#!/usr/bin/env bash
#---------------------------------------------------------------------
# 05-certs : 사내 CA 와 서비스 인증서 발급 (관리 호스트에서 실행)
#
#   ./make-certs.sh                 # CA + 서비스 인증서 발급 (멱등)
#   ./make-certs.sh --check-only    # 발급물 검증만 (체인·SAN·만료)
#   ./make-certs.sh --force-leaf    # 서비스 인증서만 재발급 (CA 유지)
#   ./make-certs.sh --rotate-ca     # CA 까지 재생성 (위험. 5절 참고)
#
# 인터넷이 필요하지 않다. openssl 만 쓰므로 에어갭에서도 실행된다.
#
# 왜 CA 를 하나만 두는가:
#   서비스마다 자가서명 인증서를 쓰면 클라이언트가 **인증서 5개**를 각각
#   신뢰해야 한다. 노드가 늘어나면 배포 대상이 노드수 x 서비스수로 커진다.
#   CA 를 하나 두면 클라이언트는 **CA 1개**만 신뢰하면 되고, 서비스 인증서를
#   갱신해도 클라이언트를 다시 건드리지 않는다.
#
# 산출물: out/ 아래. 서비스별로 그 서비스가 기대하는 파일명을 쓴다.
#   out/ca/ca.crt ca.key                CA (ca.key 는 이 호스트에만 둔다)
#   out/as/tls.crt tls.key fullchain.crt UiPath Automation Suite ingress
#   out/harbor/harbor.crt harbor.key     Harbor (harbor.yml 이 참조)
#   out/minio/public.crt private.key     MinIO (이 파일명을 요구한다)
#   out/mssql/mssql.pem mssql.key        SQL Server (mssql.conf 가 참조)
#   out/pgsql/server.crt server.key      PostgreSQL (ssl_cert_file 이 참조)
#
# 배포는 deploy-certs.sh 가 한다.
#---------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../00-common/common.sh"

MODE="issue"
case "${1:-}" in
    --check-only) MODE="check" ;;
    --force-leaf) MODE="force-leaf" ;;
    --rotate-ca)  MODE="rotate-ca" ;;
    "")           MODE="issue" ;;
    *)            die "알 수 없는 인자: $1 (--check-only | --force-leaf | --rotate-ca)" ;;
esac

require_cmds openssl
require_nonroot_build

# check 가 bash -c 로 실행하므로 헬퍼를 export 해야 새 프로세스에서 보인다.
export -f file_mode cert_san

OUT="${SCRIPT_DIR}/out"
CA_DIR="${OUT}/ca"

#---------------------------------------------------------------------
# 유효기간
#
# CA 10년: 갱신 때 모든 클라이언트를 다시 건드려야 하므로 길게 둔다.
# leaf 825일: 공개 신뢰 CA 의 상한(CA/Browser Forum)과 같은 값을 쓴다.
#             사내 CA 는 더 길게도 되지만, 갱신 절차를 주기적으로 실제로
#             돌려보는 편이 안전하다. 만료 경보를 놓쳤을 때의 피해가 크다.
#---------------------------------------------------------------------
CA_DAYS="${CA_DAYS:-3650}"
LEAF_DAYS="${LEAF_DAYS:-825}"

# CA 4096 / leaf 2048.
# leaf 를 2048 로 두는 이유: TLS 핸드셰이크마다 서명 검증 비용이 들고,
# 2048 은 여전히 표준 강도다. CA 는 교체가 어려우므로 4096 으로 둔다.
CA_BITS="${CA_BITS:-4096}"
LEAF_BITS="${LEAF_BITS:-2048}"

CA_CN="${CA_CN:-Vanilla K8s Internal CA}"
CERT_ORG="${CERT_ORG:-Vanilla K8s}"
CERT_COUNTRY="${CERT_COUNTRY:-KR}"

