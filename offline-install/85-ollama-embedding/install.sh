#!/usr/bin/env bash
#---------------------------------------------------------------------
# 85-ollama-embedding : 오프라인 설치 (에어갭 VM 에서 root 로 실행)
#
#   sudo ./install.sh                  # 설치 + 401 거부·임베딩 응답 판정
#   sudo ./install.sh --check-only     # 판정만 (키를 출력하지 않는다)
#   sudo ./install.sh --test-restart   # 자동 복구 실동작 검증 (docker 데몬 재시작 포함)
#   sudo ./install.sh --uninstall      # 컨테이너·네트워크 제거 (설정·키·이미지는 남긴다)
#
# 전제: Docker Engine + Compose 플러그인 v2.30 이상.
#       GPU 번들은 NVIDIA 드라이버 + nvidia-container-toolkit (README 4절).
#
# 결과: /opt/ollama-embedding 에 compose 프로젝트 ollama-embedding.
#       nginx 가 호스트 OLLAMA_EMBED_PORT(기본 80)에서 Bearer 키를 검사하고
#       ollama(11434, internal 네트워크, 호스트 비공개)로 넘긴다.
#       CPU/GPU 는 번들이 정한다(conf/flavor). 자동 감지로 바꾸지 않는다.
#---------------------------------------------------------------------
BUNDLE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_FILE="${BUNDLE_ROOT}/00-common/common.sh"
if [[ ! -f "$COMMON_FILE" ]]; then
    printf 'ERROR: 번들 공통 파일을 찾을 수 없습니다: %s\n' "$COMMON_FILE" >&2
    printf '빌드 산출물 ollama-embedding-<cpu|gpu>-<버전>.tar.gz 를 압축 해제한 디렉터리에서 install.sh 를 실행하세요.\n' >&2
    printf '예: tar xzf ollama-embedding-cpu-<버전>.tar.gz && cd ollama-embedding-cpu-<버전> && sudo ./install.sh\n' >&2
    exit 1
fi
source "$COMMON_FILE"

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

FLAVOR="$(cat "${CONF_DIR}/flavor" 2>/dev/null || true)"
case "$FLAVOR" in
    cpu) IMAGE="$OLLAMA_EMBED_CPU_IMAGE"; MODEL="$OLLAMA_EMBED_CPU_MODEL"
         MODEL_DIGEST="$OLLAMA_EMBED_CPU_MODEL_DIGEST"; QUANT="$OLLAMA_EMBED_CPU_QUANT" ;;
    gpu) IMAGE="$OLLAMA_EMBED_GPU_IMAGE"; MODEL="$OLLAMA_EMBED_GPU_MODEL"
         MODEL_DIGEST="$OLLAMA_EMBED_GPU_MODEL_DIGEST"; QUANT="$OLLAMA_EMBED_GPU_QUANT" ;;
    *)   die "번들의 conf/flavor 가 cpu/gpu 가 아니다: '${FLAVOR}'" ;;
esac
ID12="${MODEL_DIGEST#sha256:}"; ID12="${ID12:0:12}"

INSTALL_DIR="/opt/ollama-embedding"
COMPOSE_FILE="${INSTALL_DIR}/docker-compose.yml"
ENV_FILE="${INSTALL_DIR}/ollama-embedding.env"
CONFD_DIR="${INSTALL_DIR}/nginx/conf.d"
SECRETS_DIR="${INSTALL_DIR}/nginx/secrets"
MAP_FILE="${SECRETS_DIR}/api-key.map"
C_OLLAMA="ollama-embedding"
C_NGINX="ollama-embedding-nginx"
NET_BACKEND="ollama-embedding_backend"
PORT="${OLLAMA_EMBED_PORT}"
# 사용자 샘플 nginx 설정의 401 본문과 한 글자도 다르면 안 된다.
EXPECTED_401='{"error": {"message": "Invalid or missing API key.", "type": "invalid_request_error", "code": "invalid_api_key"}}'
WRONG_KEY="sk-wrong-key-for-offline-install-check"

