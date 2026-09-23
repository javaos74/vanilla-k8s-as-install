#!/usr/bin/env bash
#---------------------------------------------------------------------
# 80-postgresql : 오프라인 설치 (에어갭 노드에서 root 로 실행)
#
#   sudo ./install.sh                  # 설치 + TLS 접속·쓰기 왕복 검증
#   sudo ./install.sh --check-only     # 판정만
#   sudo ./install.sh --test-restart   # 자동 복구 실동작 검증
#   sudo ./install.sh --uninstall      # 컨테이너 제거(데이터는 남긴다)
#
# 전제: 10-k8s 설치 완료(docker + docker compose).
#
# 결과: /opt/postgresql 에 PostgreSQL. TLS 활성, 5432 수신.
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
IMG_DIR="${BUNDLE_ROOT}/images"

PG_DIR="/opt/postgresql"
PG_DATA_DIR="${PG_DATA_DIR:-/data/postgresql}"
CERT_DIR="${PG_DIR}/certs"
COMPOSE_FILE="${PG_DIR}/docker-compose.yml"
ENV_FILE="${PG_DIR}/postgres.env"
CONTAINER="postgres"

PG_SUPERUSER="${PG_SUPERUSER:-postgres}"
PG_TZ="${PG_TZ:-Asia/Seoul}"
# hostname -d 는 도메인이 없을 때 오류가 아니라 **빈 문자열**을 반환한다.
# `|| echo local` 은 동작하지 않으므로(exit 0), 빈 값을 따로 처리해야 한다.
# 처리하지 않으면 "postgres." 처럼 끝에 점만 남는 이름이 만들어진다(실측).
_PG_DOMAIN="$(hostname -d 2>/dev/null || true)"
PG_HOSTNAME="${PG_HOSTNAME:-postgres${_PG_DOMAIN:+.${_PG_DOMAIN}}}"
PG_HOST_IP="${PG_HOST_IP:-$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')}"
[[ -n "$PG_HOST_IP" ]] || PG_HOST_IP="$(hostname -I | awk '{print $1}')"

SMOKE_DB="pg_smoke_test"

dc() { docker compose -f "$COMPOSE_FILE" "$@"; }

pg_pw() { grep -E '^POSTGRES_PASSWORD=' "$ENV_FILE" 2>/dev/null | cut -d= -f2-; }

#=====================================================================
# psql 실행 도우미
#
# 비밀번호는 -W 나 인자가 아니라 PGPASSWORD 환경변수로 넘긴다.
# 인자로 넘기면 호스트의 ps 출력에 노출된다.
#=====================================================================
psqlq() {
    docker exec -e PGPASSWORD="$(pg_pw)" "$CONTAINER" \
        psql -h 127.0.0.1 -U "$PG_SUPERUSER" -d postgres -tAc "$1"
}

# TLS 로 붙었는지까지 확인하는 질의. sslmode=require 를 명시한다.
psqlq_tls() {
    docker exec -e PGPASSWORD="$(pg_pw)" "$CONTAINER" \
        psql "sslmode=require host=127.0.0.1 user=${PG_SUPERUSER} dbname=postgres" -tAc "$1"
}

