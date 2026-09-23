#!/usr/bin/env bash
#---------------------------------------------------------------------
# 05-certs : CA 신뢰 설정 + 서비스 인증서 배치
#
#   sudo ./deploy-certs.sh --local                    # 이 호스트에 적용
#   ./deploy-certs.sh --nodes 'n1,n2,n3'              # SSH 로 원격 적용
#   ./deploy-certs.sh --nodes-file nodes.txt
#   sudo ./deploy-certs.sh --local --check-only       # 판정만
#
# 원격 적용 시 옵션:
#   --ssh-user <이름>   기본 azureuser
#   --ssh-key  <경로>   기본 ~/.ssh/devops.pem
#
# 하는 일 네 가지:
#   1) OS 신뢰 저장소에 CA 추가 (update-ca-certificates)
#   2) docker 가 사내 레지스트리 인증서를 신뢰하도록 certs.d 배치
#   3) containerd(k8s) 가 신뢰하도록 certs.d + config_path 설정
#   4) 서비스 인증서를 /opt/pki 아래로 배치 (각 install.sh 가 여기서 읽는다)
#
# k8s 노드에는 1·3 이 중요하다. kubelet 은 docker 가 아니라 containerd 를
# 쓰므로 /etc/docker/certs.d 는 이미지 pull 에 영향을 주지 않는다.
#---------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../00-common/common.sh"

MODE=""
CHECK_ONLY=0
NODES=""
SSH_USER="${SSH_USER:-azureuser}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/devops.pem}"

while (($#)); do
    case "$1" in
        --local)      MODE="local" ;;
        --nodes)      MODE="remote"; NODES="${2:?--nodes 에 값이 없다}"; shift ;;
        --nodes-file) MODE="remote"; NODES="$(tr '\n' ',' < "${2:?--nodes-file 에 값이 없다}")"; shift ;;
        --ssh-user)   SSH_USER="${2:?}"; shift ;;
        --ssh-key)    SSH_KEY="${2:?}"; shift ;;
        --check-only) CHECK_ONLY=1 ;;
        *)            die "알 수 없는 인자: $1" ;;
    esac
    shift
done
[[ -n "$MODE" ]] || die "--local 또는 --nodes 를 지정할 것"

OUT="${SCRIPT_DIR}/out"
CA_CRT="${OUT}/ca/ca.crt"

PKI_DIR="/opt/pki"
CA_TRUST_NAME="vanilla-k8s-internal-ca"
CONTAINERD_CERTS_D="/etc/containerd/certs.d"

# containerd 에 신뢰를 넣어야 하는 레지스트리. Harbor 만 해당한다.
REGISTRY_HOST="${HARBOR_HOSTNAME:-}"