dc() { docker compose -f "$COMPOSE_FILE" "$@"; }

api_key() { sed -n 's/^OLLAMA_EMBED_API_KEY=//p' "$ENV_FILE" 2>/dev/null | head -n 1; }

#=====================================================================
# HTTP 도우미
#
# 키는 curl 인자에 넣지 않는다. 인자로 넘기면 호스트의 ps 출력에 노출된다.
# printf 는 셸 내장이라 프로세스 인자로 보이지 않고, curl 은 -H @- 로 stdin 에서
# 헤더를 읽는다.
#=====================================================================
HTTP_BODY="$(mktemp)"
trap 'rm -f "$HTTP_BODY"' EXIT

# $1=경로 $2=JSON 본문 $3=none|wrong|right
# "상태코드 Content-Type" 을 출력하고 응답 본문은 $HTTP_BODY 에 남긴다.
http_call() {
    local path="$1" data="$2" auth="$3" key
    local -a args=(-sS -o "$HTTP_BODY" -w '%{http_code} %{content_type}' --max-time 300
                   -X POST -H 'Content-Type: application/json' --data "$data"
                   "http://127.0.0.1:${PORT}${path}")
    : > "$HTTP_BODY"
    case "$auth" in
        none)  curl "${args[@]}" ;;
        wrong) printf 'Authorization: Bearer %s\n' "$WRONG_KEY" | curl -H @- "${args[@]}" ;;
        right) key="$(api_key)"; [[ -n "$key" ]] || return 1
               printf 'Authorization: Bearer %s\n' "$key" | curl -H @- "${args[@]}" ;;
        *)     return 1 ;;
    esac
}

# 응답 JSON 의 첫 벡터 원소 수. jq 가 없는 타깃에서도 동작하게 sed 로 센다.
#   /v1/embeddings -> {"data":[{"embedding":[...]}],...}
#   /api/embed     -> {"embeddings":[[...]],...}
vec_len_openai() {
    sed -n 's/.*"embedding":\[\([^]]*\)\].*/\1/p' "$HTTP_BODY" | tr ',' '\n' | awk 'NF {n++} END {print n + 0}'
}
vec_len_ollama() {
    sed -n 's/.*"embeddings":\[\[\([^]]*\)\]\].*/\1/p' "$HTTP_BODY" | tr ',' '\n' | awk 'NF {n++} END {print n + 0}'
}

# 키가 없거나 틀리면 샘플의 OpenAI 형식 JSON 과 함께 401 이어야 한다. $1=none|wrong
expect_401() {
    local r
    r="$(http_call /v1/embeddings "{\"model\":\"${MODEL}\",\"input\":\"auth check\"}" "$1")" || return 1
    [[ "$r" == "401 application/json" ]] || return 1
    [[ "$(cat "$HTTP_BODY")" == "$EXPECTED_401" ]]
}

# 올바른 키로 OpenAI 호환 엔드포인트. 200 + 벡터 길이 = OLLAMA_EMBED_DIM
embed_openai_ok() {
    local r
    r="$(http_call /v1/embeddings "{\"model\":\"${MODEL}\",\"input\":\"offline install check\"}" right)" || return 1
    [[ "${r%% *}" == 200 ]] || return 1
    [[ "$(vec_len_openai)" == "$OLLAMA_EMBED_DIM" ]]
}

# 올바른 키로 Ollama 네이티브 엔드포인트.
embed_ollama_ok() {
    local r
    r="$(http_call /api/embed "{\"model\":\"${MODEL}\",\"input\":\"offline install check\"}" right)" || return 1
    [[ "${r%% *}" == 200 ]] || return 1
    [[ "$(vec_len_ollama)" == "$OLLAMA_EMBED_DIM" ]]
}

#=====================================================================
# 컨테이너 상태 도우미
#=====================================================================
# 실행 중이고 10초 동안 PID 가 그대로인가(크래시 루프가 아닌가). 80-postgresql 과 같은 방식.
stable_running() {
    local c="$1" p1 p2
    [[ "$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null)" == running ]] || return 1
    p1="$(docker inspect -f '{{.State.Pid}}' "$c" 2>/dev/null)"
    sleep 10
    p2="$(docker inspect -f '{{.State.Pid}}' "$c" 2>/dev/null)"
    [[ -n "$p1" && "$p1" != 0 && "$p1" == "$p2" ]]
}