#---------------------------------------------------------------------
# 발급 대상
#
# site.env 에서 호스트명을 읽는다. 비어 있으면 그 서비스는 건너뛴다.
# 형식: <이름>|<호스트명>|<IP>|<와일드카드 여부>|<crt 파일명>|<key 파일명>
#
# 와일드카드가 필요한 곳:
#   as    : UiPath AS 는 alm.<fqdn>, monitoring.<fqdn> 등 하위 이름을 쓴다.
#   minio : 가상 호스트 스타일 버킷 주소(<bucket>.<host>)를 쓰려면 필요하다.
# 나머지는 단일 이름이므로 와일드카드를 넣지 않는다(공격면을 줄인다).
#---------------------------------------------------------------------
TARGETS=(
    "as|${AS_FQDN:-}|${AS_LB_IP:-}|yes|tls.crt|tls.key"
    "harbor|${HARBOR_HOSTNAME:-}|${HARBOR_PRIVATE_IP:-}|no|harbor.crt|harbor.key"
    "minio|${MINIO_HOSTNAME:-}|${MINIO_HOST_IP:-}|yes|public.crt|private.key"
    "mssql|${MSSQL_HOSTNAME:-}|${MSSQL_HOST_IP:-}|no|mssql.pem|mssql.key"
    "pgsql|${PG_HOSTNAME:-}|${PG_HOST_IP:-}|no|server.crt|server.key"
)

