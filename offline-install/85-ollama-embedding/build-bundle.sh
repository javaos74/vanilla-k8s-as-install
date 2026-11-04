#!/usr/bin/env bash
#---------------------------------------------------------------------
# 85-ollama-embedding : 번들 빌드 (온라인 빌드 호스트에서 일반 사용자로 실행)
#
#   ./build-bundle.sh          # cpu + gpu 번들 둘 다 (기본 all)
#   ./build-bundle.sh cpu      # CPU 번들만 (qwen3-embedding:8b, Q4_K_M)
#   ./build-bundle.sh gpu      # GPU 번들만 (qwen3-embedding:8b-q8_0, Q8_0)
#
# 산출물: bundle/ollama-embedding-<cpu|gpu>-<OLLAMA_VERSION>.tar.gz (+ .sha256)
#   - 공식 ollama/ollama 를 FROM 으로 하고 빌드 중 `ollama pull` 로 모델을 넣은
#     이미지(image/Dockerfile)를 docker save 한 tar
#   - nginx 이미지 tar (skopeo, amd64 다이제스트 고정)
#   - compose 템플릿, nginx 설정, install.sh, 00-common
#
# 빌드 호스트 요건 (README 3절):
#   - Linux x86_64 + Docker Engine(buildx) + 인터넷(Docker Hub, registry.ollama.ai)
#     macOS / arm64 는 지원하지 않는다. amd64 이미지를 에뮬레이션으로 빌드하면
#     RUN 안의 ollama serve / pull 동작을 보장할 수 없다.
#   - RAM 16GB 이상. 빌드 검증에서 모델을 CPU 로 한 번 띄운다(GPU 모델 포함).
#   - 디스크: docker 저장소 + bundle/ 합쳐 all 약 80GB, 단일 flavor 약 40GB.
#---------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../00-common/common.sh"

case "${1:-all}" in
    cpu|gpu) FLAVORS=("$1") ;;
    all)     FLAVORS=(cpu gpu) ;;
    *)       die "알 수 없는 인자: $1 (cpu | gpu | all)" ;;
esac

require_online
require_nonroot_build
require_cmds docker curl tar sha256sum
[[ "$(uname -m)" == x86_64 ]] \
    || die "x86_64 Linux 빌드 호스트가 필요하다(현재 $(uname -s)/$(uname -m)). macOS/arm64 는 지원하지 않는다(README 3절)."

# docker 그룹이 아니면 sudo 로 부른다(70-mssql/fts-image/build-image.sh 와 같은 방식).
if docker info >/dev/null 2>&1; then DOCKER=(docker); else DOCKER=(sudo docker); fi
"${DOCKER[@]}" info >/dev/null 2>&1 || die "docker 데몬에 접근할 수 없다"
"${DOCKER[@]}" buildx version >/dev/null 2>&1 || die "docker buildx 플러그인이 없다"
ok "docker $("${DOCKER[@]}" version -f '{{.Server.Version}}' 2>/dev/null) / $("${DOCKER[@]}" buildx version | awk '{print $1, $2}')"

if ! command -v skopeo >/dev/null 2>&1; then
    log "skopeo 설치(빌드 도구)"
    pkg_install_build_tool skopeo
fi
ok "skopeo $(skopeo --version | awk '{print $3}')"

#--- 디스크 여유 -------------------------------------------------------
# containerd 이미지 저장소(io.containerd.snapshotter.v1)를 쓰면 이미지가
# /var/lib/containerd 에 압축본과 해제본으로 이중 저장된다.
docker_store_dir() {
    local status
    status="$("${DOCKER[@]}" info -f '{{json .DriverStatus}}' 2>/dev/null || true)"
    if [[ "$status" == *io.containerd.snapshotter* ]]; then
        echo /var/lib/containerd
    else
        "${DOCKER[@]}" info -f '{{.DockerRootDir}}'
    fi
}

