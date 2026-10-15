#!/usr/bin/env bash
# Redis OSS 단일 노드 오프라인 설치
BUNDLE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_FILE="${BUNDLE_ROOT}/00-common/common.sh"
[[ -f "$COMMON_FILE" ]] || { echo "ERROR: 공통 파일 없음: $COMMON_FILE" >&2; exit 1; }
source "$COMMON_FILE"

case "${1:-}" in
    --check-only) MODE=check ;;
    --test-restart) MODE=restart-test ;;
    --uninstall) MODE=uninstall ;;
    "") MODE=install ;;
    *) die "알 수 없는 인자: $1 (--check-only | --test-restart | --uninstall)" ;;
esac
require_root

CONF_DIR="${BUNDLE_ROOT}/conf"
IMG_DIR="${BUNDLE_ROOT}/images"
REDIS_DIR="/opt/redis"
CERT_DIR="${REDIS_DIR}/certs"
REDIS_DATA_DIR="${REDIS_DATA_DIR:-/data/redis}"
REDIS_PORT="${REDIS_PORT:-6379}"
REDIS_HOSTNAME="${REDIS_HOSTNAME:-redis.local}"
REDIS_HOST_IP="${REDIS_HOST_IP:-$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')}"
[[ -n "$REDIS_HOST_IP" ]] || REDIS_HOST_IP="$(hostname -I | awk '{print $1}')"
COMPOSE_FILE="${REDIS_DIR}/docker-compose.yml"
REDIS_CONF="${REDIS_DIR}/redis.conf"
CONTAINER=redis

dc() { docker compose -f "$COMPOSE_FILE" "$@"; }
redisq() {
    docker exec "$CONTAINER" sh -ec '
        REDISCLI_AUTH="$(sed -n "s/^requirepass //p" /usr/local/etc/redis/redis.conf)"
        export REDISCLI_AUTH
        exec redis-cli --tls --cacert /etc/redis/certs/ca.crt -h localhost -p 6379 "$@"
    ' redis-cli "$@"
}
redis_roundtrip() {
    local value
    value="$(redisq set offline-install-smoke offline-install-redis 2>/dev/null)" || return 1
    [[ "$value" == OK ]] || return 1
    value="$(redisq get offline-install-smoke 2>/dev/null)" || return 1
    [[ "$value" == offline-install-redis ]] || return 1
    redisq del offline-install-smoke >/dev/null
}

run_checks() {
    step "Redis 설치 상태 판정"
    check "docker 사용 가능" docker info
    check "docker compose 사용 가능" bash -c "docker compose version >/dev/null 2>&1"
    check "이미지 적재됨" docker image inspect "$REDIS_IMAGE"
    check "compose 파일 존재" test -f "$COMPOSE_FILE"
    check "Redis 설정 권한 0600" bash -c "[[ \$(stat -c %a '$REDIS_CONF' 2>/dev/null) == 600 ]]"
    check "TLS 인증서와 CA 존재" bash -c "test -s '$CERT_DIR/server.crt' -a -s '$CERT_DIR/server.key' -a -s '$CERT_DIR/ca.crt'"
    check "데이터 디렉터리 존재" test -d "$REDIS_DATA_DIR"
    check "compose 설정 유효" bash -c "docker compose -f '$COMPOSE_FILE' config >/dev/null 2>&1"
    check "컨테이너 실행 중" bash -c "[[ \$(docker inspect -f '{{.State.Status}}' '$CONTAINER' 2>/dev/null) == running ]]"
    check "재시작 정책 unless-stopped" bash -c "[[ \$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' '$CONTAINER' 2>/dev/null) == unless-stopped ]]"
    check "TLS 포트 ${REDIS_PORT} 수신" bash -c "ss -lnt | grep -qE ':${REDIS_PORT}([[:space:]]|$)'"
    check "인증된 TLS PING" retry_until 60 redisq ping
    check "TLS SET/GET/DEL 왕복" redis_roundtrip
    check "호스트 데이터 볼륨 마운트" bash -c "
        docker inspect -f '{{range .Mounts}}{{if eq .Destination \"/data\"}}{{.Source}}{{end}}{{end}}' '$CONTAINER' \
          | grep -qxF '$REDIS_DATA_DIR'"
    local version
    version="$(redisq INFO server 2>/dev/null | sed -n 's/^redis_version://p' | tr -d '\r' | head -1)"
    log "Redis OSS 버전=${version:-?} / TLS 포트=${REDIS_PORT} / 데이터=${REDIS_DATA_DIR}"
    check_summary
}