#=====================================================================
# 판정 (로컬)
#=====================================================================
run_checks() {
    step "CA 신뢰 및 인증서 배치 판정"

    check "OS 신뢰 저장소에 CA 설치됨" \
        test -f "/usr/local/share/ca-certificates/${CA_TRUST_NAME}.crt"
    # update-ca-certificates 가 실제로 반영했는지. 파일만 두고 갱신을
    # 잊으면 신뢰되지 않는다.
    check "ca-certificates 번들에 반영됨" bash -c "
        openssl crl2pkcs7 -nocrl -certfile /etc/ssl/certs/ca-certificates.crt 2>/dev/null \
          | openssl pkcs7 -print_certs -noout 2>/dev/null | grep -q '${CA_CN_PATTERN:-Internal CA}'"

    if [[ -n "$REGISTRY_HOST" ]]; then
        check "docker 신뢰: certs.d/${REGISTRY_HOST}/ca.crt" \
            test -f "/etc/docker/certs.d/${REGISTRY_HOST}/ca.crt"
        # containerd 쪽. k8s 이미지 pull 에 영향을 주는 것은 이쪽이다.
        if [[ -f /etc/containerd/config.toml ]]; then
            check "containerd config_path 설정됨" bash -c "
                grep -qE \"config_path\\s*=\\s*'${CONTAINERD_CERTS_D}'\" /etc/containerd/config.toml"
            check "containerd 신뢰: certs.d/${REGISTRY_HOST}/hosts.toml" \
                test -f "${CONTAINERD_CERTS_D}/${REGISTRY_HOST}/hosts.toml"
            check "containerd 서비스 active" systemctl is-active --quiet containerd
        fi
    fi

    local svc
    for svc in as harbor minio mssql pgsql; do
        [[ -d "${OUT}/${svc}" ]] || continue
        check "[${svc}] /opt/pki 에 배치됨" bash -c "
            ls '${PKI_DIR}/${svc}'/*.crt >/dev/null 2>&1 || ls '${PKI_DIR}/${svc}'/*.pem >/dev/null 2>&1"
    done

    check_summary
}

#=====================================================================
# 로컬 적용
#=====================================================================
apply_local() {
    require_root
    [[ -f "$CA_CRT" ]] || die "CA 인증서가 없다: ${CA_CRT}  (먼저 ./make-certs.sh 실행)"

    #--- 1) OS 신뢰 저장소 -------------------------------------------
    step "OS 신뢰 저장소에 CA 추가"
    # 확장자가 .crt 여야 update-ca-certificates 가 인식한다.
    # .pem 으로 두면 조용히 무시된다.
    install -D -m 0644 "$CA_CRT" "/usr/local/share/ca-certificates/${CA_TRUST_NAME}.crt"
    update-ca-certificates >/dev/null 2>&1 || die "update-ca-certificates 실패"
    ok "CA 추가 및 번들 갱신 완료"

    #--- 2) docker ----------------------------------------------------
    if [[ -n "$REGISTRY_HOST" ]]; then
        step "docker 레지스트리 신뢰 설정"
        # insecure-registries 를 쓰지 않는다. TLS 검증을 통째로 끄는 설정이다.
        install -D -m 0644 "$CA_CRT" "/etc/docker/certs.d/${REGISTRY_HOST}/ca.crt"
        ok "/etc/docker/certs.d/${REGISTRY_HOST}/ca.crt"
    fi

    #--- 3) containerd -------------------------------------------------
    if [[ -n "$REGISTRY_HOST" && -f /etc/containerd/config.toml ]]; then
        step "containerd 레지스트리 신뢰 설정"

        install -D -m 0644 "$CA_CRT" "${CONTAINERD_CERTS_D}/${REGISTRY_HOST}/ca.crt"
        cat > "${CONTAINERD_CERTS_D}/${REGISTRY_HOST}/hosts.toml" <<EOF
# 사내 레지스트리 신뢰 설정. deploy-certs.sh 가 생성했다.
server = "https://${REGISTRY_HOST}"

[host."https://${REGISTRY_HOST}"]
  capabilities = ["pull", "resolve"]
  ca = "${CONTAINERD_CERTS_D}/${REGISTRY_HOST}/ca.crt"
EOF
        ok "${CONTAINERD_CERTS_D}/${REGISTRY_HOST}/hosts.toml"

        # config_path 를 켜야 위 디렉터리를 읽는다. 기본값은 빈 문자열이다.
        #
        # 주의: containerd 2.x(config version 4)에서 이 키는
        #   [plugins.'io.containerd.cri.v1.images'.registry]
        # 아래에 있다. 1.x 의 io.containerd.grpc.v1.cri 가 아니다.
        # 게다가 기본 설정에 config_path 라는 이름이 **두 곳**에 나오므로
        # 단순 sed 로 바꾸면 엉뚱한 곳을 고친다(실측 확인).
        # 그래서 해당 섹션 안의 첫 config_path 만 python 으로 정확히 바꾼다.
        if grep -qE "config_path\s*=\s*'${CONTAINERD_CERTS_D}'" /etc/containerd/config.toml; then
            ok "config_path 이미 설정됨"
        else
            cp -a /etc/containerd/config.toml \
                  "/etc/containerd/config.toml.bak.$(date +%Y%m%d-%H%M%S)"
            python3 - "$CONTAINERD_CERTS_D" <<'PY' || die "containerd config 수정 실패"
import re, sys
path = "/etc/containerd/config.toml"
certs_d = sys.argv[1]
s = open(path).read()

# registry 섹션을 찾는다. containerd 2.x 와 1.x 의 플러그인 이름을 모두 시도한다.
sec = None
for name in ("io.containerd.cri.v1.images", "io.containerd.grpc.v1.cri"):
    m = re.search(r"\[plugins\.['\"]%s['\"]\.registry\]" % re.escape(name), s)
    if m:
        sec = m
        break
if not sec:
    sys.exit("registry 섹션을 찾지 못했다")

# 그 섹션 이후 **다음 섹션 헤더 전까지** 범위에서만 config_path 를 바꾼다.
start = sec.end()
nxt = re.search(r"\n\s*\[", s[start:])
end = start + (nxt.start() if nxt else len(s) - start)
block = s[start:end]

new_block, n = re.subn(r"config_path\s*=\s*'[^']*'",
                       "config_path = '%s'" % certs_d, block, count=1)
if n == 0:
    new_block = block.rstrip("\n") + "\n      config_path = '%s'\n" % certs_d

open(path, "w").write(s[:start] + new_block + s[end:])
print("config_path 설정 완료")
PY
            systemctl restart containerd || die "containerd 재시작 실패"
            # 소켓이 열릴 때까지 기다린다. 바로 ctr 을 쓰면 실패한다.
            retry_until 60 ctr version >/dev/null 2>&1 \
                || die "containerd 가 기동되지 않았다: journalctl -u containerd"
            ok "config_path 설정 및 containerd 재시작"
        fi
    fi

    #--- 4) 서비스 인증서 배치 -----------------------------------------
    step "서비스 인증서 배치 (${PKI_DIR})"
    local svc f base
    for svc in as harbor minio mssql pgsql; do
        [[ -d "${OUT}/${svc}" ]] || continue
        install -d -m 0755 "${PKI_DIR}/${svc}"
        for f in "${OUT}/${svc}"/*; do
            base="$(basename "$f")"
            # openssl.cnf 는 발급용 설정이라 배포하지 않는다.
            [[ "$base" == "openssl.cnf" ]] && continue
            case "$base" in
                *.key|private.key) install -m 0600 "$f" "${PKI_DIR}/${svc}/${base}" ;;
                *)                 install -m 0644 "$f" "${PKI_DIR}/${svc}/${base}" ;;
            esac
        done
        ok "[${svc}] -> ${PKI_DIR}/${svc}"
    done

    # CA 만 따로도 둔다. 다른 스크립트가 참조하기 쉽게.
    install -D -m 0644 "$CA_CRT" "${PKI_DIR}/ca/ca.crt"
    ok "CA -> ${PKI_DIR}/ca/ca.crt"

    warn "CA 개인키(ca.key)는 배포하지 않는다. 발급 호스트에만 둘 것."
}

#=====================================================================
# 원격 적용
#=====================================================================
apply_remote() {
    [[ -f "$CA_CRT" ]] || die "CA 인증서가 없다: ${CA_CRT}  (먼저 ./make-certs.sh 실행)"
    [[ -f "$SSH_KEY" ]] || die "SSH 키를 찾을 수 없다: ${SSH_KEY}"
    require_cmds ssh rsync

    local -a hosts=()
    IFS=',' read -ra hosts <<<"$NODES"

    step "원격 적용 대상 ${#hosts[@]}개"
    printf '    %s\n' "${hosts[@]}"

    local h rc=0 failed=()
    for h in "${hosts[@]}"; do
        h="$(echo "$h" | tr -d '[:space:]')"
        [[ -n "$h" ]] || continue
        echo
        step "[$h] 적용"

        # 스크립트와 발급물을 함께 보낸다. ca.key 는 제외한다 —
        # 노드에 CA 개인키를 두면 그 노드가 침해되면 PKI 전체가 무너진다.
        if ! rsync -az --delete \
                --exclude 'ca/ca.key' --exclude 'ca-old-*' \
                -e "ssh -i ${SSH_KEY} -o StrictHostKeyChecking=no -o ConnectTimeout=15" \
                "${SCRIPT_DIR}/" "${SSH_USER}@${h}:/tmp/05-certs/" 2>/dev/null; then
            warn "[$h] 전송 실패"
            failed+=("$h"); rc=1; continue
        fi
        # common.sh / versions.env / site.env 도 필요하다.
        rsync -az -e "ssh -i ${SSH_KEY} -o StrictHostKeyChecking=no" \
            "${SCRIPT_DIR}/../00-common/" "${SSH_USER}@${h}:/tmp/00-common/" 2>/dev/null || true

        if ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=15 \
               "${SSH_USER}@${h}" \
               "mkdir -p /tmp/certdeploy && cp -r /tmp/05-certs /tmp/00-common /tmp/certdeploy/ 2>/dev/null;
                cd /tmp/certdeploy/05-certs && sudo bash deploy-certs.sh --local 2>&1 | tail -25"; then
            ok "[$h] 완료"
        else
            warn "[$h] 적용 실패"
            failed+=("$h"); rc=1
        fi
    done

    echo
    if ((${#failed[@]} > 0)); then
        step "실패 ${#failed[@]}개: ${failed[*]}"
    else
        step "전체 ${#hosts[@]}개 노드 적용 완료"
    fi
    return $rc
}

#=====================================================================
# 실행
#=====================================================================
if [[ "$MODE" == "local" ]]; then
    if ((CHECK_ONLY)); then
        require_root
        run_checks
        exit $?
    fi
    apply_local
    echo
    run_checks
    rc=$?
    step "다음 단계"
    echo "  서비스 설치 스크립트가 ${PKI_DIR} 아래 인증서를 자동으로 쓴다."
    echo "  이미 설치된 서비스는 해당 install.sh 를 다시 실행하면 교체된다."
    echo "    20-minio / 30-harbor / 70-mssql / 80-postgresql"
    exit $rc
else
    apply_remote
    exit $?
fi
