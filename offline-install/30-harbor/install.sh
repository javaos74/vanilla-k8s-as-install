#!/usr/bin/env bash
#---------------------------------------------------------------------
# 30-harbor : 오프라인 설치 (에어갭 노드에서 root 로 실행)
#
#   sudo ./install.sh                  # 설치 + push/pull 왕복 검증
#   sudo ./install.sh --check-only     # 판정만
#   sudo ./install.sh --test-restart   # systemd 재기동 + 데몬 재시작 검증
#   sudo ./install.sh --uninstall      # 정지·제거(데이터는 남긴다)
#
# 전제: 10-k8s 설치 완료(docker + docker compose).
#
# 결과: /opt/harbor 에 Harbor 9개 서비스. 443(HTTPS)만 열린다.
#       systemd harbor.service 로 부팅 시 자동 기동된다.
#---------------------------------------------------------------------
BUNDLE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${BUNDLE_ROOT}/00-common/common.sh"

MODE="install"
case "${1:-}" in
    --check-only)   MODE="check" ;;
    --test-restart) MODE="restart-test" ;;
    --uninstall)    MODE="uninstall" ;;
    "")             MODE="install" ;;
    *)              die "알 수 없는 인자: $1 (--check-only | --test-restart | --uninstall)" ;;
esac

require_root

CONF_DIR="${BUNDLE_ROOT}/conf"
INSTALLER_DIR="${BUNDLE_ROOT}/installer"

HARBOR_DIR="/opt/harbor"
HARBOR_DATA_DIR="${HARBOR_DATA_DIR:-/data/harbor}"
CERT_DIR="${HARBOR_DIR}/certs"
COMPOSE_FILE="${HARBOR_DIR}/docker-compose.yml"
CRED_FILE="${HARBOR_DIR}/.harbor-credentials"

# 접속 이름은 site.env 의 HARBOR_HOSTNAME 을 쓴다.
# Harbor 는 IP 로 접속하면 docker login 이 인증서 검증에 실패하는 경우가 많아
# 이름 기반 접속을 전제로 한다.
HARBOR_HOST="${HARBOR_HOSTNAME:-harbor.local}"

# 주소는 **이 노드 자신**이다. site.env 의 HARBOR_PRIVATE_IP 를 쓰면 안 된다.
# 그 값은 "이미 운영 중인 다른 Harbor 에 접근할 주소"라는 뜻이고, 이 단계는
# 여기에 Harbor 를 새로 설치하는 것이다. 혼용하면 /etc/hosts 가 다른 호스트를
# 가리켜 docker login 이 x509 오류로 실패한다(실측으로 겪은 문제).
HARBOR_HOST_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')"
[[ -n "$HARBOR_HOST_IP" ]] || HARBOR_HOST_IP="$(hostname -I | awk '{print $1}')"

SMOKE_PROJECT="harbor-smoke-test"

dc() { docker compose -f "$COMPOSE_FILE" "$@"; }

harbor_admin_pw() {
    grep -E '^HARBOR_ADMIN_PASSWORD=' "$CRED_FILE" 2>/dev/null | cut -d= -f2-
}

