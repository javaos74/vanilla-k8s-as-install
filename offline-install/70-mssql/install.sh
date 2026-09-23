#!/usr/bin/env bash
#---------------------------------------------------------------------
# 70-mssql : 오프라인 설치 (에어갭 노드에서 root 로 실행)
#
#   sudo ./install.sh                  # 설치 + FTS 실동작 검증
#   sudo ./install.sh --check-only     # 판정만
#   sudo ./install.sh --test-restart   # 자동 복구 실동작 검증
#   sudo ./install.sh --uninstall      # 컨테이너 제거(데이터는 남긴다)
#
# 전제: 10-k8s 설치 완료(docker + docker compose), 메모리 4GB 이상 권장.
#
# 결과: /opt/mssql 에 SQL Server 2022(FTS 포함). 1433 수신.
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

MSSQL_DIR="/opt/mssql"
MSSQL_DATA_DIR="${MSSQL_DATA_DIR:-/data/mssql}"
COMPOSE_FILE="${MSSQL_DIR}/docker-compose.yml"
ENV_FILE="${MSSQL_DIR}/mssql.env"
CONTAINER="mssql"

# 에디션과 메모리 상한. site.env 로 덮어쓸 수 있다.
MSSQL_PID="${MSSQL_PID:-${MSSQL_PID_DEFAULT}}"
MSSQL_MEM_LIMIT="${MSSQL_MEM_LIMIT:-4g}"
MSSQL_TZ="${MSSQL_TZ:-Asia/Seoul}"

dc() { docker compose -f "$COMPOSE_FILE" "$@"; }

sa_pw() { grep -E '^MSSQL_SA_PASSWORD=' "$ENV_FILE" 2>/dev/null | cut -d= -f2-; }

#=====================================================================
# sqlcmd 실행 도우미
#
# sqlcmd 는 이미지 안에 있지만 PATH 에 없다(실측). 절대경로를 쓴다.
# -C : 자가서명 인증서를 신뢰. mssql-tools18 은 기본이 암호화 필수이므로
#      이것이 없으면 연결 자체가 실패한다.
# -b : 오류 시 0 이 아닌 종료코드. 없으면 SQL 오류가 나도 exit 0 이 되어
#      판정이 통과해버린다.
# 비밀번호는 -P 인자로 넘기지 않고 컨테이너 환경변수에서 읽게 한다.
# 인자로 넘기면 호스트의 ps 출력에 노출된다.
#=====================================================================
sqlq() {
    docker exec -e SQLCMDPASSWORD="$(sa_pw)" "$CONTAINER" \
        "$MSSQL_SQLCMD" -S localhost -U sa -C -b -h -1 -W -Q "$1"
}

# 값 하나를 조용히 가져온다(판정 메시지에 쓰기 위함).
sqlv() { sqlq "$1" 2>/dev/null | head -1 | tr -d '\r'; }