mkdir -p "${SCRIPT_DIR}/bundle"
STORE_DIR="$(docker_store_dir)"
WANT_GB=35; ((${#FLAVORS[@]} > 1)) && WANT_GB=60
step "디스크 여유 (권장 ${WANT_GB}GB 이상, 추정치)"
for d in "$STORE_DIR" "${SCRIPT_DIR}/bundle"; do
    df -h "$d" | sed 's/^/    /'
    avail_kb="$(df -Pk "$d" | awk 'NR == 2 {print $4}')"
    ((avail_kb >= WANT_GB * 1024 * 1024)) \
        || warn "${d} 여유 $((avail_kb / 1024 / 1024))GB < 권장 ${WANT_GB}GB. 빌드 중 공간이 부족할 수 있다."
done

#--- 빌드 검증 컨테이너 정리 -------------------------------------------
VERIFY_CONTAINER=""
cleanup() {
    [[ -n "$VERIFY_CONTAINER" ]] && "${DOCKER[@]}" rm -f "$VERIFY_CONTAINER" >/dev/null 2>&1
    [[ -n "${NGINX_TEST_DIR:-}" ]] && rm -rf "$NGINX_TEST_DIR"
    return 0
}
trap cleanup EXIT

# 응답 JSON 의 첫 벡터 원소 수. jq/python 이 없는 호스트에서도 동작하게 sed 로 센다.
#   /api/embed -> {"embeddings":[[...]],...}
vec_len_ollama() {
    sed -n 's/.*"embeddings":\[\[\([^]]*\)\]\].*/\1/p' | tr ',' '\n' | awk 'NF {n++} END {print n + 0}'
}

#--- nginx 이미지 ------------------------------------------------------
NGINX_TAR_NAME="$(image_to_filename "$OLLAMA_EMBED_NGINX_IMAGE").tar"
fetch_nginx() {
    local tar="$1"
    if [[ -s "$tar" ]]; then
        log "이미 존재: $(basename "$tar")"
    else
        rm -f "${tar}.part"
        skopeo copy --override-arch amd64 --override-os linux --retry-times 5 \
            "docker://${OLLAMA_EMBED_NGINX_IMAGE%:*}@${OLLAMA_EMBED_NGINX_DIGEST}" \
            "docker-archive:${tar}.part:${OLLAMA_EMBED_NGINX_IMAGE}" >/dev/null \
            || die "nginx 이미지 받기 실패: ${OLLAMA_EMBED_NGINX_IMAGE%:*}@${OLLAMA_EMBED_NGINX_DIGEST}"
        mv "${tar}.part" "$tar"
    fi
    ok "$(basename "$tar") ($(du -h "$tar" | cut -f1))"
}

# 저장소의 nginx 설정이 이 nginx 버전에서 문법상 유효한지 본다.
# nginx -t 는 upstream 이름(ollama)을 해석하므로 --add-host 로 이름만 준다.
# 키 파일은 시험용 값으로 만든다(실제 키는 install.sh 가 타깃에서 만든다).
# install.sh 가 허용하는 가장 긴 키(39자)로 시험한다. 키가 map 해시 버킷(기본 64바이트)보다
# 길면 nginx 가 "could not build map_hash" 로 기동하지 않는데, 짧은 시험 키로는 이것을
# 못 잡는다(실측: 키 40자 이상 실패, README 5절).
check_nginx_conf() {
    local tar="$1" out test_key
    "${DOCKER[@]}" load -i "$tar" >/dev/null || die "docker load 실패: $tar"
    NGINX_TEST_DIR="$(mktemp -d)"
    mkdir -p "${NGINX_TEST_DIR}/conf.d" "${NGINX_TEST_DIR}/secrets"
    cp "${SCRIPT_DIR}/conf/nginx/default.conf" "${NGINX_TEST_DIR}/conf.d/"
    test_key="sk-$(printf '%036d' 0)"
    printf '"Bearer %s" 1;\n' "$test_key" > "${NGINX_TEST_DIR}/secrets/api-key.map"
    if ! out="$("${DOCKER[@]}" run --rm --add-host ollama:127.0.0.1 \
            -v "${NGINX_TEST_DIR}/conf.d:/etc/nginx/conf.d:ro" \
            -v "${NGINX_TEST_DIR}/secrets:/etc/nginx/secrets:ro" \
            "$OLLAMA_EMBED_NGINX_IMAGE" nginx -t 2>&1)"; then
        echo "$out" >&2
        die "nginx 설정 검사 실패: conf/nginx/default.conf"
    fi
    grep -E 'syntax is ok|test is successful' <<<"$out" | sed 's/^/    /'
    rm -rf "$NGINX_TEST_DIR"; NGINX_TEST_DIR=""
    ok "nginx -t 통과 (${OLLAMA_EMBED_NGINX_IMAGE##*:}, 시험 키 ${#test_key}자)"
}

#--- 빌드한 이미지 검증 ------------------------------------------------
# 이미지를 실제로 띄워 모델 ID·양자화·차원·임베딩 응답까지 확인한다.
# GPU 이미지도 --gpus 없이 CPU 로 띄운다. 빌드 호스트에 GPU 가 없어도
# Q8_0 가중치가 정상인지 여기서 확인된다(GPU 경로 자체는 타깃에서 확인).
verify_built_image() {
    local image="$1" model="$2" id12="$3" quant="$4" c out id hostport n
    c="ollama-embed-verify-$$"
    "${DOCKER[@]}" rm -f "$c" >/dev/null 2>&1 || true
    "${DOCKER[@]}" run -d --rm --name "$c" -p 127.0.0.1::11434 "$image" >/dev/null \
        || die "검증 컨테이너 기동 실패: ${image}"
    VERIFY_CONTAINER="$c"
    retry_until 60 "${DOCKER[@]}" exec "$c" /bin/ollama list \
        || { "${DOCKER[@]}" logs "$c" 2>&1 | tail -n 20 >&2; die "ollama 가 응답하지 않는다: ${image}"; }

    out="$("${DOCKER[@]}" exec "$c" /bin/ollama list)"
    sed 's/^/    /' <<<"$out"
    id="$(awk -v m="$model" '$1 == m {print $2}' <<<"$out")"
    [[ "$id" == "$id12" ]] || die "이미지 안 모델 ID 불일치: 기대 ${id12} / 실제 ${id:-없음}"
    ok "모델 포함: ${model} (ID ${id})"

    out="$("${DOCKER[@]}" exec "$c" /bin/ollama show "$model")"
    sed 's/^/    /' <<<"$out"
    grep -Eq "quantization[[:space:]]+${quant}([[:space:]]|$)" <<<"$out" \
        || die "양자화가 ${quant} 가 아니다: ${model}"
    grep -Eq "embedding length[[:space:]]+${OLLAMA_EMBED_DIM}([[:space:]]|$)" <<<"$out" \
        || die "embedding length 가 ${OLLAMA_EMBED_DIM} 이 아니다: ${model}"
    grep -Eq '^[[:space:]]+embedding[[:space:]]*$' <<<"$out" \
        || die "capability 에 embedding 이 없다: ${model}"
    ok "양자화 ${quant} / embedding length ${OLLAMA_EMBED_DIM} / capability embedding"

    hostport="$("${DOCKER[@]}" port "$c" 11434/tcp | head -n 1)"
    [[ -n "$hostport" ]] || die "검증 컨테이너의 포트를 확인할 수 없다"
    out="$(curl -fsS --max-time 300 -H 'Content-Type: application/json' \
        -d "{\"model\":\"${model}\",\"input\":\"offline install verification\"}" \
        "http://${hostport}/api/embed")" || die "/api/embed 요청 실패: ${model}"
    n="$(vec_len_ollama <<<"$out")"
    [[ "$n" == "$OLLAMA_EMBED_DIM" ]] || die "/api/embed 벡터 길이 ${n} != ${OLLAMA_EMBED_DIM}"
    ok "/api/embed 응답 정상 (벡터 ${n}차원, CPU 실행)"

    "${DOCKER[@]}" rm -f "$c" >/dev/null 2>&1 || true
    VERIFY_CONTAINER=""
}

#--- flavor 별 번들 ----------------------------------------------------
NGINX_CHECKED=0
TARBALLS=()
for flavor in "${FLAVORS[@]}"; do
    case "$flavor" in
        cpu) MODEL="$OLLAMA_EMBED_CPU_MODEL"; MODEL_DIGEST="$OLLAMA_EMBED_CPU_MODEL_DIGEST"
             QUANT="$OLLAMA_EMBED_CPU_QUANT"; IMAGE="$OLLAMA_EMBED_CPU_IMAGE" ;;
        gpu) MODEL="$OLLAMA_EMBED_GPU_MODEL"; MODEL_DIGEST="$OLLAMA_EMBED_GPU_MODEL_DIGEST"
             QUANT="$OLLAMA_EMBED_GPU_QUANT"; IMAGE="$OLLAMA_EMBED_GPU_IMAGE" ;;
    esac
    ID12="${MODEL_DIGEST#sha256:}"; ID12="${ID12:0:12}"
    BUNDLE_NAME="ollama-embedding-${flavor}-${OLLAMA_VERSION}"
    BUNDLE_DIR="${SCRIPT_DIR}/bundle/${BUNDLE_NAME}"
    IMG_DIR="${BUNDLE_DIR}/images"
    CONF_DIR="${BUNDLE_DIR}/conf"

    step "${BUNDLE_NAME} 번들 빌드 (${MODEL}, ${QUANT})"
    # 생성물만 지운다. images/ 의 nginx tar 는 다운로드 캐시로 남긴다.
    rm -rf "${BUNDLE_DIR}/00-common" "${CONF_DIR}" "${BUNDLE_DIR}/90-verify"
    rm -f "${BUNDLE_DIR}"/*.sh "${BUNDLE_DIR}"/*.md \
          "${BUNDLE_DIR}/SHA256SUMS" "${BUNDLE_DIR}/BUNDLE-INFO" "${IMG_DIR}"/*.part
    mkdir -p "$IMG_DIR" "$CONF_DIR/nginx"

    step "nginx 이미지 (${OLLAMA_EMBED_NGINX_IMAGE})"
    fetch_nginx "${IMG_DIR}/${NGINX_TAR_NAME}"
    if ((NGINX_CHECKED == 0)); then
        check_nginx_conf "${IMG_DIR}/${NGINX_TAR_NAME}"
        NGINX_CHECKED=1
    fi

    step "이미지 빌드: ${IMAGE}"
    log "베이스 ${OLLAMA_BASE_IMAGE}@${OLLAMA_BASE_DIGEST}"
    # provenance / sbom 을 끈다. 켜 두면 attestation 이 붙어 결과가 단일
    # 매니페스트가 아닌 인덱스가 된다(70-mssql/fts-image/build-image.sh).
    "${DOCKER[@]}" build --platform linux/amd64 \
        --provenance=false --sbom=false --progress=plain \
        --build-arg "OLLAMA_BASE=${OLLAMA_BASE_IMAGE}@${OLLAMA_BASE_DIGEST}" \
        --build-arg "EMBED_MODEL=${MODEL}" \
        --build-arg "EMBED_MODEL_ID=${ID12}" \
        -t "$IMAGE" "${SCRIPT_DIR}/image" \
        || die "이미지 빌드 실패: ${IMAGE}"
    IMAGE_ID="$("${DOCKER[@]}" image inspect -f '{{.Id}}' "$IMAGE")"
    ok "빌드 완료: ${IMAGE} (${IMAGE_ID})"

    step "빌드 이미지 검증: ${IMAGE}"
    verify_built_image "$IMAGE" "$MODEL" "$ID12" "$QUANT"

    step "이미지 저장 (docker save)"
    IMG_TAR="${IMG_DIR}/$(image_to_filename "$IMAGE").tar"
    rm -f "$IMG_TAR" "${IMG_TAR}.part"
    "${DOCKER[@]}" save -o "${IMG_TAR}.part" "$IMAGE" || die "docker save 실패: ${IMAGE}"
    mv "${IMG_TAR}.part" "$IMG_TAR"
    ok "$(basename "$IMG_TAR") ($(du -h "$IMG_TAR" | cut -f1))"

    cp "${SCRIPT_DIR}/conf/docker-compose.yml.tmpl" "${CONF_DIR}/"
    cp "${SCRIPT_DIR}/conf/nginx/default.conf" "${CONF_DIR}/nginx/"
    printf '%s\n' "$flavor" > "${CONF_DIR}/flavor"
    printf '%s\n' "$IMAGE" "$OLLAMA_EMBED_NGINX_IMAGE" > "${CONF_DIR}/images.list"
    cat > "${CONF_DIR}/images.digests" <<EOF
# 빌드 시점 다이제스트
${OLLAMA_BASE_IMAGE} ${OLLAMA_BASE_DIGEST}
${OLLAMA_EMBED_NGINX_IMAGE} ${OLLAMA_EMBED_NGINX_DIGEST}
${MODEL} ${MODEL_DIGEST}
${IMAGE} ${IMAGE_ID}
EOF

    mkdir -p "${BUNDLE_DIR}/00-common"
    cp "${SCRIPT_DIR}/../00-common/versions.env" "${BUNDLE_DIR}/00-common/"
    if [[ -f "${SCRIPT_DIR}/../00-common/site.env" ]]; then
        cp "${SCRIPT_DIR}/../00-common/site.env" "${BUNDLE_DIR}/00-common/"
    else
        cp "${SCRIPT_DIR}/../00-common/site.env.example" "${BUNDLE_DIR}/00-common/"
        warn "site.env 가 없어 예시 값으로 번들을 만든다. 타깃 환경에 맞게 수정할 것."
    fi
    cp "${SCRIPT_DIR}/../00-common/common.sh" "${BUNDLE_DIR}/00-common/"
    cp -R "${SCRIPT_DIR}/../00-common/os"     "${BUNDLE_DIR}/00-common/"
    cp "${SCRIPT_DIR}/install.sh" "${BUNDLE_DIR}/"
    cp "${SCRIPT_DIR}/README.md" "${BUNDLE_DIR}/"
    chmod +x "${BUNDLE_DIR}/install.sh"

    if [[ "$flavor" == gpu ]]; then
        REQUIRES="Docker Engine + Compose v2.30+ / NVIDIA 드라이버 + nvidia-container-toolkit (README 4절)"
    else
        REQUIRES="Docker Engine + Compose v2.30+"
    fi
    cat > "${BUNDLE_DIR}/BUNDLE-INFO" <<EOF
bundle        : ${BUNDLE_NAME}
bundle_version: ${BUNDLE_VERSION}
built_at      : $(date -Is)
built_on      : $(hostname)
flavor        : ${flavor}
ollama_base   : ${OLLAMA_BASE_IMAGE}@${OLLAMA_BASE_DIGEST}
model         : ${MODEL} (${QUANT}, ${OLLAMA_EMBED_DIM}차원)
model_digest  : ${MODEL_DIGEST}
image         : ${IMAGE}
image_id      : ${IMAGE_ID}
nginx         : ${OLLAMA_EMBED_NGINX_IMAGE}@${OLLAMA_EMBED_NGINX_DIGEST}
listener      : HTTP ${OLLAMA_EMBED_PORT} (nginx, Bearer 키 검사) -> ollama 11434 (internal)
requires      : ${REQUIRES}
EOF

    write_manifest "$BUNDLE_DIR"
    step "아카이브"
    TARBALL="${SCRIPT_DIR}/bundle/${BUNDLE_NAME}.tar.gz"
    rm -f "$TARBALL" "${TARBALL}.sha256"
    # 모델 가중치는 거의 압축되지 않는다. pigz 가 있으면 병렬로 시간만 줄인다(형식은 같다).
    if command -v pigz >/dev/null 2>&1; then
        tar -C "${SCRIPT_DIR}/bundle" -I pigz -cf "$TARBALL" "$BUNDLE_NAME"
    else
        tar -C "${SCRIPT_DIR}/bundle" -czf "$TARBALL" "$BUNDLE_NAME"
    fi
    (cd "$(dirname "$TARBALL")" && sha256sum "$(basename "$TARBALL")") > "${TARBALL}.sha256"
    cat "${BUNDLE_DIR}/BUNDLE-INFO"
    echo
    ok "번들: ${TARBALL} ($(du -h "$TARBALL" | cut -f1))"
    TARBALLS+=("$TARBALL")
done

step "완료"
for t in "${TARBALLS[@]}"; do ok "$(basename "$t") ($(du -h "$t" | cut -f1))"; done
echo "  타깃으로 옮길 파일: <번들>.tar.gz 와 <번들>.tar.gz.sha256"
echo "  CPU 전용 VM 은 cpu 번들, NVIDIA GPU VM 은 gpu 번들 하나만 옮긴다(README 4절)."