do_restart_test() {
    step "자동 복구 실동작 검증"
    local before after pid
    before="$(docker inspect -f '{{.RestartCount}}' "$CONTAINER" 2>/dev/null)" || die "컨테이너가 없다"
    pid="$(docker inspect -f '{{.State.Pid}}' "$CONTAINER")"
    [[ -n "$pid" && "$pid" != 0 ]] || die "컨테이너 PID 를 확인할 수 없다"
    kill -9 "$pid" || die "컨테이너 프로세스 종료 실패"
    retry_until 120 bash -c "
        rc=\$(docker inspect -f '{{.RestartCount}}' '$CONTAINER' 2>/dev/null || echo 0)
        st=\$(docker inspect -f '{{.State.Status}}' '$CONTAINER' 2>/dev/null || echo none)
        [[ \$rc -gt $before && \$st == running ]]" \
        || die "프로세스 사고사 후 자동 복구 실패"
    after="$(docker inspect -f '{{.RestartCount}}' "$CONTAINER")"
    ok "프로세스 사고사 후 자동 복구 (RestartCount ${before} -> ${after})"
    retry_until 90 redisq ping || die "복구 후 Redis TLS 응답 실패"
    if systemctl list-unit-files --no-legend docker.service 2>/dev/null | grep -q '^docker.service'; then
        systemctl restart docker || die "docker 데몬 재시작 실패"
        retry_until 120 bash -c "[[ \$(docker inspect -f '{{.State.Status}}' '$CONTAINER' 2>/dev/null) == running ]]" \
            || die "docker 데몬 재시작 후 컨테이너가 복구되지 않았다"
        retry_until 90 redisq ping || die "데몬 재시작 후 Redis 응답 실패"
        ok "docker 재시작 후 Redis 복구"
    else
        warn "docker.service 가 없어 데몬 재시작 검증을 건너뛴다. 컨테이너 사고사 검증은 통과했다."
    fi
}

do_uninstall() {
    [[ -f "$COMPOSE_FILE" ]] && dc down >/dev/null 2>&1 || true
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    ok "컨테이너 제거. 설정(${REDIS_DIR})과 데이터(${REDIS_DATA_DIR})는 보존한다."
}

if [[ "$MODE" == uninstall ]]; then do_uninstall; exit; fi
if [[ "$MODE" == restart-test ]]; then do_restart_test; exit; fi
if [[ "$MODE" == check ]]; then run_checks; exit $?; fi

step "사전 확인"
verify_manifest "$BUNDLE_ROOT"
require_cmds docker openssl
docker info >/dev/null 2>&1 || die "docker 가 동작하지 않는다. 10-k8s 설치를 확인할 것."
docker compose version >/dev/null 2>&1 || die "docker compose 플러그인이 없다."
if [[ ! "$REDIS_PORT" =~ ^[0-9]{1,5}$ ]] || ((REDIS_PORT < 1 || REDIS_PORT > 65535)); then
    die "REDIS_PORT 값이 유효하지 않다"