#=====================================================================
# 판정
#=====================================================================
run_checks() {
    step "설치 상태 판정"

    check "docker 사용 가능"         docker info
    check "docker compose 사용 가능"  bash -c "docker compose version >/dev/null 2>&1"
    check "이미지 적재됨"             bash -c "docker image inspect '$POSTGRES_IMAGE' >/dev/null 2>&1"
    check "compose 파일 존재"         test -f "$COMPOSE_FILE"
    check "env 파일 권한 0600"        bash -c "[[ \$(stat -c %a '$ENV_FILE' 2>/dev/null) == 600 ]]"
    check "TLS 인증서 존재"           bash -c "test -f '${CERT_DIR}/server.crt' -a -f '${CERT_DIR}/server.key'"
    check "데이터 디렉터리 존재"       test -d "$PG_DATA_DIR"
    check "compose 설정 문법 유효"     bash -c "docker compose -f '$COMPOSE_FILE' config >/dev/null 2>&1"

    check "컨테이너 실행 중(크래시 루프 아님)" bash -c "
        [[ \$(docker inspect -f '{{.State.Status}}' '$CONTAINER' 2>/dev/null) == running ]] || exit 1
        p1=\$(docker inspect -f '{{.State.Pid}}' '$CONTAINER' 2>/dev/null)
        sleep 10
        p2=\$(docker inspect -f '{{.State.Pid}}' '$CONTAINER' 2>/dev/null)
        [[ -n \"\$p1\" && \"\$p1\" != 0 && \"\$p1\" == \"\$p2\" ]]"
    check "재시작 정책 unless-stopped" bash -c "
        [[ \$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' '$CONTAINER' 2>/dev/null) == unless-stopped ]]"
    check "호스트 ${POSTGRES_PORT} 수신" retry_until 90 bash -c "ss -lnt | grep -qE ':${POSTGRES_PORT}\b'"

    # 인증서 소유권. postgres 는 키 파일이 자기 소유가 아니거나 권한이 넓으면
    # 기동을 거부한다. 기동 실패 원인 중 가장 흔하다.
    check "인증서가 컨테이너 uid(${POSTGRES_UID}) 소유" bash -c "
        [[ \$(stat -c %u '${CERT_DIR}/server.key') == '${POSTGRES_UID}' ]]"
    check "server.key 권한이 0600" bash -c "
        [[ \$(stat -c %a '${CERT_DIR}/server.key') == 600 ]]"
    check "인증서 SAN 에 ${PG_HOSTNAME} 포함" bash -c "
        openssl x509 -in '${CERT_DIR}/server.crt' -noout -text \
          | grep -A1 'Subject Alternative Name' | grep -q '${PG_HOSTNAME}'"

    #--- 서버 구성 확인 -------------------------------------------------
    check "pg_isready" retry_until 120 bash -c "docker exec '$CONTAINER' pg_isready -U '${PG_SUPERUSER}' -d postgres"
    check "psql 접속" retry_until 120 psqlq "SELECT 1"

    local ver ssl_on pw_enc chk
    ver="$(psqlq "SHOW server_version" 2>/dev/null | tr -d '\r' | head -1)"
    ssl_on="$(psqlq "SHOW ssl" 2>/dev/null | tr -d '\r' | head -1)"
    pw_enc="$(psqlq "SHOW password_encryption" 2>/dev/null | tr -d '\r' | head -1)"
    chk="$(psqlq "SHOW data_checksums" 2>/dev/null | tr -d '\r' | head -1)"
    log "버전=${ver:-?} / ssl=${ssl_on:-?} / password_encryption=${pw_enc:-?} / data_checksums=${chk:-?}"

    # AS 의 temporal-sql-tool 이 SQL_TLS=true 로 붙는다. ssl=off 면 실패한다.
    check "ssl=on (AS 의 SQL_TLS=true 요구)" bash -c "[[ '${ssl_on}' == 'on' ]]"
    check "password_encryption=scram-sha-256" bash -c "[[ '${pw_enc}' == 'scram-sha-256' ]]"
    check "data_checksums=on" bash -c "[[ '${chk}' == 'on' ]]"

    #--- TLS 로 실제 접속되는지 -----------------------------------------
    # SHOW ssl 은 "서버가 TLS 를 켰다"까지만 알려준다. 실제로 TLS 세션이
    # 성립하는지는 sslmode=require 로 붙어 봐야 안다.
    step "TLS 접속 검증"
    check "sslmode=require 로 접속 성공" retry_until 60 psqlq_tls "SELECT 1"
    check "세션이 실제로 암호화됨(pg_stat_ssl)" bash -c "
        docker exec -e PGPASSWORD='$(pg_pw)' '$CONTAINER' \
          psql \"sslmode=require host=127.0.0.1 user=${PG_SUPERUSER} dbname=postgres\" \
          -tAc \"SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()\" 2>/dev/null \
          | tr -d '\r' | grep -qx t"

    #--- DB 왕복 -------------------------------------------------------
    step "데이터베이스 왕복 검증"

    psqlq "DROP DATABASE IF EXISTS ${SMOKE_DB}" >/dev/null 2>&1 || true
    check "DB 생성" psqlq "CREATE DATABASE ${SMOKE_DB}"
    check "테이블 생성 및 INSERT" bash -c "
        docker exec -e PGPASSWORD='$(pg_pw)' '$CONTAINER' \
          psql -h 127.0.0.1 -U '${PG_SUPERUSER}' -d '${SMOKE_DB}' -tAc \
          \"CREATE TABLE t(v text); INSERT INTO t VALUES ('offline-install');\""
    check "SELECT 로 값 확인" bash -c "
        docker exec -e PGPASSWORD='$(pg_pw)' '$CONTAINER' \
          psql -h 127.0.0.1 -U '${PG_SUPERUSER}' -d '${SMOKE_DB}' -tAc \
          'SELECT v FROM t' 2>/dev/null | tr -d '\r' | grep -qx offline-install"
    # 데이터가 호스트 볼륨에 떨어졌는지. 컨테이너 안에만 있으면 재생성 시 소실.
    check "호스트 볼륨에 데이터 기록됨" bash -c "
        test -d '${PG_DATA_DIR}/pgdata/base'"

    psqlq "DROP DATABASE IF EXISTS ${SMOKE_DB}" >/dev/null 2>&1 || true

    log "접속: postgresql://${PG_SUPERUSER}@${PG_HOSTNAME}:${POSTGRES_PORT}/postgres?sslmode=require"
    log "자격증명: ${ENV_FILE}"
    check_summary
}

#=====================================================================
# 자동 복구 검증
#=====================================================================
do_restart_test() {
    step "자동 복구 실동작 검증"

    local before after pid
    before="$(docker inspect -f '{{.RestartCount}}' "$CONTAINER" 2>/dev/null)" \
        || die "컨테이너 ${CONTAINER} 가 없다"
    log "현재 RestartCount=${before}"

    # docker kill 을 쓰면 안 된다. 수동 정지로 기록되어 unless-stopped 가
    # 재시작하지 않는다(40-haproxy 에서 실측).
    pid="$(docker inspect -f '{{.State.Pid}}' "$CONTAINER")"
    [[ -n "$pid" && "$pid" != "0" ]] || die "컨테이너 PID 를 확인할 수 없다"
    log "호스트에서 컨테이너 PID ${pid} 에 SIGKILL"
    kill -9 "$pid" || die "kill 실패"

    # RestartCount 가 늘어나는 것을 기다린다. status == running 을 기다리면 안 된다.
    # kill 직후에는 docker 가 아직 죽음을 인지하지 못해 status 가 그대로 running 이고,
    # 그러면 retry_until 이 첫 폴링에서 즉시 통과한 뒤 RestartCount=0 을 읽어
    # 거짓 실패가 된다. 컨테이너가 클수록(예: SQL Server) 이 경쟁에서 지기 쉽다.
    # 실측: mssql 은 이 이유로 실패했고 postgres/haproxy 는 우연히 통과했다.
    if retry_until 180 bash -c "
        rc=\$(docker inspect -f '{{.RestartCount}}' '${CONTAINER}' 2>/dev/null || echo 0)
        st=\$(docker inspect -f '{{.State.Status}}' '${CONTAINER}' 2>/dev/null || echo none)
        [[ \"\$rc\" -gt ${before} && \"\$st\" == running ]]"; then
        after="$(docker inspect -f '{{.RestartCount}}' "$CONTAINER")"
        ok "프로세스 사고사 후 자동 복구 (RestartCount ${before} -> ${after})"
    else
        die "자동 복구되지 않았다. 재시작 정책을 확인할 것."
    fi
    # SIGKILL 이후에는 crash recovery 가 돌아간다. 넉넉히 기다린다.
    retry_until 180 psqlq "SELECT 1" \
        && ok "복구 후 psql 응답 정상" || die "복구됐지만 psql 이 응답하지 않는다"

    step "docker 데몬 재시작 후 복구 (재부팅 대리 검증)"
    systemctl restart docker || die "docker 데몬 재시작 실패"
    retry_until 150 bash -c "[[ \$(docker inspect -f '{{.State.Status}}' '$CONTAINER' 2>/dev/null) == running ]]" \
        && ok "데몬 재시작 후 복구됨" || die "데몬 재시작 후 올라오지 않았다"
    retry_until 180 psqlq "SELECT 1" \
        && ok "psql 응답 정상" || die "복구됐지만 psql 이 응답하지 않는다"
    exit 0
}

do_uninstall() {
    step "PostgreSQL 제거"
    [[ -f "$COMPOSE_FILE" ]] && dc down >/dev/null 2>&1 || true
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    ok "컨테이너 제거. 설정(${PG_DIR})과 데이터(${PG_DATA_DIR})는 남겨둔다."
    log "데이터까지 지우려면: rm -rf ${PG_DATA_DIR}"
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

require_cmds docker openssl
docker info >/dev/null 2>&1 || die "docker 가 동작하지 않는다. 10-k8s 설치를 확인할 것."
docker compose version >/dev/null 2>&1 || die "docker compose 플러그인이 없다."
ok "docker $(docker --version | awk '{print $3}' | tr -d ,) / compose $(docker compose version --short 2>/dev/null)"

if ss -lnt | grep -qE ":${POSTGRES_PORT}\b"; then
    docker inspect -f '{{.State.Running}}' "$CONTAINER" >/dev/null 2>&1 \
        || die "포트 ${POSTGRES_PORT} 를 다른 프로세스가 쓰고 있다: $(ss -lntp | grep -E ":${POSTGRES_PORT}\b" | head -1)"
fi
ok "포트 ${POSTGRES_PORT} 사용 가능"

log "접속 이름=${PG_HOSTNAME} / 주소=${PG_HOST_IP}"

#=====================================================================
# 1. 이미지 적재
#=====================================================================
step "이미지 적재 (docker)"
shopt -s nullglob
for tar in "${IMG_DIR}"/*.tar; do
    log "docker load: $(basename "$tar")"
    docker load -i "$tar" >/dev/null || die "docker load 실패: $tar"
done
shopt -u nullglob
docker image inspect "$POSTGRES_IMAGE" >/dev/null 2>&1 \
    || die "적재되지 않은 이미지: ${POSTGRES_IMAGE}"
ok "이미지 적재 확인: ${POSTGRES_IMAGE}"

#=====================================================================
# 2. 디렉터리 / 자격증명
#=====================================================================
step "디렉터리 및 자격증명"

install -d -m 0755 "$PG_DIR"
install -d -m 0700 "$CERT_DIR"
install -d -m 0700 "$PG_DATA_DIR"
chown -R "${POSTGRES_UID}:${POSTGRES_UID}" "$PG_DATA_DIR"
ok "디렉터리: ${PG_DIR}, ${PG_DATA_DIR}"

if [[ -f "$ENV_FILE" ]]; then
    ok "기존 env 파일 사용: ${ENV_FILE}"
    PG_PASSWORD="$(pg_pw)"
else
    if [[ -z "${PG_PASSWORD:-}" ]]; then
        PG_PASSWORD="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 24)"
        GENERATED_PW=1
    fi
    sed -e "s|__PG_SUPERUSER__|${PG_SUPERUSER}|g" \
        -e "s|__PG_PASSWORD__|${PG_PASSWORD}|g" \
        -e "s|__PG_TZ__|${PG_TZ}|g" \
        "${CONF_DIR}/postgres.env.tmpl" > "$ENV_FILE"
    chmod 0600 "$ENV_FILE"
    ok "env 파일 생성: ${ENV_FILE} (0600)"
fi

#=====================================================================
# 3. TLS 인증서
#
# postgres 는 키 파일이 자기 소유가 아니거나 권한이 넓으면 기동을 거부한다.
#   FATAL: private key file "..." has group or world access
# 그래서 소유권을 컨테이너 uid 로, 권한을 0600 으로 맞춘다.
#=====================================================================
step "TLS 인증서"

# 05-certs 로 발급한 사내 CA 인증서가 있으면 그것을 쓴다.
PKI_PG="${PKI_DIR:-/opt/pki}/pgsql"
if [[ -f "${PKI_PG}/server.crt" && -f "${PKI_PG}/server.key" ]]; then
    install -m 0644 "${PKI_PG}/server.crt" "${CERT_DIR}/server.crt"
    install -m 0600 "${PKI_PG}/server.key" "${CERT_DIR}/server.key"
    [[ -f "${PKI_PG}/ca.crt" ]] && install -m 0644 "${PKI_PG}/ca.crt" "${CERT_DIR}/ca.crt"
    ok "사내 CA 발급 인증서 사용 (${PKI_PG})"
elif [[ -f "${CERT_DIR}/server.crt" && -f "${CERT_DIR}/server.key" ]]; then
    ok "기존 인증서 사용 (만료: $(openssl x509 -in "${CERT_DIR}/server.crt" -noout -enddate | cut -d= -f2))"
else
    sed -e "s|__PG_HOSTNAME__|${PG_HOSTNAME}|g" \
        -e "s|__PG_HOST_IP__|${PG_HOST_IP}|g" \
        "${CONF_DIR}/pg-openssl.cnf.tmpl" > /tmp/pg-openssl.cnf
    openssl req -x509 -nodes -days 3650 -newkey rsa:4096 \
        -keyout "${CERT_DIR}/server.key" \
        -out    "${CERT_DIR}/server.crt" \
        -config /tmp/pg-openssl.cnf >/dev/null 2>&1 \
        || die "인증서 생성 실패"
    rm -f /tmp/pg-openssl.cnf
    ok "자가서명 인증서 생성 (SAN: ${PG_HOSTNAME}, ${PG_HOST_IP}, localhost, 127.0.0.1)"
fi

chmod 0644 "${CERT_DIR}/server.crt"
chmod 0600 "${CERT_DIR}/server.key"
chown -R "${POSTGRES_UID}:${POSTGRES_UID}" "$CERT_DIR"
ok "인증서 소유권 ${POSTGRES_UID}:${POSTGRES_UID}, server.key 0600"

#=====================================================================
# 4. compose 생성 및 기동
#=====================================================================
step "compose 파일 생성"

sed -e "s|__POSTGRES_IMAGE__|${POSTGRES_IMAGE}|g" \
    -e "s|__POSTGRES_PORT__|${POSTGRES_PORT}|g" \
    -e "s|__PG_DIR__|${PG_DIR}|g" \
    -e "s|__PG_DATA_DIR__|${PG_DATA_DIR}|g" \
    -e "s|__PG_TZ__|${PG_TZ}|g" \
    "${CONF_DIR}/docker-compose.yml.tmpl" > "${COMPOSE_FILE}.new"

docker compose -f "${COMPOSE_FILE}.new" config >/dev/null 2>&1 \
    || { docker compose -f "${COMPOSE_FILE}.new" config; die "생성된 compose 파일이 유효하지 않다"; }
ok "compose 문법 검사 통과"

install_file "${COMPOSE_FILE}.new" "$COMPOSE_FILE" 0644
rm -f "${COMPOSE_FILE}.new"

step "컨테이너 기동"
dc up -d >/dev/null 2>&1 || { dc logs --tail 30; die "기동 실패"; }

if ! retry_until 180 bash -c "docker exec '$CONTAINER' pg_isready -U '${PG_SUPERUSER}' -d postgres >/dev/null 2>&1"; then
    dc logs --tail 40 >&2 || true
    die "$(cat <<'MSG'
PostgreSQL 이 응답하지 않는다. 위 로그를 확인할 것.

흔한 원인:
  - 인증서 소유권/권한 문제
      FATAL: private key file has group or world access
    -> server.key 는 컨테이너 uid 소유 + 0600 이어야 한다
  - 데이터 디렉터리에 다른 내용이 있어 initdb 가 거부
  - shared_buffers 가 shm_size 보다 큼
MSG
)"
fi
ok "PostgreSQL 기동 및 pg_isready 확인"

#=====================================================================
# 5. 판정
#=====================================================================
run_checks
rc=$?

step "다음 단계"
if [[ "${GENERATED_PW:-0}" == 1 ]]; then
    echo
    warn "비밀번호를 무작위 생성했다. 아래 값을 안전한 곳에 보관할 것."
    echo "    ${PG_SUPERUSER} / ${PG_PASSWORD}"
    echo "    (${ENV_FILE} 에 0600 으로 저장돼 있다)"
    echo
fi
echo "  접속: postgresql://${PG_SUPERUSER}@${PG_HOSTNAME}:${POSTGRES_PORT}/postgres?sslmode=require"
echo
echo "  UiPath AS 에 연결할 때:"
echo "    - TLS 가 켜져 있어야 한다 (temporal-sql-tool 이 SQL_TLS=true)"
echo "    - 자가서명으로 충분하다 (SQL_TLS_DISABLE_HOST_VERIFICATION=true)"
echo "    - 슈퍼유저를 직접 쓰지 말고 AS 전용 롤·DB 를 만들 것"
echo
echo "  자동 복구 검증: sudo ./install.sh --test-restart"
echo "  재판정:         sudo ./install.sh --check-only"
exit $rc