both_running() {
    [[ "$(docker inspect -f '{{.State.Status}}' "$C_OLLAMA" 2>/dev/null)" == running ]] \
        && [[ "$(docker inspect -f '{{.State.Status}}' "$C_NGINX" 2>/dev/null)" == running ]]
}

ollama_healthy() {
    [[ "$(docker inspect -f '{{.State.Health.Status}}' "$C_OLLAMA" 2>/dev/null)" == healthy ]]
}

# ollama 가 호스트 포트를 하나도 공개하지 않는가(11434 우회 경로 없음)
ollama_no_host_port() {
    docker inspect "$C_OLLAMA" >/dev/null 2>&1 || return 1
    [[ -z "$(docker port "$C_OLLAMA" 2>/dev/null)" ]]
}

# ollama 가 붙은 네트워크가 internal backend 하나뿐인가
ollama_internal_only() {
    local nets
    nets="$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$C_OLLAMA" 2>/dev/null)" || return 1
    [[ "${nets% }" == "$NET_BACKEND" ]] || return 1
    [[ "$(docker network inspect -f '{{.Internal}}' "$NET_BACKEND" 2>/dev/null)" == true ]]
}

# ollama 컨테이너에서 외부로 TCP 연결이 안 되는가(IP 와 모델 레지스트리 이름 둘 다).
# exec 자체가 실패해서 "연결 실패"로 보이는 일이 없게 먼저 exec 가 되는지 본다.
ollama_no_egress() {
    docker exec "$C_OLLAMA" true >/dev/null 2>&1 || return 1
    ! docker exec "$C_OLLAMA" timeout 5 bash -c 'exec 3<>/dev/tcp/1.1.1.1/443' >/dev/null 2>&1 || return 1
    ! docker exec "$C_OLLAMA" timeout 5 bash -c 'exec 3<>/dev/tcp/registry.ollama.ai/443' >/dev/null 2>&1
}

# 이미지 안에 핀한 모델이 들어 있는가(ollama list 의 ID = 매니페스트 sha256 앞 12자리)
model_in_image() {
    local list id
    list="$(docker exec "$C_OLLAMA" /bin/ollama list 2>/dev/null)" || return 1
    id="$(awk -v m="$MODEL" '$1 == m {print $2}' <<<"$list")"
    [[ "$id" == "$ID12" ]]
}