#=====================================================================
# 판정
#=====================================================================
run_checks() {
    step "설치 상태 판정"

    check "docker 사용 가능"         docker info
    check "docker compose 사용 가능"  bash -c "docker compose version >/dev/null 2>&1"
    check "이미지 적재됨"             bash -c "docker image inspect '$MSSQL_SERVER_IMAGE' >/dev/null 2>&1"
    check "compose 파일 존재"         test -f "$COMPOSE_FILE"
    check "env 파일 권한 0600"        bash -c "[[ \$(stat -c %a '$ENV_FILE' 2>/dev/null) == 600 ]]"
    check "데이터 디렉터리 존재"       test -d "$MSSQL_DATA_DIR"
    check "compose 설정 문법 유효"     bash -c "docker compose -f '$COMPOSE_FILE' config >/dev/null 2>&1"

    # 크래시 루프를 실행 중으로 오판하지 않도록 PID 유지까지 본다.
    # SQL Server 는 비밀번호 정책 위반이나 EULA 누락 시 기동 직후 종료된다.
    check "컨테이너 실행 중(크래시 루프 아님)" bash -c "
        [[ \$(docker inspect -f '{{.State.Status}}' '$CONTAINER' 2>/dev/null) == running ]] || exit 1
        p1=\$(docker inspect -f '{{.State.Pid}}' '$CONTAINER' 2>/dev/null)
        sleep 10
        p2=\$(docker inspect -f '{{.State.Pid}}' '$CONTAINER' 2>/dev/null)
        [[ -n \"\$p1\" && \"\$p1\" != 0 && \"\$p1\" == \"\$p2\" ]]"
    check "재시작 정책 unless-stopped" bash -c "
        [[ \$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' '$CONTAINER' 2>/dev/null) == unless-stopped ]]"
    check "호스트 ${MSSQL_PORT} 수신" retry_until 120 bash -c "ss -lnt | grep -qE ':${MSSQL_PORT}\b'"

    check "sqlcmd 존재(${MSSQL_SQLCMD})" \
        bash -c "docker exec '$CONTAINER' test -x '$MSSQL_SQLCMD'"

    #--- SQL 접속 및 구성 확인 ------------------------------------------
    check "sa 로 SQL 접속" retry_until 180 sqlq "SELECT 1"

    local ver edition coll fts
    ver="$(sqlv "SELECT CONVERT(varchar(32), SERVERPROPERTY('ProductVersion'))")"
    edition="$(sqlv "SELECT CONVERT(varchar(64), SERVERPROPERTY('Edition'))")"
    coll="$(sqlv "SELECT CONVERT(varchar(64), SERVERPROPERTY('Collation'))")"
    fts="$(sqlv "SELECT CONVERT(varchar(8), SERVERPROPERTY('IsFullTextInstalled'))")"
    log "버전=${ver:-?} / 에디션=${edition:-?}"
    log "collation=${coll:-?} / IsFullTextInstalled=${fts:-?}"

    # 여기가 이 단계의 존재 이유다. 공식 이미지는 이 값이 0 이다.
    check "Full-Text Search 설치됨(IsFullTextInstalled=1)" \
        bash -c "[[ '${fts}' == '1' ]]"

    # AS 는 특정 collation 을 요구한다. 최초 기동 시에만 적용되므로
    # 틀렸으면 데이터 디렉터리를 비우고 다시 초기화해야 한다.
    check "collation 이 ${MSSQL_COLLATION}" \
        bash -c "[[ '${coll}' == '${MSSQL_COLLATION}' ]]"

    #--- FTS 실동작 검증 ------------------------------------------------
    # SERVERPROPERTY 는 "설치됨"까지만 알려준다. 카탈로그·인덱스를 실제로
    # 만들고 CONTAINS 질의를 수행해야 동작을 증명할 수 있다.
    step "Full-Text Search 실동작 검증 (카탈로그 -> 인덱스 -> CONTAINS)"

    check "FTS 카탈로그·인덱스·CONTAINS 질의 성공" bash -c "
        docker exec -i -e SQLCMDPASSWORD='$(sa_pw)' '$CONTAINER' \
            '$MSSQL_SQLCMD' -S localhost -U sa -C -b < '${CONF_DIR}/verify-fts.sql' 2>&1 \
          | grep -q FTS_QUERY_OK"

    #--- DB 생성·쓰기 왕복 ----------------------------------------------
    step "데이터베이스 왕복 검증"

    check "DB 생성" sqlq "IF DB_ID('smoke_db') IS NULL CREATE DATABASE smoke_db"
    check "테이블 생성 및 INSERT" sqlq \
        "USE smoke_db; IF OBJECT_ID('t') IS NULL CREATE TABLE t(v NVARCHAR(64)); INSERT INTO t VALUES(N'offline-install');"
    check "SELECT 로 값 확인" bash -c "
        docker exec -e SQLCMDPASSWORD='$(sa_pw)' '$CONTAINER' \
            '$MSSQL_SQLCMD' -S localhost -U sa -C -b -h -1 -W \
            -Q \"USE smoke_db; SELECT TOP 1 v FROM t\" 2>/dev/null | grep -q offline-install"

    # 데이터가 호스트 볼륨에 떨어졌는지. 컨테이너 안에만 있으면 재생성 시 소실된다.
    check "호스트 볼륨에 DB 파일 기록됨" bash -c "
        ls '${MSSQL_DATA_DIR}'/data/smoke_db*.mdf >/dev/null 2>&1"

    sqlq "IF DB_ID('smoke_db') IS NOT NULL BEGIN ALTER DATABASE smoke_db SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE smoke_db; END" \
        >/dev/null 2>&1 || true

    if [[ "$MSSQL_PID" =~ ^([Dd]eveloper|[Ee]xpress|[Ee]valuation)$ ]]; then
        echo
        warn "에디션이 ${MSSQL_PID} 다. 평가·개발용이며 UiPath AS 운영에는"
        warn "Standard/Enterprise 가 필요하다. site.env 의 MSSQL_PID 로 바꿀 것."
    fi

    log "접속: <호스트>,${MSSQL_PORT}  (sa / ${ENV_FILE} 참고)"
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
    # SQL Server 는 복구 후 DB recovery 에 시간이 걸린다. 넉넉히 기다린다.
    retry_until 240 sqlq "SELECT 1" \
        && ok "복구 후 SQL 응답 정상" || die "복구됐지만 SQL 이 응답하지 않는다"

    step "docker 데몬 재시작 후 복구 (재부팅 대리 검증)"
    systemctl restart docker || die "docker 데몬 재시작 실패"
    retry_until 180 bash -c "[[ \$(docker inspect -f '{{.State.Status}}' '$CONTAINER' 2>/dev/null) == running ]]" \
        && ok "데몬 재시작 후 복구됨" || die "데몬 재시작 후 올라오지 않았다"
    retry_until 240 sqlq "SELECT 1" \
        && ok "SQL 응답 정상" || die "복구됐지만 SQL 이 응답하지 않는다"
    exit 0
}

do_uninstall() {
    step "SQL Server 제거"
    [[ -f "$COMPOSE_FILE" ]] && dc down >/dev/null 2>&1 || true
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    ok "컨테이너 제거. 설정(${MSSQL_DIR})과 데이터(${MSSQL_DATA_DIR})는 남겨둔다."
    log "데이터까지 지우려면: rm -rf ${MSSQL_DATA_DIR}"
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

# SQL Server 는 2GB 미만에서 기동하지 않는다. 먼저 잡는다.
MEM_MB="$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo)"
((MEM_MB >= 2048)) || die "메모리가 ${MEM_MB}MB 다. SQL Server 는 2GB 이상을 요구한다."
((MEM_MB >= 4096)) || warn "메모리 ${MEM_MB}MB. 동작은 하지만 4GB 이상을 권장한다."
ok "메모리 ${MEM_MB}MB"

if ss -lnt | grep -qE ":${MSSQL_PORT}\b"; then
    docker inspect -f '{{.State.Running}}' "$CONTAINER" >/dev/null 2>&1 \
        || die "포트 ${MSSQL_PORT} 를 다른 프로세스가 쓰고 있다: $(ss -lntp | grep -E ":${MSSQL_PORT}\b" | head -1)"
fi
ok "포트 ${MSSQL_PORT} 사용 가능"

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
docker image inspect "$MSSQL_SERVER_IMAGE" >/dev/null 2>&1 \
    || die "적재되지 않은 이미지: ${MSSQL_SERVER_IMAGE}"
ok "이미지 적재 확인: ${MSSQL_SERVER_IMAGE}"

# 적재된 이미지에 FTS 가 실제로 있는지. 여기서 걸러야 뒤 단계가 의미를 갖는다.
docker run --rm --entrypoint dpkg "$MSSQL_SERVER_IMAGE" -l mssql-server-fts 2>/dev/null \
    | grep -q '^ii' \
    || die "이미지에 mssql-server-fts 가 없다. FTS 없는 이미지로는 AS 설치가 진행되지 않는다."
ok "이미지에 Full-Text Search 포함 확인"

#=====================================================================
# 2. 디렉터리 / 자격증명
#=====================================================================
step "디렉터리 및 자격증명"

install -d -m 0755 "$MSSQL_DIR"
install -d -m 0755 "$MSSQL_DATA_DIR"
# 컨테이너의 mssql 사용자(uid 10001)가 써야 한다.
chown -R 10001:0 "$MSSQL_DATA_DIR" 2>/dev/null || true
ok "디렉터리: ${MSSQL_DIR}, ${MSSQL_DATA_DIR}"

if [[ -f "$ENV_FILE" ]]; then
    ok "기존 env 파일 사용: ${ENV_FILE}"
    MSSQL_SA_PASSWORD="$(sa_pw)"
else
    if [[ -z "${MSSQL_SA_PASSWORD:-}" ]]; then
        # SQL Server 정책: 8자 이상 + 대문자/소문자/숫자/기호 중 3종류 이상.
        # 정책을 만족하지 못하면 기동 직후 종료되고 로그에만 이유가 남는다.
        # 기호를 섞되 셸·URL 에서 문제되는 문자는 피한다.
        MSSQL_SA_PASSWORD="Aa1$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 20)#"
        GENERATED_PW=1
    fi
    ((${#MSSQL_SA_PASSWORD} >= 8)) || die "MSSQL_SA_PASSWORD 가 8자 미만이다. SQL Server 가 기동하지 않는다."

    sed -e "s|__MSSQL_SA_PASSWORD__|${MSSQL_SA_PASSWORD}|g" \
        -e "s|__MSSQL_PID__|${MSSQL_PID}|g" \
        -e "s|__MSSQL_COLLATION__|${MSSQL_COLLATION}|g" \
        -e "s|__MSSQL_TZ__|${MSSQL_TZ}|g" \
        "${CONF_DIR}/mssql.env.tmpl" > "$ENV_FILE"
    chmod 0600 "$ENV_FILE"
    ok "env 파일 생성: ${ENV_FILE} (0600)"
fi

#=====================================================================
# 3. compose 생성 및 기동
#=====================================================================
step "compose 파일 생성"

sed -e "s|__MSSQL_IMAGE__|${MSSQL_SERVER_IMAGE}|g" \
    -e "s|__MSSQL_DIR__|${MSSQL_DIR}|g" \
    -e "s|__MSSQL_DATA_DIR__|${MSSQL_DATA_DIR}|g" \
    -e "s|__MSSQL_PORT__|${MSSQL_PORT}|g" \
    -e "s|__MSSQL_MEM_LIMIT__|${MSSQL_MEM_LIMIT}|g" \
    -e "s|__MSSQL_SQLCMD__|${MSSQL_SQLCMD}|g" \
    "${CONF_DIR}/docker-compose.yml.tmpl" > "${COMPOSE_FILE}.new"

docker compose -f "${COMPOSE_FILE}.new" config >/dev/null 2>&1 \
    || { docker compose -f "${COMPOSE_FILE}.new" config; die "생성된 compose 파일이 유효하지 않다"; }
ok "compose 문법 검사 통과"

install_file "${COMPOSE_FILE}.new" "$COMPOSE_FILE" 0644
rm -f "${COMPOSE_FILE}.new"

step "컨테이너 기동 (최초 기동은 DB 생성으로 시간이 걸린다)"
dc up -d >/dev/null 2>&1 || { dc logs --tail 30; die "기동 실패"; }

# 상태 플래그가 아니라 실제 SQL 응답으로 확인한다.
if ! retry_until 300 sqlq "SELECT 1"; then
    dc logs --tail 40 >&2 || true
    die "$(cat <<'MSG'
SQL Server 가 응답하지 않는다. 위 로그를 확인할 것.

흔한 원인:
  - sa 비밀번호가 정책 미달(8자 이상 + 3종류 이상 문자)
  - ACCEPT_EULA 누락
  - 메모리 부족(2GB 미만)
  - 데이터 디렉터리 권한(컨테이너 uid 10001 이 쓸 수 있어야 한다)
MSG
)"
fi
ok "SQL Server 기동 및 접속 확인"

#=====================================================================
# 4. 판정
#=====================================================================
run_checks
rc=$?

step "다음 단계"
if [[ "${GENERATED_PW:-0}" == 1 ]]; then
    echo
    warn "sa 비밀번호를 무작위 생성했다. 아래 값을 안전한 곳에 보관할 것."
    echo "    MSSQL_SA_PASSWORD = ${MSSQL_SA_PASSWORD}"
    echo "    (${ENV_FILE} 에 0600 으로 저장돼 있다)"
    echo
fi
echo "  접속: <호스트>,${MSSQL_PORT}   사용자 sa"
echo "  버전: $(sqlv "SELECT CONVERT(varchar(32), SERVERPROPERTY('ProductVersion'))")"
echo
echo "  UiPath AS 에 연결할 때:"
echo "    - Full-Text Search 가 필요하다 (이 번들은 포함)"
echo "    - collation 은 ${MSSQL_COLLATION} 여야 한다"
echo "    - 운영은 Standard/Enterprise 에디션이 필요하다 (현재 ${MSSQL_PID})"
echo "    - sa 를 직접 쓰지 말고 AS 전용 로그인·DB 를 만들 것"
echo
echo "  자동 복구 검증: sudo ./install.sh --test-restart"
echo "  재판정:         sudo ./install.sh --check-only"
exit $rc