fi
[[ "$REDIS_HOST_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "REDIS_HOST_IP 를 IPv4 주소로 설정할 것"
[[ "$REDIS_DATA_DIR" =~ ^/[A-Za-z0-9_./-]+$ && "$REDIS_DATA_DIR" != *".."* ]] \
    || die "REDIS_DATA_DIR 는 공백 없는 단순 절대 경로여야 한다"
[[ "$REDIS_HOSTNAME" =~ ^[A-Za-z0-9.-]+$ ]] || die "REDIS_HOSTNAME 값이 유효하지 않다"
if ss -lnt | grep -qE ":${REDIS_PORT}([[:space:]]|$)"; then
    docker inspect "$CONTAINER" >/dev/null 2>&1 || die "포트 ${REDIS_PORT} 를 다른 프로세스가 사용 중이다"
fi

step "이미지 적재"
shopt -s nullglob
for tar in "${IMG_DIR}"/*.tar; do docker load -i "$tar" >/dev/null || die "docker load 실패: $tar"; done
shopt -u nullglob
docker image inspect "$REDIS_IMAGE" >/dev/null 2>&1 || die "이미지가 적재되지 않았다: ${REDIS_IMAGE}"

step "데이터·인증서·Redis 설정"
install -d -m 0755 "$REDIS_DIR"
install -d -m 0700 "$CERT_DIR" "$REDIS_DATA_DIR"
chown -R 999:999 "$REDIS_DATA_DIR"

PKI_REDIS="${PKI_DIR:-/opt/pki}/redis"
if [[ -s "$PKI_REDIS/server.crt" && -s "$PKI_REDIS/server.key" ]]; then
    install -m 0644 "$PKI_REDIS/server.crt" "$CERT_DIR/server.crt"
    install -m 0600 "$PKI_REDIS/server.key" "$CERT_DIR/server.key"
    if [[ -s "$PKI_REDIS/ca.crt" ]]; then
        install -m 0644 "$PKI_REDIS/ca.crt" "$CERT_DIR/ca.crt"
    elif [[ -s "${PKI_DIR:-/opt/pki}/ca/ca.crt" ]]; then
        install -m 0644 "${PKI_DIR:-/opt/pki}/ca/ca.crt" "$CERT_DIR/ca.crt"
    else
        die "Redis 서비스 인증서용 CA 를 찾지 못했다. 05-certs 를 먼저 배포할 것."
    fi
    log "05-certs 사내 CA 인증서를 사용한다"
elif [[ -s "$CERT_DIR/server.crt" && -s "$CERT_DIR/server.key" && -s "$CERT_DIR/ca.crt" ]]; then
    log "기존 로컬 TLS 인증서를 유지한다"
else
    log "Redis 서비스 인증서가 없어 로컬 CA/서버 인증서를 만든다"
    cert_tmp="$(mktemp -d)"
    openssl req -x509 -newkey rsa:3072 -nodes -days 3650 \
        -subj "/CN=Redis OSS local CA" -addext "basicConstraints=critical,CA:TRUE" \
        -keyout "${cert_tmp}/ca.key" -out "${CERT_DIR}/ca.crt" >/dev/null 2>&1 \
        || die "로컬 CA 생성 실패"
    openssl req -newkey rsa:2048 -nodes -subj "/CN=${REDIS_HOSTNAME}" \
        -keyout "${CERT_DIR}/server.key" -out "${cert_tmp}/server.csr" >/dev/null 2>&1 \
        || die "Redis 서버 키 생성 실패"
    printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:%s,DNS:localhost,IP:%s,IP:127.0.0.1\n' \
        "$REDIS_HOSTNAME" "$REDIS_HOST_IP" > "${cert_tmp}/server.ext"
    openssl x509 -req -in "${cert_tmp}/server.csr" -CA "${CERT_DIR}/ca.crt" \
        -CAkey "${cert_tmp}/ca.key" -CAcreateserial -days 825 -sha256 \
        -extfile "${cert_tmp}/server.ext" -out "${CERT_DIR}/server.crt" >/dev/null 2>&1 \
        || die "Redis 서버 인증서 발급 실패"
    rm -rf "$cert_tmp"
fi
chmod 0644 "$CERT_DIR/server.crt" "$CERT_DIR/ca.crt"
chmod 0600 "$CERT_DIR/server.key"
chown -R 999:999 "$CERT_DIR"

if [[ -f "$REDIS_CONF" ]]; then
    REDIS_PASSWORD="$(sed -n 's/^requirepass //p' "$REDIS_CONF" | head -1)"
else
    REDIS_PASSWORD="${REDIS_PASSWORD:-}"
    if [[ -z "$REDIS_PASSWORD" ]]; then
        REDIS_PASSWORD="$(openssl rand -hex 32)"
        REDIS_PASSWORD_GENERATED=1
    fi
    [[ "$REDIS_PASSWORD" =~ ^[A-Za-z0-9_-]{32,128}$ ]] \
        || die "REDIS_PASSWORD 는 영문자/숫자/밑줄/하이픈 32~128자로 설정할 것"
    cat > "$REDIS_CONF" <<EOF
bind 0.0.0.0
protected-mode yes
port 0
tls-port 6379
tls-cert-file /etc/redis/certs/server.crt
tls-key-file /etc/redis/certs/server.key
tls-auth-clients no
requirepass ${REDIS_PASSWORD}
dir /data
appendonly yes
appendfsync everysec
save 900 1
save 300 10
save 60 10000
EOF
fi
chmod 0600 "$REDIS_CONF"
chown 999:999 "$REDIS_CONF"

step "compose 생성 및 기동"
sed -e "s|__REDIS_IMAGE__|${REDIS_IMAGE}|g" \
    -e "s|__REDIS_BIND_IP__|${REDIS_HOST_IP}|g" \
    -e "s|__REDIS_PORT__|${REDIS_PORT}|g" \
    -e "s|__REDIS_DATA_DIR__|${REDIS_DATA_DIR}|g" \
    "$CONF_DIR/docker-compose.yml.tmpl" > "${COMPOSE_FILE}.new"
docker compose -f "${COMPOSE_FILE}.new" config >/dev/null 2>&1 \
    || { docker compose -f "${COMPOSE_FILE}.new" config; die "compose 설정이 유효하지 않다"; }
install_file "${COMPOSE_FILE}.new" "$COMPOSE_FILE" 0644
rm -f "${COMPOSE_FILE}.new"
dc up -d >/dev/null 2>&1 || { dc logs --tail 40 >&2; die "Redis 기동 실패"; }
retry_until 120 redisq ping || { dc logs --tail 40 >&2; die "Redis TLS/PING 확인 실패"; }
ok "Redis OSS 기동 및 TLS 인증 확인"
run_checks

step "다음 단계"
[[ "${REDIS_PASSWORD_GENERATED:-0}" == 1 ]] && log "무작위 비밀번호 생성 완료. 비밀번호: sudo grep '^requirepass ' ${REDIS_CONF}"
echo "접속: rediss://${REDIS_HOSTNAME}:${REDIS_PORT} (TLS, 인증 필수)"
echo "설정/비밀번호: ${REDIS_CONF} (0600)"
echo "자동 복구 검증: sudo ./install.sh --test-restart"
