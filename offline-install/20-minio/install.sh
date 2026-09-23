#!/usr/bin/env bash
#---------------------------------------------------------------------
# 20-minio : 오프라인 설치 (에어갭 노드에서 root 로 실행)
#
#   sudo ./install.sh                  # 설치 + 버킷 왕복 검증
#   sudo ./install.sh --check-only     # 판정만
#   sudo ./install.sh --test-restart   # 자동 복구 실동작 검증
#   sudo ./install.sh --uninstall      # 컨테이너 제거(데이터는 남긴다)
#
# 전제: 10-k8s 설치 완료(docker + docker compose).
#
# 자격증명은 site.env 의 MINIO_ROOT_USER / MINIO_ROOT_PASSWORD 를 쓴다.
# 없으면 무작위 생성해 /opt/minio/minio.env(0600)에 저장하고 출력한다.
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

MINIO_DIR="/opt/minio"
MINIO_DATA_DIR="${MINIO_DATA_DIR:-/data/minio}"
COMPOSE_FILE="${MINIO_DIR}/docker-compose.yml"
ENV_FILE="${MINIO_DIR}/minio.env"
CERT_DIR="${MINIO_DIR}/certs"
CONTAINER="minio"

# 접속 이름·주소. site.env 로 덮어쓸 수 있다.
# hostname -d 는 도메인이 없을 때 오류가 아니라 **빈 문자열**을 반환한다.
# `|| echo local` 은 동작하지 않으므로(exit 0) 빈 값을 따로 처리한다.
# 처리하지 않으면 "minio." 처럼 끝에 점만 남는 이름이 만들어진다.
_MINIO_DOMAIN="$(hostname -d 2>/dev/null || true)"
MINIO_HOSTNAME="${MINIO_HOSTNAME:-minio${_MINIO_DOMAIN:+.${_MINIO_DOMAIN}}}"
MINIO_HOST_IP="${MINIO_HOST_IP:-$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')}"
[[ -n "$MINIO_HOST_IP" ]] || MINIO_HOST_IP="$(hostname -I | awk '{print $1}')"

# 판정에 쓸 버킷 이름. 남더라도 해가 없도록 전용 이름을 쓴다.
SMOKE_BUCKET="minio-smoke-test"

dc() { docker compose -f "$COMPOSE_FILE" "$@"; }

#=====================================================================
# mc 실행 도우미
#
# 서버가 TLS 전용이고 자가서명이므로 --insecure 가 필요하다.
# mc 를 호스트에 설치하지 않고 컨테이너로 돌린다. 번들에 바이너리가 없고
# (업스트림 아카이브), 호스트를 더럽히지 않는 편이 낫다.
# --network host: 서버가 host 포트 9000 에 있고, TLS SAN 에 127.0.0.1 이 있다.
#
# 자격증명을 명령행이 아니라 MC_HOST_<alias> 환경변수로 넘긴다.
# 명령행에 넣으면 `ps` 와 셸 히스토리에 비밀번호가 남는다.
#=====================================================================
mc_host_url() {
    local u p
    u="$(grep -E '^MINIO_ROOT_USER=' "$ENV_FILE" | cut -d= -f2-)"
    p="$(grep -E '^MINIO_ROOT_PASSWORD=' "$ENV_FILE" | cut -d= -f2-)"
    # URL 안에 들어가므로 특수문자를 퍼센트 인코딩한다.
    p="$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe=""))' "$p")"
    echo "https://${u}:${p}@127.0.0.1:9000"
}

mc_run() {
    docker run --rm --network host \
        -e MC_HOST_m="$(mc_host_url)" \
        "$MINIO_MC_IMAGE" --insecure "$@"
}

# 호스트 파일을 컨테이너에 마운트해 업로드한다.
mc_upload() {
    local src="$1" dst="$2"
    docker run --rm --network host -v "${src}":/tmp/upload:ro \
        -e MC_HOST_m="$(mc_host_url)" \
        "$MINIO_MC_IMAGE" --insecure cp /tmp/upload "$dst"
}