#=====================================================================
# 판정
#=====================================================================
run_checks() {
    step "설치 상태 판정"

    check "docker 사용 가능"         docker info
    check "docker compose 사용 가능"  bash -c "docker compose version >/dev/null 2>&1"
    check "harbor.yml 존재"          test -f "${HARBOR_DIR}/harbor.yml"
    check "compose 파일 생성됨(prepare 완료)" test -f "$COMPOSE_FILE"
    check "TLS 인증서 존재"          bash -c "test -f '${CERT_DIR}/harbor.crt' -a -f '${CERT_DIR}/harbor.key'"
    check "자격증명 파일 권한 0600"   bash -c "[[ \$(stat -c %a '$CRED_FILE' 2>/dev/null) == 600 ]]"
    check "데이터 디렉터리 존재"      test -d "$HARBOR_DATA_DIR"

    # 인증서 SAN. 이름이 빠지면 docker login 이 x509 오류로 실패한다.
    check "인증서 SAN 에 ${HARBOR_HOST} 포함" bash -c "
        openssl x509 -in '${CERT_DIR}/harbor.crt' -noout -text \
          | grep -A1 'Subject Alternative Name' | grep -q '${HARBOR_HOST}'"

    #--- systemd ------------------------------------------------------
    # 재부팅 후 자동 기동의 유일한 근거다. Docker 재시작 정책만으로는
    # 기동 순서가 지켜지지 않아 대부분의 컨테이너가 죽는다(README 3절).
    check "harbor.service 설치됨"    test -f /etc/systemd/system/harbor.service
    check "harbor.service enabled"   systemctl is-enabled --quiet harbor.service
    check "harbor-start.sh 실행 가능" test -x /usr/local/bin/harbor-start.sh

    #--- 서비스 상태 ---------------------------------------------------
    # 9개 서비스가 전부 running 인지. 하나라도 빠지면 443 이 닫히거나
    # 로그인/push 가 실패한다.
    check "compose 서비스 전부 running" retry_until 240 bash -c "
        cd '${HARBOR_DIR}' || exit 1
        mapfile -t svcs < <(docker compose config --services)
        ((\${#svcs[@]} > 0)) || exit 1
        for s in \"\${svcs[@]}\"; do
            st=\$(docker compose ps -a --format '{{.State}}' \"\$s\" 2>/dev/null | head -1)
            [[ \"\$st\" == running ]] || exit 1
        done"

    if [[ -f "$COMPOSE_FILE" ]]; then
        local n_svc n_run
        n_svc="$(cd "$HARBOR_DIR" && docker compose config --services | wc -l | tr -d ' ')"
        n_run="$(cd "$HARBOR_DIR" && docker compose ps --format '{{.State}}' 2>/dev/null | grep -c running || true)"
        log "서비스 ${n_run}/${n_svc} running"
    fi

    check "harbor-log 이 1514 수신" retry_until 60 bash -c "
        timeout 2 bash -c '>/dev/tcp/127.0.0.1/1514'"
    check "호스트 443 수신" retry_until 120 bash -c "ss -lnt | grep -qE ':443\b'"

    # 80 은 harbor.yml 에 http 절을 넣지 않아도 Harbor 가 항상 publish 한다
    # (compose 템플릿에 80:8080 이 박혀 있다). 닫혀 있기를 기대하면 안 된다.
    # 확인해야 할 실제 보안 속성은 "평문으로 서비스하지 않고 HTTPS 로 보낸다"다.
    # 실측: HTTP 308 -> https://<host>:443/
    check "80 이 HTTPS 로 리다이렉트(평문 서비스 안 함)" bash -c "
        code=\$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1/ 2>/dev/null)
        [[ \"\$code\" == 301 || \"\$code\" == 308 ]]"

    #--- API 상태 ------------------------------------------------------
    check "API /health 응답" retry_until 180 bash -c "
        curl -sk --max-time 5 https://127.0.0.1/api/v2.0/health -o /dev/null"
    # 개별 컴포넌트까지 healthy 인지 본다. 전체 status 만 보면
    # 일부 컴포넌트가 죽어도 통과할 수 있다.
    check "API health 의 모든 컴포넌트 healthy" retry_until 240 bash -c "
        body=\$(curl -sk --max-time 10 https://127.0.0.1/api/v2.0/health)
        echo \"\$body\" | grep -q '\"status\":\"healthy\"' || exit 1
        ! echo \"\$body\" | grep -q '\"status\":\"unhealthy\"'"

    if curl -sk --max-time 10 https://127.0.0.1/api/v2.0/health >/tmp/hb-health.json 2>/dev/null; then
        log "컴포넌트 상태:"
        python3 - <<'PY' 2>/dev/null || true
import json
d = json.load(open("/tmp/hb-health.json"))
for c in d.get("components", []):
    print(f"    {c.get('name','?'):<24} {c.get('status','?')}")
PY
        rm -f /tmp/hb-health.json
    fi

    #--- 인증 + 레지스트리 왕복 검증 ------------------------------------
    # 여기가 핵심이다. 서비스가 running 이어도 DB 초기화 실패나 인증서
    # 문제로 push 가 안 되는 경우가 있다. 실제로 밀어 보고 받아 본다.
    step "레지스트리 왕복 검증 (login -> push -> pull)"

    local pw; pw="$(harbor_admin_pw)"
    if [[ -z "$pw" ]]; then
        warn "자격증명 파일을 읽을 수 없어 왕복 검증을 생략한다."
        check_summary
        return $?
    fi

    check "admin API 인증 성공" bash -c "
        [[ \$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 \
            -u 'admin:${pw}' https://127.0.0.1/api/v2.0/users/current) == 200 ]]"

    # docker login 은 이름으로 해야 한다. /etc/hosts 매핑을 확인/추가한다.
    check "/etc/hosts 에 ${HARBOR_HOST} 매핑" bash -c "
        getent hosts '${HARBOR_HOST}' >/dev/null"
    # 자가서명이므로 docker 가 CA 를 신뢰해야 한다.
    check "docker 가 인증서를 신뢰(certs.d 배치)" \
        test -f "/etc/docker/certs.d/${HARBOR_HOST}/ca.crt"

    check "docker login" bash -c "
        echo '${pw}' | docker login '${HARBOR_HOST}' -u admin --password-stdin >/dev/null 2>&1"

    check "프로젝트 생성(API)" bash -c "
        code=\$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 -X POST \
            -u 'admin:${pw}' -H 'Content-Type: application/json' \
            -d '{\"project_name\":\"${SMOKE_PROJECT}\",\"public\":false}' \
            https://127.0.0.1/api/v2.0/projects)
        [[ \"\$code\" == 201 || \"\$code\" == 409 ]]"

    # push 에 쓸 이미지는 Harbor 자신의 이미지 중 가장 작은 것을 재사용한다.
    # 에어갭이라 새로 받을 수 없고, 별도 이미지를 번들에 넣으면 용량만 늘어난다.
    local src_img
    src_img="$(docker images --format '{{.Repository}}:{{.Tag}}' \
               | grep -E '^goharbor/(nginx-photon|registry-photon|harbor-portal)' | head -1)"
    if [[ -z "$src_img" ]]; then
        warn "push 검증에 쓸 goharbor 이미지를 찾지 못했다. push/pull 검증을 생략한다."
    else
        local dst="${HARBOR_HOST}/${SMOKE_PROJECT}/smoke:1"
        log "push 원본: ${src_img}"
        check "이미지 태깅"  docker tag "$src_img" "$dst"
        check "docker push" bash -c "docker push '${dst}' >/dev/null 2>&1"
        # 로컬 캐시를 지우고 다시 받아야 pull 을 실제로 검증하는 것이 된다.
        docker rmi "$dst" >/dev/null 2>&1 || true
        check "docker pull(로컬 캐시 삭제 후)" bash -c "docker pull '${dst}' >/dev/null 2>&1"
        check "API 에 아티팩트 등록 확인" bash -c "
            curl -sk --max-time 10 -u 'admin:${pw}' \
              'https://127.0.0.1/api/v2.0/projects/${SMOKE_PROJECT}/repositories/smoke/artifacts' \
              | grep -q digest"
        docker rmi "$dst" >/dev/null 2>&1 || true
    fi

    # 정리. 실패해도 판정에 영향을 주지 않는다.
    curl -sk -o /dev/null --max-time 10 -X DELETE -u "admin:${pw}" \
        "https://127.0.0.1/api/v2.0/projects/${SMOKE_PROJECT}/repositories/smoke" 2>/dev/null || true
    curl -sk -o /dev/null --max-time 10 -X DELETE -u "admin:${pw}" \
        "https://127.0.0.1/api/v2.0/projects/${SMOKE_PROJECT}" 2>/dev/null || true
    docker logout "$HARBOR_HOST" >/dev/null 2>&1 || true

    log "레지스트리: https://${HARBOR_HOST}  (admin / ${CRED_FILE} 참고)"
    check_summary
}

#=====================================================================
# 재기동 검증
#=====================================================================
do_restart_test() {
    step "systemd 재기동 검증"
    systemctl restart harbor.service || die "harbor.service 재시작 실패"
    retry_until 300 bash -c "curl -sk -o /dev/null --max-time 5 https://127.0.0.1/api/v2.0/health" \
        && ok "systemd 재기동 후 API 응답 정상" || die "재기동 후 API 가 응답하지 않는다"

    step "docker 데몬 재시작 후 복구 (재부팅 대리 검증)"
    # 여기가 진짜 시험이다. 데몬이 내려가면 9개 컨테이너가 동시에 다시 뜨려 하고,
    # harbor-log 가 1514 를 잡기 전에 나머지가 뜨면 exit 128 로 죽는다.
    # systemd 유닛 + harbor-start.sh 가 그 순서를 잡아 주는지 확인한다.
    systemctl restart docker || die "docker 데몬 재시작 실패"
    sleep 5
    # 데몬 재시작만으로는 harbor.service 가 다시 돌지 않는다(oneshot).
    # 부팅 시에는 systemd 가 순서를 지켜 주지만, 데몬만 재시작한 경우는
    # 수동으로 유닛을 다시 돌려 기동 순서를 재현한다.
    systemctl restart harbor.service || die "harbor.service 재시작 실패"

    retry_until 300 bash -c "
        cd '${HARBOR_DIR}' || exit 1
        mapfile -t svcs < <(docker compose config --services)
        for s in \"\${svcs[@]}\"; do
            st=\$(docker compose ps -a --format '{{.State}}' \"\$s\" 2>/dev/null | head -1)
            [[ \"\$st\" == running ]] || exit 1
        done" && ok "전 서비스 running 복귀" || die "일부 서비스가 복귀하지 않았다"

    retry_until 180 bash -c "ss -lnt | grep -qE ':443\b'" \
        && ok "443 재수신" || die "443 이 다시 열리지 않았다"
    retry_until 180 bash -c "curl -sk -o /dev/null --max-time 5 https://127.0.0.1/api/v2.0/health" \
        && ok "API 응답 정상" || die "API 가 응답하지 않는다"
    exit 0
}

do_uninstall() {
    step "Harbor 제거"
    systemctl disable --now harbor.service >/dev/null 2>&1 || true
    if [[ -f "$COMPOSE_FILE" ]]; then
        dc down >/dev/null 2>&1 || true
    fi
    rm -f /etc/systemd/system/harbor.service /usr/local/bin/harbor-start.sh
    systemctl daemon-reload
    ok "컨테이너·유닛 제거. 설정(${HARBOR_DIR})과 데이터(${HARBOR_DATA_DIR})는 남겨둔다."
    log "데이터까지 지우려면: rm -rf ${HARBOR_DATA_DIR} ${HARBOR_DIR}"
    exit 0
}

[[ "$MODE" == "uninstall" ]]    && do_uninstall
[[ "$MODE" == "restart-test" ]] && do_restart_test
if [[ "$MODE" == "check" ]]; then run_checks; exit $?; fi

#=====================================================================
# 0. 사전 확인
#=====================================================================
step "사전 확인"
verify_manifest "$BUNDLE_ROOT"

is_online && warn "인터넷 연결 상태다. 오프라인 검증이라면 airgap-on.sh 를 먼저 실행할 것." \
          || ok "인터넷 차단 상태 (에어갭 검증 조건 충족)"

require_cmds docker openssl tar
docker info >/dev/null 2>&1 || die "docker 가 동작하지 않는다. 10-k8s 설치를 확인할 것."
docker compose version >/dev/null 2>&1 \
    || die "docker compose 플러그인이 없다. 10-k8s 번들의 docker-compose-plugin deb 를 확인할 것."
ok "docker $(docker --version | awk '{print $3}' | tr -d ,) / compose $(docker compose version --short 2>/dev/null)"

# Harbor 는 443 을 직접 점유한다. 40-haproxy 의 l4 도 443 을 쓰므로
# 같은 노드에 둘을 함께 올릴 수 없다. 먼저 명확히 알려준다.
if ss -lnt | grep -qE ':443\b'; then
    if ! docker ps --format '{{.Names}}' | grep -q '^nginx$'; then
        die "$(cat <<MSG
포트 443 을 다른 프로세스가 쓰고 있다:
  $(ss -lntp | grep -E ':443\b' | head -1)

40-haproxy 의 l4 컨테이너가 443 을 쓰고 있다면 같은 노드에 Harbor 를 올릴 수 없다.
Harbor 는 별도 호스트에 두는 것을 권장한다(README 2절).
MSG
)"
    fi
fi
ok "포트 443 사용 가능"

log "접속 이름=${HARBOR_HOST} / 주소=${HARBOR_HOST_IP}"

#=====================================================================
# 1. 인스톨러 전개
#=====================================================================
step "오프라인 인스톨러 전개"

TGZ="$(ls "${INSTALLER_DIR}"/harbor-offline-installer-*.tgz 2>/dev/null | head -1)"
[[ -n "$TGZ" ]] || die "인스톨러를 찾지 못했다: ${INSTALLER_DIR}"

install -d -m 0755 "$HARBOR_DIR"
install -d -m 0700 "$CERT_DIR"
install -d -m 0755 "$HARBOR_DATA_DIR"

# tgz 최상위가 harbor/ 이므로 --strip-components=1 로 /opt/harbor 에 바로 푼다.
tar -C "$HARBOR_DIR" -xzf "$TGZ" --strip-components=1 \
    || die "인스톨러 전개 실패"
ok "전개 완료: ${HARBOR_DIR} ($(du -sh "$HARBOR_DIR" | cut -f1))"

#=====================================================================
# 2. 자격증명
#=====================================================================
step "자격증명"

if [[ -f "$CRED_FILE" ]]; then
    ok "기존 자격증명 사용: ${CRED_FILE}"
    HARBOR_ADMIN_PASSWORD="$(grep -E '^HARBOR_ADMIN_PASSWORD=' "$CRED_FILE" | cut -d= -f2-)"
    HARBOR_DB_PASSWORD="$(grep -E '^HARBOR_DB_PASSWORD=' "$CRED_FILE" | cut -d= -f2-)"
else
    # 기본 비밀번호(Harbor12345)를 쓰지 않는다. 공개 문서의 기본값이
    # 그대로 운영에 들어가는 일이 실제로 생긴다.
    HARBOR_ADMIN_PASSWORD="${HARBOR_ADMIN_PASSWORD:-$(openssl rand -base64 24 | tr -d '/+=' | head -c 20)}"
    HARBOR_DB_PASSWORD="${HARBOR_DB_PASSWORD:-$(openssl rand -base64 24 | tr -d '/+=' | head -c 20)}"
    cat > "$CRED_FILE" <<EOF
# Harbor 자격증명 — 30-harbor/install.sh 가 생성했다.
# admin 비밀번호는 최초 기동 시에만 harbor.yml 에서 읽힌다.
# 이후 변경은 UI/API 로 하고, 바꾸면 이 파일도 함께 갱신할 것.
HARBOR_ADMIN_PASSWORD=${HARBOR_ADMIN_PASSWORD}
HARBOR_DB_PASSWORD=${HARBOR_DB_PASSWORD}
EOF
    chmod 0600 "$CRED_FILE"
    GENERATED_PW=1
    ok "자격증명 생성: ${CRED_FILE} (0600)"
fi

#=====================================================================
# 3. TLS 인증서
#=====================================================================
step "TLS 인증서"

if [[ -f "${CERT_DIR}/harbor.crt" && -f "${CERT_DIR}/harbor.key" ]]; then
    ok "기존 인증서 사용 (만료: $(openssl x509 -in "${CERT_DIR}/harbor.crt" -noout -enddate | cut -d= -f2))"
else
    sed -e "s|__HARBOR_HOSTNAME__|${HARBOR_HOST}|g" \
        -e "s|__HARBOR_HOST_IP__|${HARBOR_HOST_IP}|g" \
        "${CONF_DIR}/harbor-openssl.cnf.tmpl" > /tmp/harbor-openssl.cnf
    openssl req -x509 -nodes -days 3650 -newkey rsa:4096 \
        -keyout "${CERT_DIR}/harbor.key" \
        -out    "${CERT_DIR}/harbor.crt" \
        -config /tmp/harbor-openssl.cnf >/dev/null 2>&1 \
        || die "인증서 생성 실패"
    rm -f /tmp/harbor-openssl.cnf
    chmod 0644 "${CERT_DIR}/harbor.crt"
    chmod 0600 "${CERT_DIR}/harbor.key"
    ok "자가서명 인증서 생성 (SAN: ${HARBOR_HOST}, ${HARBOR_HOST_IP}, localhost, 127.0.0.1)"
fi

# docker 가 이 레지스트리의 자가서명 인증서를 신뢰하도록 배치한다.
# 없으면 docker login 이 x509: certificate signed by unknown authority 로 실패한다.
# insecure-registries 를 쓰면 TLS 검증을 통째로 끄게 되므로 쓰지 않는다.
install -d -m 0755 "/etc/docker/certs.d/${HARBOR_HOST}"
install -m 0644 "${CERT_DIR}/harbor.crt" "/etc/docker/certs.d/${HARBOR_HOST}/ca.crt"
ok "docker 신뢰 설정: /etc/docker/certs.d/${HARBOR_HOST}/ca.crt"

# 이름 해석. 공인 DNS 는 공인 IP 를 반환하거나 레코드가 없다.
# 에어갭에서는 /etc/hosts 가 실질적인 사내 DNS 역할을 한다.
# || true 가 반드시 필요하다. getent 는 이름을 못 찾으면 exit 2 이고,
# common.sh 의 set -e + pipefail 조합에서 명령 치환 실패가 곧 스크립트 종료로
# 이어진다. 실측: 이 줄에서 로그도 남기지 않고 조용히 죽었다.
CURRENT_MAP="$(getent hosts "$HARBOR_HOST" 2>/dev/null | awk '{print $1}' | head -1 || true)"
if [[ -z "$CURRENT_MAP" ]]; then
    printf '%s %s\n' "$HARBOR_HOST_IP" "$HARBOR_HOST" >> /etc/hosts
    ok "/etc/hosts 에 추가: ${HARBOR_HOST_IP} ${HARBOR_HOST}"
elif [[ "$CURRENT_MAP" == "$HARBOR_HOST_IP" ]]; then
    ok "/etc/hosts 매핑 이미 정확: ${CURRENT_MAP} ${HARBOR_HOST}"
else
    # 다른 호스트를 가리키고 있다. 그대로 두면 docker login/push 가 그쪽으로
    # 가서 x509 오류가 난다. 이 노드가 이제 그 이름을 서비스하므로 바로잡는다.
    warn "${HARBOR_HOST} 가 ${CURRENT_MAP} 를 가리키고 있다. 이 노드(${HARBOR_HOST_IP})로 바로잡는다."
    warn "  다른 Harbor 를 계속 쓰려면 site.env 의 HARBOR_HOSTNAME 을 다른 이름으로 바꿀 것."
    cp -a /etc/hosts "/etc/hosts.bak.$(date +%Y%m%d-%H%M%S)"
    sed -i -E "/[[:space:]]${HARBOR_HOST}([[:space:]]|\$)/d" /etc/hosts
    printf '%s %s\n' "$HARBOR_HOST_IP" "$HARBOR_HOST" >> /etc/hosts
    ok "/etc/hosts 교정: ${HARBOR_HOST_IP} ${HARBOR_HOST} (원본은 /etc/hosts.bak.* 에 보관)"
fi

#=====================================================================
# 4. harbor.yml 생성
#=====================================================================
step "harbor.yml 생성"

# _version 은 인스톨러가 제공하는 템플릿의 값을 그대로 따라야 한다.
# 다르면 prepare 가 "please make sure the version is correct" 로 거부한다.
YML_VERSION="$(grep -E '^_version:' "${HARBOR_DIR}/harbor.yml.tmpl" 2>/dev/null | awk '{print $2}')"
[[ -n "$YML_VERSION" ]] || die "harbor.yml.tmpl 에서 _version 을 읽지 못했다"
ok "harbor.yml 스키마 버전: ${YML_VERSION}"

sed -e "s|__HARBOR_HOSTNAME__|${HARBOR_HOST}|g" \
    -e "s|__HARBOR_DIR__|${HARBOR_DIR}|g" \
    -e "s|__HARBOR_DATA_DIR__|${HARBOR_DATA_DIR}|g" \
    -e "s|__HARBOR_ADMIN_PASSWORD__|${HARBOR_ADMIN_PASSWORD}|g" \
    -e "s|__HARBOR_DB_PASSWORD__|${HARBOR_DB_PASSWORD}|g" \
    -e "s|__HARBOR_YML_VERSION__|${YML_VERSION}|g" \
    "${CONF_DIR}/harbor.yml.tmpl" > "${HARBOR_DIR}/harbor.yml"
chmod 0600 "${HARBOR_DIR}/harbor.yml"   # admin/DB 비밀번호가 들어 있다
ok "harbor.yml 생성 (0600)"

#=====================================================================
# 5. 이미지 적재 + prepare + 기동
#
# Harbor 공식 install.sh 를 쓴다. 이미지 load, prepare(compose 파일 생성),
# docker compose up 을 순서대로 수행한다. 우리가 직접 재현하면 업스트림이
# 검증한 절차와 어긋날 수 있다.
#
# --with-trivy 는 주지 않는다. 에어갭에서 취약점 DB 를 갱신할 수 없어
# 실효가 없고 컨테이너와 메모리만 늘어난다. 필요하면 아래 줄에 추가한다.
#=====================================================================
step "Harbor 공식 인스톨러 실행 (이미지 적재 + prepare + 기동)"

pushd "$HARBOR_DIR" >/dev/null
if ! ./install.sh 2>&1 | tee /var/log/harbor-install.log | tail -20; then
    popd >/dev/null
    die "Harbor install.sh 실패. 전체 로그: /var/log/harbor-install.log"
fi
popd >/dev/null
ok "인스톨러 완료 (로그: /var/log/harbor-install.log)"

#=====================================================================
# 6. systemd 등록
#
# 반드시 필요하다. Docker 재시작 정책만으로는 harbor-log(1514)가 먼저
# 뜨는 것을 보장하지 못해 부팅 시 대부분의 컨테이너가 exit 128 로 죽는다.
#=====================================================================
step "systemd 유닛 등록"

sed "s|__HARBOR_DIR__|${HARBOR_DIR}|g" "${CONF_DIR}/harbor-start.sh" \
    > /tmp/harbor-start.sh
install -m 0755 /tmp/harbor-start.sh /usr/local/bin/harbor-start.sh
rm -f /tmp/harbor-start.sh
ok "/usr/local/bin/harbor-start.sh"

sed "s|__HARBOR_DIR__|${HARBOR_DIR}|g" "${CONF_DIR}/harbor.service" \
    > /tmp/harbor.service
install -m 0644 /tmp/harbor.service /etc/systemd/system/harbor.service
rm -f /tmp/harbor.service
systemctl daemon-reload
systemctl enable harbor.service >/dev/null 2>&1
ok "harbor.service enabled (부팅 시 자동 기동)"

# 인스톨러가 이미 띄워 둔 상태이므로 유닛을 start 하면 멱등하게 수렴한다.
# RemainAfterExit=yes 인 oneshot 이라 상태 추적도 가능해진다.
systemctl start harbor.service >/dev/null 2>&1 || warn "harbor.service start 경고. 상태를 확인할 것."

if ! retry_until 300 bash -c "curl -sk -o /dev/null --max-time 5 https://127.0.0.1/api/v2.0/health"; then
    dc logs --tail 30 >&2 || true
    die "Harbor API 가 응답하지 않는다. 위 로그와 /var/log/harbor-install.log 를 확인할 것."
fi
ok "API 응답 확인"

#=====================================================================
# 7. 판정
#=====================================================================
run_checks
rc=$?

step "다음 단계"
if [[ "${GENERATED_PW:-0}" == 1 ]]; then
    echo
    warn "자격증명을 무작위 생성했다. 아래 값을 안전한 곳에 보관할 것."
    echo "    admin 비밀번호 = ${HARBOR_ADMIN_PASSWORD}"
    echo "    DB 비밀번호    = ${HARBOR_DB_PASSWORD}"
    echo "    (${CRED_FILE} 에 0600 으로 저장돼 있다)"
    echo
fi
echo "  레지스트리: https://${HARBOR_HOST}      (admin)"
echo
echo "  다른 노드에서 쓰려면 두 가지가 필요하다:"
echo "    1) /etc/hosts 에  ${HARBOR_HOST_IP} ${HARBOR_HOST}"
echo "    2) 인증서 신뢰:   /etc/docker/certs.d/${HARBOR_HOST}/ca.crt"
echo "       (이 노드의 ${CERT_DIR}/harbor.crt 를 복사)"
echo "       containerd(k8s)용 설정은 README 6절 참고"
echo
echo "  재기동 검증: sudo ./install.sh --test-restart"
echo "  재판정:      sudo ./install.sh --check-only"
echo "  상태:        systemctl status harbor ; cd ${HARBOR_DIR} && docker compose ps"
exit $rc