#=====================================================================
# 판정
#=====================================================================
run_checks() {
    step "인증서 발급물 판정"

    check "CA 인증서 존재" test -f "${CA_DIR}/ca.crt"
    check "CA 키 존재"     test -f "${CA_DIR}/ca.key"
    check "CA 키 권한 0600" bash -c "[[ \$(file_mode '${CA_DIR}/ca.key') == 600 ]]"
    check "CA 가 CA:TRUE" bash -c "
        openssl x509 -in '${CA_DIR}/ca.crt' -noout -text | grep -q 'CA:TRUE'"

    if [[ -f "${CA_DIR}/ca.crt" ]]; then
        log "CA subject : $(openssl x509 -in "${CA_DIR}/ca.crt" -noout -subject | sed 's/^subject=//')"
        log "CA 만료    : $(openssl x509 -in "${CA_DIR}/ca.crt" -noout -enddate | cut -d= -f2)"
    fi

    local entry name host ip wild crt key d
    for entry in "${TARGETS[@]}"; do
        IFS='|' read -r name host ip wild crt key <<<"$entry"
        [[ -n "$host" ]] || continue
        d="${OUT}/${name}"

        check "[${name}] 인증서·키 존재" bash -c "test -f '${d}/${crt}' -a -f '${d}/${key}'"
        [[ -f "${d}/${crt}" ]] || continue

        check "[${name}] 키 권한 0600" bash -c "[[ \$(file_mode '${d}/${key}') == 600 ]]"
        # CA 로 검증되는지. 체인이 깨지면 클라이언트가 거부한다.
        check "[${name}] CA 로 검증됨" bash -c "
            openssl verify -CAfile '${CA_DIR}/ca.crt' '${d}/${crt}' >/dev/null 2>&1"
        # 인증서와 키가 실제로 짝인지. 섞이면 기동 시 조용히 실패한다.
        check "[${name}] 인증서와 키가 짝" bash -c "
            a=\$(openssl x509 -in '${d}/${crt}' -noout -pubkey | openssl md5)
            b=\$(openssl pkey -in '${d}/${key}' -pubout | openssl md5)
            [[ \"\$a\" == \"\$b\" ]]"
        check "[${name}] SAN 에 ${host} 포함" bash -c "
            cert_san '${d}/${crt}' | grep -q 'DNS:${host}'"
        if [[ "$wild" == "yes" ]]; then
            check "[${name}] SAN 에 *.${host} 포함" bash -c "
                cert_san '${d}/${crt}' | grep -q 'DNS:\*\.${host}'"
        fi
        # 30일 안에 만료되면 알려준다. 만료는 조용히 다가온다.
        check "[${name}] 만료까지 30일 이상" bash -c "
            openssl x509 -in '${d}/${crt}' -noout -checkend 2592000 >/dev/null"
        log "  [${name}] ${host} / 만료 $(openssl x509 -in "${d}/${crt}" -noout -enddate | cut -d= -f2)"
    done

    check_summary
}

#=====================================================================
# CA 생성
#=====================================================================
make_ca() {
    if [[ -f "${CA_DIR}/ca.crt" && "$MODE" != "rotate-ca" ]]; then
        ok "기존 CA 사용 (만료: $(openssl x509 -in "${CA_DIR}/ca.crt" -noout -enddate | cut -d= -f2))"
        return 0
    fi

    if [[ -f "${CA_DIR}/ca.crt" && "$MODE" == "rotate-ca" ]]; then
        warn "CA 를 재생성한다. **기존에 발급한 모든 인증서가 무효가 된다.**"
        warn "모든 노드·클라이언트에 새 CA 를 다시 배포해야 한다."
        local bak="${CA_DIR}/../ca-old-$(date +%Y%m%d-%H%M%S)"
        mkdir -p "$bak" && cp -a "${CA_DIR}/." "$bak/"
        warn "기존 CA 는 ${bak} 에 보관했다."
    fi

    step "CA 생성 (${CA_BITS}bit, ${CA_DAYS}일)"
    mkdir -p "$CA_DIR"

    # pathlen:0 — 이 CA 가 하위 CA 를 만들 수 없게 제한한다.
    # 중간 CA 를 쓰지 않는 구성이므로 제한을 걸어 오용을 막는다.
    cat > "${CA_DIR}/ca-openssl.cnf" <<EOF
[req]
default_bits       = ${CA_BITS}
prompt             = no
default_md         = sha256
distinguished_name = dn
x509_extensions    = v3_ca

[dn]
C  = ${CERT_COUNTRY}
O  = ${CERT_ORG}
CN = ${CA_CN}

[v3_ca]
basicConstraints       = critical, CA:TRUE, pathlen:0
keyUsage               = critical, digitalSignature, cRLSign, keyCertSign
subjectKeyIdentifier   = hash
EOF

    openssl req -x509 -nodes -new -newkey "rsa:${CA_BITS}" -sha256 \
        -days "$CA_DAYS" \
        -keyout "${CA_DIR}/ca.key" \
        -out    "${CA_DIR}/ca.crt" \
        -config "${CA_DIR}/ca-openssl.cnf" >/dev/null 2>&1 \
        || die "CA 생성 실패"

    chmod 0600 "${CA_DIR}/ca.key"
    chmod 0644 "${CA_DIR}/ca.crt"
    ok "CA 생성: ${CA_DIR}/ca.crt"
    log "  subject: $(openssl x509 -in "${CA_DIR}/ca.crt" -noout -subject | sed 's/^subject=//')"
}

#=====================================================================
# 서비스 인증서 발급
#=====================================================================
issue_leaf() {
    local name="$1" host="$2" ip="$3" wild="$4" crt="$5" key="$6"
    local d="${OUT}/${name}"
    mkdir -p "$d"

    if [[ -f "${d}/${crt}" && "$MODE" == "issue" ]]; then
        ok "[${name}] 기존 인증서 사용 (만료: $(openssl x509 -in "${d}/${crt}" -noout -enddate | cut -d= -f2))"
        return 0
    fi

    # SAN 목록 구성. 이름과 IP 를 모두 넣는다.
    # 하나만 넣으면 다른 방식으로 접속할 때 거부된다.
    local -a san=("DNS:${host}")
    [[ "$wild" == "yes" ]] && san+=("DNS:*.${host}")
    san+=("DNS:localhost")
    [[ -n "$ip" ]] && san+=("IP:${ip}")
    san+=("IP:127.0.0.1")
    local SAN_LINE
    SAN_LINE="$(IFS=,; echo "${san[*]}")"

    cat > "${d}/openssl.cnf" <<EOF
[req]
default_bits       = ${LEAF_BITS}
prompt             = no
default_md         = sha256
distinguished_name = dn
req_extensions     = v3_req

[dn]
C  = ${CERT_COUNTRY}
O  = ${CERT_ORG}
OU = ${name}
# CN 은 접속 이름과 같아야 한다. SQL Server 는 CN 을 본다(SAN 만으로는
# 거부하는 클라이언트가 있다).
CN = ${host}

[v3_req]
basicConstraints = CA:FALSE
# keyEncipherment 가 필요하다. SQL Server 는 키 교환용(AT_KEYEXCHANGE)
# 인증서를 요구하며 이 비트가 없으면 TLS 를 켜지 못한다.
keyUsage         = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName   = ${SAN_LINE}
EOF

    openssl req -new -nodes -newkey "rsa:${LEAF_BITS}" -sha256 \
        -keyout "${d}/${key}" \
        -out    "${d}/${name}.csr" \
        -config "${d}/openssl.cnf" >/dev/null 2>&1 \
        || die "[${name}] CSR 생성 실패"

    # -copy_extensions 를 쓰지 않고 -extfile 로 명시한다.
    # CSR 의 확장을 그대로 복사하면 요청자가 확장을 임의로 넣을 수 있다.
    openssl x509 -req -sha256 -days "$LEAF_DAYS" \
        -in  "${d}/${name}.csr" \
        -CA  "${CA_DIR}/ca.crt" -CAkey "${CA_DIR}/ca.key" -CAcreateserial \
        -extfile "${d}/openssl.cnf" -extensions v3_req \
        -out "${d}/${crt}" >/dev/null 2>&1 \
        || die "[${name}] 서명 실패"

    rm -f "${d}/${name}.csr"
    chmod 0600 "${d}/${key}"
    chmod 0644 "${d}/${crt}"

    # 체인 파일. ingress 컨트롤러 등은 서버 인증서 + CA 를 한 파일로 요구한다.
    cat "${d}/${crt}" "${CA_DIR}/ca.crt" > "${d}/fullchain.crt"
    chmod 0644 "${d}/fullchain.crt"

    # CA 도 같은 디렉터리에 둔다. 배포 시 한 디렉터리만 옮기면 되게 한다.
    cp "${CA_DIR}/ca.crt" "${d}/ca.crt"

    ok "[${name}] 발급: ${host}  (SAN: ${SAN_LINE})"
}

[[ "$MODE" == "check" ]] && { run_checks; exit $?; }

#=====================================================================
# 실행
#=====================================================================
step "사내 PKI 발급 (CA 1개 + 서비스 인증서)"
mkdir -p "$OUT"

# site.env 를 읽었는지 확인한다. 예시 값으로 발급하면 SAN 이 맞지 않아
# 나중에 전부 다시 발급해야 한다.
if [[ ! -f "${SCRIPT_DIR}/../00-common/site.env" ]]; then
    warn "site.env 가 없다. site.env.example 의 예시 호스트명으로 발급된다."
    warn "  cp 00-common/site.env.example 00-common/site.env 후 값을 채울 것."
fi

make_ca

step "서비스 인증서 발급"
ISSUED=0 SKIPPED=()
for entry in "${TARGETS[@]}"; do
    IFS='|' read -r name host ip wild crt key <<<"$entry"
    if [[ -z "$host" ]]; then
        SKIPPED+=("$name")
        continue
    fi
    issue_leaf "$name" "$host" "$ip" "$wild" "$crt" "$key"
    ISSUED=$((ISSUED + 1))
done

((${#SKIPPED[@]} == 0)) || {
    warn "호스트명이 비어 건너뛴 서비스: ${SKIPPED[*]}"
    warn "  site.env 에 AS_FQDN / HARBOR_HOSTNAME / MINIO_HOSTNAME /"
    warn "  MSSQL_HOSTNAME / PG_HOSTNAME 을 채우면 발급된다."
}

#=====================================================================
# 판정
#=====================================================================
run_checks
rc=$?

step "다음 단계"
echo "  발급 위치: ${OUT}"
echo
echo "  1) 각 노드에 CA 신뢰 + 서비스 인증서 배치:"
echo "       sudo ./deploy-certs.sh --local                 # 이 호스트에"
echo "       ./deploy-certs.sh --nodes 'node1,node2,node3'  # SSH 로 원격에"
echo
echo "  2) 서비스 설치 스크립트가 /opt/pki 아래 인증서를 자동으로 쓴다."
echo "     이미 설치돼 있다면 해당 install.sh 를 다시 실행하면 교체된다."
echo
echo "  주의: ${CA_DIR}/ca.key 는 이 호스트에만 두고 배포하지 말 것."
echo "        유출되면 누구나 우리 CA 를 신뢰하는 인증서를 만들 수 있다."
exit $rc