# 아래 두 개는 check 에 직접 넘기기 위한 래퍼다. bash -c 로 감싸면
# $ENV_FILE 같은 셸 변수가 새 프로세스에 전달되지 않아 조용히 실패한다.
mc_object_listed() {
    mc_run ls "$1" 2>/dev/null | grep -q "$2"
}
mc_object_contains() {
    mc_run cat "$1" 2>/dev/null | grep -q "$2"
}

#=====================================================================
# 판정
#=====================================================================
run_checks() {
    step "설치 상태 판정"

    check "docker 사용 가능"       docker info
    check "docker compose 사용 가능" bash -c "docker compose version >/dev/null 2>&1"

    local img
    while read -r img; do
        [[ -n "$img" ]] || continue
        check "이미지 적재됨: ${img##*/}" \
            bash -c "docker image inspect '$img' >/dev/null 2>&1"
    done < "${CONF_DIR}/images.list"

    check "compose 파일 존재"        test -f "$COMPOSE_FILE"
    check "env 파일 권한 0600"       bash -c "[[ \$(stat -c %a '$ENV_FILE' 2>/dev/null) == 600 ]]"
    check "TLS 인증서 존재"          bash -c "test -f '${CERT_DIR}/public.crt' -a -f '${CERT_DIR}/private.key'"
    check "데이터 디렉터리 존재"      test -d "$MINIO_DATA_DIR"
    check "compose 설정 문법 유효"    bash -c "docker compose -f '$COMPOSE_FILE' config >/dev/null 2>&1"

    # 크래시 루프를 실행 중으로 오판하지 않도록 PID 유지까지 본다.
    # (40-haproxy 에서 실제로 겪은 문제다)
    check "컨테이너 실행 중(크래시 루프 아님)" bash -c "
        [[ \$(docker inspect -f '{{.State.Status}}' '$CONTAINER' 2>/dev/null) == running ]] || exit 1
        p1=\$(docker inspect -f '{{.State.Pid}}' '$CONTAINER' 2>/dev/null)
        sleep 10
        p2=\$(docker inspect -f '{{.State.Pid}}' '$CONTAINER' 2>/dev/null)
        [[ -n \"\$p1\" && \"\$p1\" != 0 && \"\$p1\" == \"\$p2\" ]]"
    check "재시작 정책 unless-stopped" bash -c "
        [[ \$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' '$CONTAINER' 2>/dev/null) == unless-stopped ]]"

    for p in 9000 9001; do
        check "호스트 ${p} 수신" retry_until 60 bash -c "ss -lnt | grep -qE ':${p}\b'"
    done

    # TLS 로 응답하는지. HTTP 로 오면 --certs-dir 가 먹지 않은 것이다.
    check "9000 이 TLS 로 응답" retry_until 90 bash -c "
        curl -sk --max-time 5 https://127.0.0.1:9000/minio/health/live -o /dev/null"
    check "health/live 200" retry_until 90 bash -c "
        [[ \$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 https://127.0.0.1:9000/minio/health/live) == 200 ]]"
    check "콘솔 9001 응답" retry_until 60 bash -c "
        curl -sk -o /dev/null --max-time 5 https://127.0.0.1:9001/"

    # 인증서 SAN 에 접속 이름이 들어 있는지. 없으면 클라이언트가 거부한다.
    check "인증서 SAN 에 ${MINIO_HOSTNAME} 포함" bash -c "
        openssl x509 -in '${CERT_DIR}/public.crt' -noout -text \
          | grep -A1 'Subject Alternative Name' | grep -q '${MINIO_HOSTNAME}'"

    #--- 실제 동작 검증: 버킷 생성 -> 쓰기 -> 읽기 -> 삭제 ---------------
    # 설정만 보는 검사로는 자격증명 불일치나 디스크 권한 문제를 잡을 수 없다.
    step "버킷 왕복 검증 (생성 -> 쓰기 -> 읽기 -> 삭제)"

    # check 는 "$@" 를 그대로 실행하므로 셸 함수를 직접 넘길 수 있다.
    # bash -c 로 감싸고 declare -f 로 함수를 옮기는 방식은 인용이 중첩되어
    # 깨지기 쉽다. 함수를 그대로 넘기는 편이 안전하다.
    check "mc 로 서버 접속 가능" retry_until 90 mc_run ready m

    local tmpf="/tmp/minio-smoke-$$.txt"
    echo "offline-install smoke $(date -Is)" > "$tmpf"

    check "버킷 생성"        mc_run mb --ignore-existing "m/${SMOKE_BUCKET}"
    check "객체 업로드"      mc_upload "$tmpf" "m/${SMOKE_BUCKET}/o.txt"
    check "객체 목록에 보임" mc_object_listed "m/${SMOKE_BUCKET}" "o.txt"
    check "객체 내용 일치"   mc_object_contains "m/${SMOKE_BUCKET}/o.txt" "offline-install smoke"

    # 데이터가 호스트 볼륨에 실제로 떨어졌는지. 컨테이너 안에만 있으면
    # 재시작 시 사라진다.
    check "호스트 볼륨에 데이터 기록됨" test -d "${MINIO_DATA_DIR}/${SMOKE_BUCKET}"

    # 정리. 실패해도 판정에 영향을 주지 않는다.
    mc_run rb --force "m/${SMOKE_BUCKET}" >/dev/null 2>&1 || true
    rm -f "$tmpf"

    log "리전: $(grep -E '^MINIO_REGION=' "$ENV_FILE" | cut -d= -f2-)"
    log "S3 엔드포인트: https://${MINIO_HOSTNAME}:9000"
    log "콘솔:          https://${MINIO_HOSTNAME}:9001"

    check_summary
}

#=====================================================================
# 자동 복구 실동작 검증
#=====================================================================
do_restart_test() {
    step "자동 복구 실동작 검증"

    local before after pid
    before="$(docker inspect -f '{{.RestartCount}}' "$CONTAINER" 2>/dev/null)" \
        || die "컨테이너 ${CONTAINER} 가 없다"
    log "현재 RestartCount=${before}"

    # docker kill 을 쓰면 안 된다. "사용자가 의도적으로 멈춤"으로 기록되어
    # unless-stopped 가 재시작하지 않는다(40-haproxy 에서 실측).
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
    retry_until 90 bash -c "curl -sk -o /dev/null --max-time 5 https://127.0.0.1:9000/minio/health/live" \
        && ok "복구 후 health 응답 정상" || die "복구됐지만 health 가 응답하지 않는다"

    # docker 데몬 재시작 = 노드 재부팅 대리 검증
    step "docker 데몬 재시작 후 복구 (재부팅 대리 검증)"
    systemctl restart docker || die "docker 데몬 재시작 실패"
    retry_until 120 bash -c "[[ \$(docker inspect -f '{{.State.Status}}' '$CONTAINER' 2>/dev/null) == running ]]" \
        && ok "데몬 재시작 후 복구됨" || die "데몬 재시작 후 올라오지 않았다"
    retry_until 120 bash -c "curl -sk -o /dev/null --max-time 5 https://127.0.0.1:9000/minio/health/live" \
        && ok "health 응답 정상" || die "복구됐지만 health 가 응답하지 않는다"
    exit 0
}

do_uninstall() {
    step "MinIO 제거"
    if [[ -f "$COMPOSE_FILE" ]]; then
        dc down >/dev/null 2>&1 || true
    fi
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    ok "컨테이너 제거. 설정(${MINIO_DIR})과 데이터(${MINIO_DATA_DIR})는 남겨둔다."
    log "데이터까지 지우려면: rm -rf ${MINIO_DATA_DIR}"
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
docker compose version >/dev/null 2>&1 \
    || die "docker compose 플러그인이 없다. 10-k8s 번들의 docker-compose-plugin deb 를 확인할 것."
ok "docker $(docker --version | awk '{print $3}' | tr -d ,) / compose $(docker compose version --short 2>/dev/null)"

# 포트 선점 확인. 기동 실패는 로그만 남기고 조용히 끝나므로 먼저 잡는다.
for p in 9000 9001; do
    if ss -lnt | grep -qE ":${p}\b"; then
        if ! docker inspect -f '{{.State.Running}}' "$CONTAINER" >/dev/null 2>&1; then
            die "포트 ${p} 를 다른 프로세스가 쓰고 있다: $(ss -lntp | grep -E ":${p}\b" | head -1)"
        fi
    fi
done
ok "포트 9000/9001 사용 가능"

log "접속 이름=${MINIO_HOSTNAME} / 주소=${MINIO_HOST_IP}"

#=====================================================================
# 1. 이미지 적재
#=====================================================================
step "이미지 적재 (docker)"
# k8s 워크로드가 아니라 docker 로 돌리므로 ctr 이 아니라 docker load 를 쓴다.
shopt -s nullglob
for tar in "${IMG_DIR}"/*.tar; do
    log "docker load: $(basename "$tar")"
    docker load -i "$tar" >/dev/null || die "docker load 실패: $tar"
done
shopt -u nullglob

MISSING=()
while read -r img; do
    [[ -n "$img" ]] || continue
    docker image inspect "$img" >/dev/null 2>&1 || MISSING+=("$img")
done < "${CONF_DIR}/images.list"
((${#MISSING[@]} == 0)) || die "적재되지 않은 이미지: ${MISSING[*]}"
ok "이미지 $(wc -l < "${CONF_DIR}/images.list")개 적재 확인"

#=====================================================================
# 2. 디렉터리 / 자격증명
#=====================================================================
step "디렉터리 및 자격증명"

install -d -m 0755 "$MINIO_DIR"
install -d -m 0700 "$CERT_DIR"
install -d -m 0755 "$MINIO_DATA_DIR"
ok "디렉터리: ${MINIO_DIR}, ${MINIO_DATA_DIR}"

if [[ -f "$ENV_FILE" ]]; then
    ok "기존 env 파일 사용: ${ENV_FILE}"
    MINIO_ROOT_USER="$(grep -E '^MINIO_ROOT_USER=' "$ENV_FILE" | cut -d= -f2-)"
    MINIO_ROOT_PASSWORD="$(grep -E '^MINIO_ROOT_PASSWORD=' "$ENV_FILE" | cut -d= -f2-)"
else
    # site.env 값이 있으면 쓰고, 없으면 무작위 생성한다.
    # 무작위 생성이 기본인 이유: 공개 저장소에 기본 비밀번호를 적어두면
    # 그대로 운영에 들어가는 일이 실제로 생긴다.
    MINIO_ROOT_USER="${MINIO_ROOT_USER:-uipathadmin}"
    if [[ -z "${MINIO_ROOT_PASSWORD:-}" ]]; then
        MINIO_ROOT_PASSWORD="$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)"
        GENERATED_PW=1
    fi
    # MinIO 는 8자 미만 비밀번호면 기동 직후 종료된다. 먼저 잡는다.
    ((${#MINIO_ROOT_PASSWORD} >= 8)) \
        || die "MINIO_ROOT_PASSWORD 가 8자 미만이다. MinIO 가 기동하지 않는다."
    ((${#MINIO_ROOT_USER} >= 3)) \
        || die "MINIO_ROOT_USER 가 3자 미만이다. MinIO 가 기동하지 않는다."

    sed -e "s|__MINIO_ROOT_USER__|${MINIO_ROOT_USER}|g" \
        -e "s|__MINIO_ROOT_PASSWORD__|${MINIO_ROOT_PASSWORD}|g" \
        -e "s|__MINIO_HOSTNAME__|${MINIO_HOSTNAME}|g" \
        -e "s|__MINIO_REGION__|${MINIO_REGION}|g" \
        "${CONF_DIR}/minio.env.tmpl" > "$ENV_FILE"
    chmod 0600 "$ENV_FILE"
    ok "env 파일 생성: ${ENV_FILE} (0600)"
fi

#=====================================================================
# 3. TLS 인증서
#
# 자가서명이다. 사내 CA 가 있으면 public.crt / private.key 를 교체하면 된다.
# SAN 에 호스트명과 IP 를 모두 넣는다. IP 만 넣으면 이름으로 접속할 때,
# 이름만 넣으면 IP 로 접속할 때 각각 거부된다.
#=====================================================================
step "TLS 인증서"

if [[ -f "${CERT_DIR}/public.crt" && -f "${CERT_DIR}/private.key" ]]; then
    ok "기존 인증서 사용 (만료: $(openssl x509 -in "${CERT_DIR}/public.crt" -noout -enddate | cut -d= -f2))"
else
    sed -e "s|__MINIO_HOSTNAME__|${MINIO_HOSTNAME}|g" \
        -e "s|__MINIO_HOST_IP__|${MINIO_HOST_IP}|g" \
        "${CONF_DIR}/minio-openssl.cnf.tmpl" > /tmp/minio-openssl.cnf

    openssl req -x509 -nodes -days 3650 -newkey rsa:4096 \
        -keyout "${CERT_DIR}/private.key" \
        -out    "${CERT_DIR}/public.crt" \
        -config /tmp/minio-openssl.cnf >/dev/null 2>&1 \
        || die "인증서 생성 실패"
    rm -f /tmp/minio-openssl.cnf
    # MinIO 컨테이너는 uid 1000(minio)으로 돌고 /certs 를 읽어야 한다.
    chmod 0644 "${CERT_DIR}/public.crt"
    chmod 0640 "${CERT_DIR}/private.key"
    chown -R 1000:1000 "$CERT_DIR"
    ok "자가서명 인증서 생성 (SAN: ${MINIO_HOSTNAME}, ${MINIO_HOST_IP}, localhost, 127.0.0.1)"
fi

# 데이터 디렉터리도 컨테이너 uid 소유여야 쓰기가 된다.
chown -R 1000:1000 "$MINIO_DATA_DIR"

#=====================================================================
# 4. compose 파일 생성 및 기동
#=====================================================================
step "compose 파일 생성"

sed -e "s|__MINIO_IMAGE__|${MINIO_IMAGE}|g" \
    -e "s|__MINIO_DIR__|${MINIO_DIR}|g" \
    -e "s|__MINIO_DATA_DIR__|${MINIO_DATA_DIR}|g" \
    -e "s|__MINIO_HOSTNAME__|${MINIO_HOSTNAME}|g" \
    -e "s|__MINIO_HOST_IP__|${MINIO_HOST_IP}|g" \
    "${CONF_DIR}/docker-compose.yml.tmpl" > "${COMPOSE_FILE}.new"

docker compose -f "${COMPOSE_FILE}.new" config >/dev/null 2>&1 \
    || { docker compose -f "${COMPOSE_FILE}.new" config; die "생성된 compose 파일이 유효하지 않다"; }
ok "compose 문법 검사 통과"

install_file "${COMPOSE_FILE}.new" "$COMPOSE_FILE" 0644
rm -f "${COMPOSE_FILE}.new"

step "컨테이너 기동"
dc up -d >/dev/null 2>&1 || { dc logs --tail 30; die "기동 실패"; }

# 상태 플래그가 아니라 실제 응답으로 확인한다. 기동 실패는 Running=true 로
# 잠깐 보였다가 종료되는 형태로 나타나므로 플래그로는 놓친다.
if ! retry_until 120 bash -c "curl -sk -o /dev/null --max-time 3 https://127.0.0.1:9000/minio/health/live"; then
    dc logs --tail 30 >&2 || true
    die "MinIO 가 정상 기동하지 않았다(health 무응답). 위 로그를 확인할 것."
fi
ok "컨테이너 기동 및 health 응답 확인"

#=====================================================================
# 5. 판정
#=====================================================================
run_checks
rc=$?

step "다음 단계"
if [[ "${GENERATED_PW:-0}" == 1 ]]; then
    echo
    warn "자격증명을 무작위 생성했다. 아래 값을 안전한 곳에 보관할 것."
    echo "    MINIO_ROOT_USER     = ${MINIO_ROOT_USER}"
    echo "    MINIO_ROOT_PASSWORD = ${MINIO_ROOT_PASSWORD}"
    echo "    (${ENV_FILE} 에 0600 으로 저장돼 있다)"
    echo
fi
echo "  S3 엔드포인트: https://${MINIO_HOSTNAME}:9000   (리전 ${MINIO_REGION})"
echo "  웹 콘솔:       https://${MINIO_HOSTNAME}:9001"
echo
echo "  이름으로 접속하려면 클라이언트의 /etc/hosts 에 매핑이 필요하다:"
echo "    ${MINIO_HOST_IP} ${MINIO_HOSTNAME}"
echo "  자가서명 인증서이므로 클라이언트는 ${CERT_DIR}/public.crt 를 신뢰해야 한다."
echo
echo "  자동 복구 검증: sudo ./install.sh --test-restart"
echo "  재판정:         sudo ./install.sh --check-only"
exit $rc