map_file_ok() {
    [[ "$(stat -c %a "$SECRETS_DIR" 2>/dev/null)" == 700 ]] || return 1
    [[ "$(stat -c %a "$MAP_FILE" 2>/dev/null)" == 600 ]] || return 1
    [[ "$(grep -c '^"Bearer ' "$MAP_FILE" 2>/dev/null)" == 1 ]]
}

# 임베딩 요청 직후 ollama ps 의 PROCESSOR 열에 GPU 가 보이는가
ollama_on_gpu() {
    local ps
    embed_ollama_ok || return 1
    ps="$(docker exec "$C_OLLAMA" /bin/ollama ps 2>/dev/null)" || return 1
    [[ "$ps" == *GPU* ]]
}

port_in_use() { ss -lnt | grep -qE ":${PORT}([[:space:]]|$)"; }

# docker 이미지 저장소 경로. containerd 이미지 저장소면 /var/lib/containerd 에
# 압축본(content)과 해제본(snapshot)이 함께 쌓인다.
docker_store_dir() {
    local status
    status="$(docker info -f '{{json .DriverStatus}}' 2>/dev/null || true)"
    if [[ "$status" == *io.containerd.snapshotter* ]]; then
        echo /var/lib/containerd
    else
        docker info -f '{{.DockerRootDir}}'
    fi
}

# GPU 번들의 사전 조건. 아무것도 바꾸기 전에 확인한다.
# 없으면 docker 가 기동 시점에 `could not select device driver "nvidia"` 로 실패하므로
# 같은 실패를 더 이르게, 원인과 함께 낸다.
gpu_preflight() {
    local missing=() gpus=""
    if command -v nvidia-smi >/dev/null 2>&1; then
        gpus="$(nvidia-smi -L 2>/dev/null || true)"
    fi
    [[ "$gpus" == *"GPU "* ]] || missing+=("NVIDIA 드라이버(nvidia-smi -L 이 GPU 를 보여야 한다)")
    command -v nvidia-container-runtime-hook >/dev/null 2>&1 || command -v nvidia-ctk >/dev/null 2>&1 \
        || missing+=("nvidia-container-toolkit(nvidia-container-runtime-hook / nvidia-ctk)")
    if ((${#missing[@]} > 0)); then
        die "GPU 번들 사전 조건이 없다: ${missing[*]}. README 4.2절의 GPU 사전 준비 번들(install-gpu-prep.sh)로 드라이버·toolkit 을 먼저 설치하거나 CPU 번들을 쓸 것. 아무것도 바꾸지 않았다."
    fi
    ok "GPU 사전 조건: $(head -n 1 <<<"$gpus")"
}

#=====================================================================
# 판정
#=====================================================================
run_checks() {
    step "설치 상태 판정 (${FLAVOR}: ${MODEL})"

    check "docker 사용 가능"            docker info
    check "docker compose 사용 가능"    bash -c "docker compose version >/dev/null 2>&1"
    check "이미지 적재됨: ${IMAGE}"     docker image inspect "$IMAGE"
    check "이미지 적재됨: ${OLLAMA_EMBED_NGINX_IMAGE}" docker image inspect "$OLLAMA_EMBED_NGINX_IMAGE"
    check "compose 파일 존재"           test -f "$COMPOSE_FILE"
    check "compose 설정 유효"           bash -c "docker compose -f '$COMPOSE_FILE' config >/dev/null 2>&1"
    check "env 파일 권한 0600"          bash -c "[[ \$(stat -c %a '$ENV_FILE' 2>/dev/null) == 600 ]]"
    check "키 map 0600 / 디렉터리 0700 / Bearer 1줄" map_file_ok

    check "ollama 실행 중(크래시 루프 아님)" stable_running "$C_OLLAMA"
    check "nginx 실행 중(크래시 루프 아님)"  stable_running "$C_NGINX"
    check "재시작 정책 unless-stopped" bash -c "
        [[ \$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' '$C_OLLAMA' 2>/dev/null) == unless-stopped ]] &&
        [[ \$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' '$C_NGINX' 2>/dev/null) == unless-stopped ]]"
    check "ollama health=healthy"       retry_until 60 ollama_healthy
    check "ollama 컨테이너 이미지 = ${IMAGE}" bash -c "
        [[ \$(docker inspect -f '{{.Config.Image}}' '$C_OLLAMA' 2>/dev/null) == '$IMAGE' ]]"

    #--- 오프라인 구성 --------------------------------------------------
    check "ollama 호스트 포트 비공개(11434)"       ollama_no_host_port
    check "ollama 네트워크 = ${NET_BACKEND}(internal) 하나" ollama_internal_only
    check "ollama 컨테이너에서 외부 TCP 연결 불가" ollama_no_egress
    check "이미지 안 모델: ${MODEL} (ID ${ID12})" model_in_image

    #--- nginx 키 검사 --------------------------------------------------
    step "nginx Bearer 키 검사 / 임베딩 응답"
    check "호스트 ${PORT} 수신"                     retry_until 60 port_in_use
    check "키 없음 -> 401 + OpenAI 형식 JSON"       expect_401 none
    check "틀린 키 -> 401 + OpenAI 형식 JSON"       expect_401 wrong
    check "올바른 키 POST /v1/embeddings -> 200, ${OLLAMA_EMBED_DIM}차원" retry_until 300 embed_openai_ok
    check "올바른 키 POST /api/embed -> 200, ${OLLAMA_EMBED_DIM}차원"     embed_ollama_ok

    if [[ "$FLAVOR" == gpu ]]; then
        step "GPU"
        check "컨테이너에서 nvidia-smi -L" docker exec "$C_OLLAMA" nvidia-smi -L
        check "모델이 GPU 에 적재됨(ollama ps PROCESSOR)" ollama_on_gpu
    fi

    local ver compute
    ver="$(docker exec "$C_OLLAMA" /bin/ollama --version 2>/dev/null | head -n 1 || true)"
    compute="$(docker logs "$C_OLLAMA" 2>&1 | grep 'inference compute' | head -n 1 || true)"
    log "flavor=${FLAVOR} / ${ver:-ollama ?} / 모델=${MODEL}(${QUANT}) / 포트=${PORT}"
    [[ -n "$compute" ]] && log "ollama: ${compute#*msg=}"
    check_summary
}

#=====================================================================
# 자동 복구 검증
#=====================================================================
do_restart_test() {
    step "자동 복구 실동작 검증"
    local c before after pid
    for c in "$C_OLLAMA" "$C_NGINX"; do
        before="$(docker inspect -f '{{.RestartCount}}' "$c" 2>/dev/null)" || die "컨테이너 ${c} 가 없다"
        # docker kill 을 쓰면 안 된다. 수동 정지로 기록되어 unless-stopped 가
        # 재시작하지 않는다(40-haproxy 3절에서 실측).
        pid="$(docker inspect -f '{{.State.Pid}}' "$c")"
        [[ -n "$pid" && "$pid" != 0 ]] || die "컨테이너 ${c} 의 PID 를 확인할 수 없다"
        log "호스트에서 ${c} PID ${pid} 에 SIGKILL (RestartCount=${before})"
        kill -9 "$pid" || die "kill 실패: ${c}"
        # status == running 이 아니라 RestartCount 증가를 기다린다(80-postgresql 6절).
        retry_until 180 bash -c "
            rc=\$(docker inspect -f '{{.RestartCount}}' '$c' 2>/dev/null || echo 0)
            st=\$(docker inspect -f '{{.State.Status}}' '$c' 2>/dev/null || echo none)
            [[ \"\$rc\" -gt $before && \"\$st\" == running ]]" \
            || die "${c} 가 자동 복구되지 않았다. 재시작 정책을 확인할 것."
        after="$(docker inspect -f '{{.RestartCount}}' "$c")"
        ok "${c} 프로세스 사고사 후 자동 복구 (RestartCount ${before} -> ${after})"
        retry_until 300 embed_openai_ok || die "${c} 복구 후 /v1/embeddings 가 200 이 아니다"
        ok "복구 후 올바른 키 /v1/embeddings 200"
    done

    step "docker 데몬 재시작 후 복구 (재부팅 대리 검증)"
    if systemctl list-unit-files --no-legend docker.service 2>/dev/null | grep -q '^docker.service'; then
        systemctl restart docker || die "docker 데몬 재시작 실패"
        # nginx 가 ollama 보다 먼저 뜨면 upstream 이름을 못 찾고 한두 번 재시작될 수 있다.
        retry_until 150 both_running || die "데몬 재시작 후 두 컨테이너가 running 이 아니다"
        retry_until 300 embed_openai_ok || die "데몬 재시작 후 /v1/embeddings 가 200 이 아니다"
        ok "docker 재시작 후 두 컨테이너 복구, /v1/embeddings 200"
    else
        warn "docker.service 가 없어 데몬 재시작 검증을 건너뛴다. 컨테이너 사고사 검증은 통과했다."
    fi
    exit 0
}

do_uninstall() {
    step "ollama-embedding 제거"
    [[ -f "$COMPOSE_FILE" ]] && dc down >/dev/null 2>&1 || true
    docker rm -f "$C_OLLAMA" "$C_NGINX" >/dev/null 2>&1 || true
    ok "컨테이너·네트워크 제거. 설정과 키(${INSTALL_DIR}), 이미지는 남겨둔다."
    log "완전히 지우려면:"
    log "  docker image rm ${OLLAMA_EMBED_CPU_IMAGE} ${OLLAMA_EMBED_GPU_IMAGE} ${OLLAMA_EMBED_NGINX_IMAGE}"
    log "  rm -rf ${INSTALL_DIR}"
    exit 0
}

[[ "$MODE" == "uninstall" ]]    && do_uninstall
[[ "$MODE" == "restart-test" ]] && do_restart_test
if [[ "$MODE" == "check" ]]; then run_checks; exit $?; fi

#=====================================================================
# 0. 사전 확인
#=====================================================================
step "사전 확인 (${FLAVOR} 번들: ${MODEL}, ${QUANT})"
[[ "$FLAVOR" == gpu ]] && gpu_preflight
verify_manifest "$BUNDLE_ROOT"

if is_online; then
    warn "인터넷 연결 상태다. 이 설치는 번들 tar 만 쓴다(compose pull_policy: never, ollama 는 internal 네트워크)."
else
    ok "인터넷 차단 상태"
fi

require_cmds docker curl openssl ss
docker info >/dev/null 2>&1 || die "docker 가 동작하지 않는다. Docker Engine 설치를 확인할 것(README 4절)."
docker compose version >/dev/null 2>&1 || die "docker compose 플러그인이 없다."
ok "docker $(docker --version | awk '{print $3}' | tr -d ,) / compose $(docker compose version --short 2>/dev/null)"

if [[ ! "$PORT" =~ ^[0-9]{1,5}$ ]] || ((PORT < 1 || PORT > 65535)); then
    die "OLLAMA_EMBED_PORT 값이 유효하지 않다: ${PORT}"
fi
if port_in_use; then
    docker inspect "$C_NGINX" >/dev/null 2>&1 \
        || die "포트 ${PORT} 를 다른 프로세스가 쓰고 있다: $(ss -lntp | grep -E ":${PORT}([[:space:]]|$)" | head -n 1)"
fi
ok "포트 ${PORT} 사용 가능"

# 디스크. 이미지가 아직 없을 때만 본다. 계수는 docker load 가 저장소에 쓰는 양 / tar 합계.
# 실측(2026-11-04, containerd 이미지 저장소, CPU 번들): tar 합계 7.50GiB -> 저장소 증가 16.67GiB
# = 2.22배. 압축본(content)과 해제본(snapshot)을 함께 쓰기 때문이다. 10% 여유를 더해 2.5 로 둔다.
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    STORE_DIR="$(docker_store_dir)"
    tar_kb=0
    shopt -s nullglob
    for t in "${IMG_DIR}"/*.tar; do tar_kb=$((tar_kb + $(stat -c %s "$t") / 1024)); done
    shopt -u nullglob
    need_kb=$((tar_kb * 25 / 10))
    avail_kb="$(df -Pk "$STORE_DIR" | awk 'NR == 2 {print $4}')"
    if ((avail_kb < need_kb)); then
        die "docker 저장소(${STORE_DIR}) 여유가 부족하다: 필요 약 $((need_kb / 1024 / 1024))GB / 여유 $((avail_kb / 1024 / 1024))GB (README 4절)"
    fi
    ok "디스크: ${STORE_DIR} 여유 $((avail_kb / 1024 / 1024))GB >= 필요 약 $((need_kb / 1024 / 1024))GB"
fi

if docker inspect "$C_OLLAMA" >/dev/null 2>&1; then
    cur="$(docker inspect -f '{{.Config.Image}}' "$C_OLLAMA" 2>/dev/null || true)"
    [[ "$cur" != "$IMAGE" ]] && log "flavor 를 바꾼다: ${cur} -> ${IMAGE}"
fi

#=====================================================================
# 1. 이미지 적재
#=====================================================================
step "이미지 적재 (docker load, 번들 tar)"
shopt -s nullglob
for tar in "${IMG_DIR}"/*.tar; do
    log "docker load: $(basename "$tar") ($(du -h "$tar" | cut -f1))"
    docker load -i "$tar" >/dev/null || die "docker load 실패: $tar"
done
shopt -u nullglob
for img in "$IMAGE" "$OLLAMA_EMBED_NGINX_IMAGE"; do
    docker image inspect "$img" >/dev/null 2>&1 || die "적재되지 않은 이미지: ${img}"
    ok "이미지 적재 확인: ${img}"
done

#=====================================================================
# 2. API 키
#
# 우선순위: 기존 env 파일 > OLLAMA_EMBED_API_KEY(환경변수/site.env) > 생성.
# 원본은 env 파일(0600) 하나다. nginx 용 map 파일은 매번 env 에서 다시 만들고
# 백업을 남기지 않는다(install_file 은 .bak 을 남겨 옛 키가 디스크에 남는다).
#=====================================================================
step "API 키"
install -d -m 0755 "$INSTALL_DIR" "${INSTALL_DIR}/nginx" "$CONFD_DIR"
install -d -m 0700 "$SECRETS_DIR"
chmod 0700 "$SECRETS_DIR"

PROVIDED_KEY="${OLLAMA_EMBED_API_KEY:-}"
KEY_GENERATED=0
if [[ -f "$ENV_FILE" ]]; then
    API_KEY="$(api_key)"
    [[ -n "$API_KEY" ]] || die "${ENV_FILE} 에 OLLAMA_EMBED_API_KEY= 줄이 없다"
    if [[ -n "$PROVIDED_KEY" && "$PROVIDED_KEY" != "$API_KEY" ]]; then
        warn "OLLAMA_EMBED_API_KEY 가 주어졌지만 기존 ${ENV_FILE} 의 키를 유지한다. 바꾸려면 그 파일을 고친 뒤 다시 실행할 것(README 5절)."
    fi
    ok "기존 키 유지: ${ENV_FILE}"
elif [[ -n "$PROVIDED_KEY" ]]; then
    API_KEY="$PROVIDED_KEY"
    ok "OLLAMA_EMBED_API_KEY 값을 쓴다"
else
    # 128비트 난수. 길이 35자는 아래 상한(39자) 안에 든다.
    API_KEY="sk-$(openssl rand -hex 16)"
    KEY_GENERATED=1
    ok "키 생성 (sk- + hex 32자)"
fi
# nginx map 문자열에 따옴표·백슬래시·$·;·공백이 들어가지 않게 문자를 제한한다.
# 길이 상한 39자: 샘플 nginx 설정은 map_hash_bucket_size 를 지정하지 않아 기본값
# (CPU 캐시 라인 64바이트)을 쓰고, 그때 "Bearer <키>" 가 47바이트를 넘으면 nginx 가
# "could not build map_hash" 로 기동하지 않는다(실측: 키 39자 통과, 40자 실패).
[[ "$API_KEY" =~ ^[A-Za-z0-9._-]{20,39}$ ]] \
    || die "API 키는 영문자·숫자·.·_·- 20~39자여야 한다(${ENV_FILE} 또는 OLLAMA_EMBED_API_KEY). 따옴표 없이 적을 것(README 5절)."

if [[ ! -f "$ENV_FILE" ]]; then
    (umask 077; printf 'OLLAMA_EMBED_API_KEY=%s\n' "$API_KEY" > "$ENV_FILE")
fi
chown root:root "$ENV_FILE"
chmod 0600 "$ENV_FILE"
(umask 077; printf '"Bearer %s" 1;\n' "$API_KEY" > "${MAP_FILE}.new")
mv -f "${MAP_FILE}.new" "$MAP_FILE"
chmod 0600 "$MAP_FILE"
ok "키 파일: ${ENV_FILE} (0600) / nginx map: ${MAP_FILE} (0600)"

#=====================================================================
# 3. 설정 파일
#=====================================================================
step "설정 파일"
install_file "${CONF_DIR}/nginx/default.conf" "${CONFD_DIR}/default.conf" 0644

if [[ "$FLAVOR" == gpu ]]; then GPUS_SED='s|__OLLAMA_GPUS__|gpus: all|'; else GPUS_SED='/__OLLAMA_GPUS__/d'; fi
sed -e "$GPUS_SED" \
    -e "s|__OLLAMA_IMAGE__|${IMAGE}|g" \
    -e "s|__NGINX_IMAGE__|${OLLAMA_EMBED_NGINX_IMAGE}|g" \
    -e "s|__OLLAMA_EMBED_PORT__|${PORT}|g" \
    -e "s|__INSTALL_DIR__|${INSTALL_DIR}|g" \
    "${CONF_DIR}/docker-compose.yml.tmpl" > "${COMPOSE_FILE}.new"
docker compose -f "${COMPOSE_FILE}.new" config >/dev/null 2>&1 \
    || { docker compose -f "${COMPOSE_FILE}.new" config; die "생성된 compose 파일이 유효하지 않다"; }
ok "compose 문법 검사 통과"
install_file "${COMPOSE_FILE}.new" "$COMPOSE_FILE" 0644
rm -f "${COMPOSE_FILE}.new"

#=====================================================================
# 4. 기동
#=====================================================================
step "기동"
dc up -d >/dev/null 2>&1 || { dc logs --tail 40 >&2 || true; die "기동 실패"; }
retry_until 180 ollama_healthy || { dc logs --tail 40 >&2 || true; die "ollama 가 healthy 가 되지 않았다"; }
ok "ollama healthy"
# nginx 가 설정 오류로 재시작을 반복하면 아래 exec 가 "is restarting" 으로만 실패해
# 원인이 보이지 않는다. 먼저 안정적으로 떠 있는지 보고, 아니면 nginx 로그를 보여 준다.
if ! retry_until 60 stable_running "$C_NGINX"; then
    docker logs --tail 20 "$C_NGINX" >&2 || true
    die "nginx 가 실행 상태를 유지하지 못한다. 위 로그를 확인할 것(README 11절)."
fi
# 키를 바꿨을 수 있으므로 설정을 다시 읽힌다. 컨테이너는 디렉터리 마운트라 새 파일이 보인다.
docker exec "$C_NGINX" nginx -t >/dev/null 2>&1 \
    || { docker exec "$C_NGINX" nginx -t || true; die "nginx 설정 검사 실패"; }
docker exec "$C_NGINX" nginx -s reload >/dev/null 2>&1 || die "nginx reload 실패"
ok "nginx 설정 검사·reload"
# 첫 요청이 모델을 메모리에 올린다. CPU 에서는 수십 초 걸릴 수 있다.
log "첫 임베딩 요청 (모델 적재 포함, 최대 300초)"
retry_until 300 embed_openai_ok || { dc logs --tail 40 >&2 || true; die "올바른 키로 /v1/embeddings 가 200 이 아니다"; }
ok "올바른 키 /v1/embeddings 200"

#=====================================================================
# 5. 판정
#=====================================================================
rc=0
run_checks || rc=$?

step "다음 단계"
HOST_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") {print $(i + 1); exit}}' || true)"
[[ -n "$HOST_IP" ]] || HOST_IP="$(hostname -I | awk '{print $1}')"
if ((KEY_GENERATED == 1)); then
    echo
    warn "API 키를 생성했다. 아래 값을 안전한 곳에 보관할 것(다시 출력하지 않는다)."
    echo "    ${API_KEY}"
    echo "    (${ENV_FILE} 에 0600 으로 저장돼 있다)"
    echo
fi
echo "  OpenAI 호환: POST http://${HOST_IP}:${PORT}/v1/embeddings  (model=${MODEL})"
echo "  Ollama:      POST http://${HOST_IP}:${PORT}/api/embed"
echo "  헤더:        Authorization: Bearer <키>"
echo "  키 확인:     sudo grep '^OLLAMA_EMBED_API_KEY=' ${ENV_FILE}"
echo
echo "  자동 복구 검증: sudo ./install.sh --test-restart   (docker 데몬도 재시작한다)"
echo "  재판정:         sudo ./install.sh --check-only"
exit $rc
