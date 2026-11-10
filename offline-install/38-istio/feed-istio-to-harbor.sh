#!/usr/bin/env bash
#---------------------------------------------------------------------
# 38-istio : 번들 안의 Istio 아티팩트 8개를 Harbor 에 등록한다 (오프라인)
#
#   ./feed-istio-to-harbor.sh --dry-run   # 올릴 목록·경로·명령만 출력. Harbor 에 접속하지 않고 계정도 묻지 않는다
#   ./feed-istio-to-harbor.sh             # 계정·비밀번호를 프롬프트로 묻고, 없는 것만 올린 뒤 결과를 확인한다
#   printf '%s\n' "$U" "$P" | ./feed-istio-to-harbor.sh
#                                         # 터미널이 아니면 stdin 두 줄(계정, 비밀번호)을 읽는다
#
# 언제 쓰는가:
#   AS 전체 hydrate(상위 README 5.2, hydrate-registry.sh + as-cmk 약 57GB) 전에 Istio 만 먼저
#   설치할 때, 또는 Harbor 를 새로 설치해 Istio 아티팩트가 없을 때(상위 README 5.2.8).
#   hydrate 와 같은 경로·태그로 올리므로 hydrate 를 먼저 하든 나중에 하든 충돌하지 않는다.
#
# 실행 위치: https://<HARBOR_HOSTNAME> 에 닿는 아무 호스트(점프 박스, Harbor 호스트, control plane).
#   kubeconfig·root·인터넷이 필요 없다. 번들만 쓴다.
# 필요한 명령: skopeo, helm(3.8 이상, OCI), curl, base64, sha256sum, tar, diff, getent.
#   하나라도 없으면 Harbor 에 접속하기 전에 멈춘다(--dry-run 이 미리 알려 준다).
#   skopeo 를 대신하는 경로(podman/docker load → push)는 두지 않았다. 레이어를 다시 압축해
#   다이제스트가 바뀌기 때문이다(README 4.2절).
#
# 올리는 것(versions.env 값, 경로·태그는 hydrate-registry.sh 와 같다):
#   이미지 <HARBOR_HOSTNAME>/<ISTIO_HARBOR_PROJECT>/<원본 경로>:<태그>        <- images/<이름>/ (skopeo dir 형식)
#   차트   oci://<HARBOR_HOSTNAME>/<ISTIO_HARBOR_PROJECT>/<차트 경로> <버전>  <- charts/*.tgz
#
# 규칙:
#   - Harbor 에 같은 태그가 이미 있으면 올리지 않는다. 다시 실행하면 모두 건너뛴다.
#   - Harbor 에서 지우거나 덮어쓰지 않는다. 프로젝트도 만들지 않는다(상위 README 5.2.3).
#   - 이미지는 매니페스트·레이어를 그대로 올린다. 이 도구가 올린 이미지의 Harbor 다이제스트는
#     versions.env 핀과 같다. 차트는 번들 tgz(sha256 = 핀)를 그대로 helm push 한다.
#   - 비밀번호는 stdin 으로만 받는다. 프로세스 인자와 로그에 남기지 않는다.
#     Harbor API 는 curl -K -(stdin), helm 은 --password-stdin, skopeo 는 임시 인증 파일
#     (mktemp -d 0700 디렉터리, 끝나면 지운다)로 넘긴다.
#   - CA 검증을 끄지 않는다. install.sh 와 같은 CA 후보(istio-lib.sh 의 HARBOR_CA)를 쓰고,
#     후보가 없으면 OS 신뢰 저장소로 검증한다.
#---------------------------------------------------------------------
BUNDLE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${BUNDLE_ROOT}/00-common/common.sh"
source "${BUNDLE_ROOT}/istio-lib.sh"

DRY_RUN=0
while (($#)); do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        *)         die "알 수 없는 인자: $1 (--dry-run)" ;;
    esac
    shift
done

IMAGE_DIR="${BUNDLE_ROOT}/images"
FEED_TOOLS=(skopeo helm curl base64 sha256sum tar diff getent)

# 올릴 것. 이미지: <원본 ref>|<다이제스트 핀>, 차트: <OCI 경로>|<버전>|<tgz sha256 핀>
FEED_IMAGES=(
    "${ISTIO_PILOT_IMAGE}|${ISTIO_PILOT_DIGEST}"
    "${ISTIO_PROXYV2_IMAGE}|${ISTIO_PROXYV2_DIGEST}"
    "${UIPATH_WASM_IMAGE}|${UIPATH_WASM_DIGEST}"
    "${UIPATH_ISTIO_CURL_IMAGE}|${UIPATH_ISTIO_CURL_DIGEST}"
)
FEED_CHARTS=(
    "${ISTIO_BASE_CHART}|${ISTIO_CHART_VERSION}|${ISTIO_BASE_CHART_SHA256}"
    "${ISTIO_ISTIOD_CHART}|${ISTIO_CHART_VERSION}|${ISTIO_ISTIOD_CHART_SHA256}"
    "${ISTIO_GATEWAY_CHART}|${ISTIO_CHART_VERSION}|${ISTIO_GATEWAY_CHART_SHA256}"
    "${UIPATH_ISTIO_CONFIGURE_CHART}|${UIPATH_ISTIO_CONFIGURE_VERSION}|${UIPATH_ISTIO_CONFIGURE_CHART_SHA256}"
)
FEED_TOTAL=$(( ${#FEED_IMAGES[@]} + ${#FEED_CHARTS[@]} ))

#=====================================================================
# 번들
#=====================================================================
image_dir() { echo "${IMAGE_DIR}/$(image_to_filename "$1")"; }   # $1=원본 ref

# 번들 이미지(skopeo dir 형식)가 핀과 같은가. $1=디렉터리 $2=핀(sha256:...)
# manifest.json 의 sha256 이 이미지 다이제스트다. 매니페스트가 가리키는 blob(config·레이어,
# 파일 이름 = sha256 hex)이 모두 있어야 한다. blob 내용은 SHA256SUMS(verify_manifest)가 본다.
bundle_image_ok() {
    local m="${1}/manifest.json" d
    local -a ds=()
    [[ -f "$m" ]] || { BAD="manifest.json 이 없다"; return 1; }
    [[ "sha256:$(sha256_of "$m")" == "$2" ]] || { BAD="manifest sha256 이 핀과 다르다"; return 1; }
    mapfile -t ds < <(grep -oE 'sha256:[0-9a-f]{64}' "$m")
    ((${#ds[@]} > 0)) || { BAD="manifest 에 blob 다이제스트가 없다"; return 1; }
    for d in "${ds[@]}"; do
        [[ -f "${1}/${d#sha256:}" ]] || { BAD="blob 이 없다: ${d}"; return 1; }
    done
}

check_bundle() {
    local e img pin ref ver t d
    for e in "${FEED_IMAGES[@]}"; do
        img="${e%%|*}"; pin="${e#*|}"; d="$(image_dir "$img")"
        bundle_image_ok "$d" "$pin" \
            || die "번들 이미지가 핀과 맞지 않는다: ${d#"${BUNDLE_ROOT}"/} (${BAD}). build-bundle.sh 로 다시 빌드할 것."
    done
    for e in "${FEED_CHARTS[@]}"; do
        IFS='|' read -r ref ver pin <<<"$e"
        t="$(bundle_chart "$ref" "$ver")"
        [[ -f "$t" && "$(sha256_of "$t")" == "$pin" ]] \
            || die "번들 차트가 없거나 sha256 이 핀과 다르다: ${t#"${BUNDLE_ROOT}"/}. build-bundle.sh 로 다시 빌드할 것."
    done
    ok "번들 아티팩트 ${FEED_TOTAL}개 = versions.env 핀 (이미지 manifest sha256, 차트 tgz sha256)"
}

#=====================================================================
# 도구
#=====================================================================
MISSING=()
find_missing_tools() {
    local c
    MISSING=()
    for c in "${FEED_TOOLS[@]}"; do command -v "$c" >/dev/null 2>&1 || MISSING+=("$c"); done
}

# helm 3.8 이상(OCI 기본 지원). helm 4 도 된다.
helm_oci_ok() {
    local v maj min
    v="$(helm version --short 2>/dev/null || true)"; v="${v#v}"
    maj="${v%%.*}"; min="${v#*.}"; min="${min%%.*}"
    [[ "$maj" =~ ^[0-9]+$ && "$min" =~ ^[0-9]+$ ]] && ((maj > 3 || (maj == 3 && min >= 8)))
}

# skopeo 에 --preserve-digests 가 있으면 쓴다. 다이제스트를 지킬 수 없으면(형식 변환이 필요하면)
# 올리지 않고 실패한다. 옛 skopeo 에는 이 옵션이 없다. 그때도 dir -> docker 는 형식을 바꾸지
# 않으므로 다이제스트가 그대로이고, 올린 뒤 Harbor 다이제스트 = 핀 을 확인한다.
PRESERVE=""
detect_preserve() {
    local h
    h="$(skopeo copy --help 2>/dev/null || true)"
    if [[ "$h" == *--preserve-digests* ]]; then PRESERVE="--preserve-digests"; else PRESERVE=""; fi
}
preserve_desc() {
    if [[ -n "$PRESERVE" ]]; then echo "--preserve-digests 있음"
    else echo "--preserve-digests 없음, 올린 뒤 Harbor 다이제스트 = 핀 으로 확인"; fi
}

#=====================================================================
# Harbor
#=====================================================================
# Harbor API GET(자격증명은 hcurl_auth 로 stdin 에). 결과: HTTP_CODE(000 = 접속·TLS 실패),
# HTTP_BODY(200 일 때만 채워진다. hcurl 의 -f 가 오류 본문을 버린다).
HTTP_CODE=""; HTTP_BODY=""
harbor_get() {
    local resp
    resp="$(hcurl_auth -w '\n%{http_code}' "$1" 2>/dev/null)" || true
    HTTP_CODE="${resp##*$'\n'}"; HTTP_BODY="${resp%$'\n'*}"
    [[ "$HTTP_CODE" =~ ^[0-9]{3}$ ]] || { HTTP_CODE="000"; HTTP_BODY=""; }
}

# Harbor artifact JSON 의 다이제스트. 응답의 첫 "digest" 가 아티팩트 자신의 것이다
# (with_accessory 를 주지 않으면 accessories 가 없다).
body_digest() {
    local re='"digest":[[:space:]]*"(sha256:[0-9a-f]{64})"'
    if [[ "$HTTP_BODY" =~ $re ]]; then echo "${BASH_REMATCH[1]}"; fi
}

# 저장소:태그 가 Harbor 에 있는가. 200 = 있음, 404 = 없음. 그 밖의 응답이면 멈춘다.
artifact_exists() {   # $1=저장소(istio/pilot) $2=태그
    local url; url="$(harbor_artifact_url "$1" "$2")"
    harbor_get "$url"
    case "$HTTP_CODE" in
        200) return 0 ;;
        404) return 1 ;;
        *)   die "Harbor API 응답 ${HTTP_CODE}: ${url} (401 = 계정·비밀번호, 403 = 권한, 000 = 접속·인증서)" ;;
    esac
}

# 계정·비밀번호를 stdin 으로 받는다. 이름은 istio-lib.sh 의 hcurl_auth·harbor_helm_login 이
# 읽는 PULL_USER/PULL_PASS 를 그대로 쓴다(여기서는 push 권한이 있는 계정이다).
read_credentials() {
    PULL_USER=""; PULL_PASS=""
    if [[ -t 0 ]]; then
        IFS= read -r -p "Harbor 계정(${PROJECT} 프로젝트 push 권한): " PULL_USER
        IFS= read -rs -p 'Harbor 비밀번호: ' PULL_PASS; echo >&2
    else
        IFS= read -r PULL_USER || true
        IFS= read -r PULL_PASS || true
    fi
    [[ -n "$PULL_USER" && -n "$PULL_PASS" ]] \
        || die "Harbor 계정과 비밀번호가 필요하다. 터미널에서 실행하거나 stdin 두 줄(계정, 비밀번호)로 넘길 것(README 4.2절)."
}

# skopeo 인증 파일과 CA 디렉터리. mktemp -d 는 0700 이고 EXIT 때 istio_cleanup 이 지운다.
# auth 는 base64 "계정:비밀번호" 다. printf 는 셸 내장이고 base64 는 stdin 으로 받으므로
# 프로세스 인자에 남지 않는다(--dest-creds 는 인자에 보여서 쓰지 않는다).
SKOPEO_AUTH=""; SKOPEO_CERT=()
skopeo_setup() {
    [[ -z "$SKOPEO_AUTH" ]] || return 0
    local d auth
    mktemp_tracked -d; d="$TMP_LAST"
    auth="$(printf '%s:%s' "$PULL_USER" "$PULL_PASS" | base64 -w0)"
    printf '{"auths":{"%s":{"auth":"%s"}}}\n' "$HARBOR_HOST" "$auth" > "${d}/auth.json"
    SKOPEO_AUTH="${d}/auth.json"
    if [[ -n "$HARBOR_CA" ]]; then
        # --dest-cert-dir 는 *.crt 를 CA 로, *.cert/*.key 를 클라이언트 인증서로 읽는다.
        # /opt/pki/ca 처럼 키가 함께 있을 수 있는 디렉터리를 주지 않고 CA 만 복사해 준다.
        mkdir "${d}/certs"
        cp "$HARBOR_CA" "${d}/certs/ca.crt"
        SKOPEO_CERT=(--dest-cert-dir "${d}/certs")
    fi
}

push_image() {   # $1=번들 디렉터리 $2=대상 ref
    skopeo_setup
    # --dest-tls-verify=true 를 명시한다. registries.conf 에 insecure 로 적힌 레지스트리라도
    # 검증을 끄지 않게 하려는 것이다.
    skopeo copy ${PRESERVE:+"$PRESERVE"} --retry-times 3 --dest-tls-verify=true \
        --dest-authfile "$SKOPEO_AUTH" ${SKOPEO_CERT[@]+"${SKOPEO_CERT[@]}"} \
        "dir:${1}" "docker://${2}" >/dev/null \
        || die "skopeo copy 실패: ${2}. 이미 올린 것은 남는다. 원인을 고친 뒤 다시 실행하면 없는 것만 올린다."
}

push_chart() {   # $1=번들 tgz $2=OCI 경로(vendor/base). 결과: PUSH_DIGEST
    local out args=(--registry-config "$HELM_REGCFG") re='Digest:[[:space:]]*(sha256:[0-9a-f]{64})'
    [[ -z "$HARBOR_CA" ]] || args+=(--ca-file "$HARBOR_CA")
    # helm push 는 oci://<레지스트리>/<프로젝트>/<첫 경로> 아래에 Chart.yaml 의 name 으로 올린다
    # (hydrate-registry.sh import_sf_charts 와 같은 규칙).
    out="$(helm push "$1" "oci://${HARBOR_REGISTRY}/${2%/*}" "${args[@]}" 2>&1)" || {
        printf '%s\n' "$out" | sed 's/^/    /' >&2
        die "helm push 실패: ${1##*/} -> oci://${HARBOR_REGISTRY}/${2%/*}. 이미 올린 것은 남는다. 원인을 고친 뒤 다시 실행하면 없는 것만 올린다."
    }
    PUSH_DIGEST=""
    if [[ "$out" =~ $re ]]; then PUSH_DIGEST="${BASH_REMATCH[1]}"; fi
}

# Harbor 에서 차트를 받아 핀과 대조한다(install.sh 의 harbor_chart_pull 과 같은 기준, README 4.3절).
# 멈추지 않고 결과만 돌려준다. 결과: CHART_NOTE
chart_matches_pin() {   # $1=OCI 경로 $2=버전 $3=핀
    local ref="$1" ver="$2" pin="$3" f got
    local args=(--version "$ver" --registry-config "$HELM_REGCFG")
    [[ -z "$HARBOR_CA" ]] || args+=(--ca-file "$HARBOR_CA")
    mktemp_tracked -d
    helm pull "oci://${HARBOR_REGISTRY}/${ref}" "${args[@]}" -d "$TMP_LAST" >/dev/null 2>&1 \
        || { CHART_NOTE="helm pull --version ${ver} 실패"; return 1; }
    f="${TMP_LAST}/${ref##*/}-${ver}.tgz"
    [[ -f "$f" ]] || { CHART_NOTE="받은 파일 이름이 예상과 다르다: $(ls "$TMP_LAST")"; return 1; }
    got="$(sha256_of "$f")"
    if [[ "$got" == "$pin" ]]; then
        CHART_NOTE="helm pull --version ${ver}, tgz sha256 = 핀"
        return 0
    fi
    if chart_content_same "$f" "$(bundle_chart "$ref" "$ver")"; then
        CHART_NOTE="helm pull --version ${ver}, tgz sha256 ${got} ≠ 핀, 재패키징(내용 = 핀, 파일 ${CHART_DIFF_FILES}개)"
        return 0
    fi
    CHART_NOTE="helm pull --version ${ver}, tgz sha256 ${got}, 내용이 핀과 다르다: ${CHART_DIFF_OUT//$'\n'/; }"
    return 1
}

#=====================================================================
# --dry-run: Harbor 에 접속하지 않는다
#=====================================================================
do_dry_run() {
    local e img pin path d ref ver tgz c
    step "dry-run: Harbor 등록 계획"
    verify_manifest "$BUNDLE_ROOT"
    check_bundle
    [[ -n "$HARBOR_HOST" ]] || die "site.env 에 HARBOR_HOSTNAME 이 없다"
    command -v skopeo >/dev/null 2>&1 && detect_preserve

    echo "  대상          : ${HARBOR_REGISTRY} (HARBOR_HOSTNAME / ISTIO_HARBOR_PROJECT)"
    echo "  CA            : ${HARBOR_CA_DESC}"
    echo "  사전 확인     : https://${HARBOR_HOST}/api/v2.0/ping, GET /api/v2.0/projects/${PROJECT} (계정·비밀번호는 stdin)"
    echo "  규칙          : 같은 태그가 있으면 건너뛴다. 지우거나 덮어쓰지 않는다. 프로젝트는 만들지 않는다."
    echo
    echo "  이미지 ${#FEED_IMAGES[@]}개 (없을 때만 skopeo copy, 매니페스트·레이어 그대로)"
    for e in "${FEED_IMAGES[@]}"; do
        img="${e%%|*}"; pin="${e#*|}"; path="${img#*/}"; d="$(image_dir "$img")"
        echo "    ${HARBOR_REGISTRY}/${path}"
        echo "      원본    ${img%:*}@${pin}"
        echo "      번들    ${d#"${BUNDLE_ROOT}"/}/ ($(du -sh "$d" | cut -f1))"
        echo "      있는지  GET $(harbor_artifact_url "${path%:*}" "${path##*:}")"
        echo "      올리기  skopeo copy ${PRESERVE:+${PRESERVE} }--retry-times 3 --dest-tls-verify=true --dest-authfile <임시>${HARBOR_CA:+ --dest-cert-dir <CA 사본>} dir:${d#"${BUNDLE_ROOT}"/} docker://${HARBOR_REGISTRY}/${path}"
    done
    echo
    echo "  차트 ${#FEED_CHARTS[@]}개 (없을 때만 helm push, 번들 tgz 그대로)"
    for e in "${FEED_CHARTS[@]}"; do
        IFS='|' read -r ref ver pin <<<"$e"
        tgz="$(bundle_chart "$ref" "$ver")"
        echo "    oci://${HARBOR_REGISTRY}/${ref} --version ${ver}"
        echo "      번들    ${tgz#"${BUNDLE_ROOT}"/} (sha256 ${pin})"
        echo "      있는지  GET $(harbor_artifact_url "$ref" "$ver")"
        echo "      올리기  helm push ${tgz#"${BUNDLE_ROOT}"/} oci://${HARBOR_REGISTRY}/${ref%/*} --registry-config <임시>${HARBOR_CA:+ --ca-file ${HARBOR_CA}}"
    done
    echo
    echo "  등록 뒤 확인  : 이미지 = Harbor API 태그와 다이제스트(= 핀), 차트 = helm pull --version + tgz sha256"
    echo "                  (다르면 번들 차트와 내용 대조, README 4.3절)"

    step "dry-run: 이 호스트의 도구"
    find_missing_tools
    for c in "${FEED_TOOLS[@]}"; do
        if command -v "$c" >/dev/null 2>&1; then echo "  OK   ${c} ($(command -v "$c"))"; else echo "  없음 ${c}"; fi
    done
    if command -v helm >/dev/null 2>&1; then
        if helm_oci_ok; then echo "  OK   helm $(helm version --short 2>/dev/null) (3.8 이상)"
        else echo "  부족 helm $(helm version --short 2>/dev/null) (3.8 이상 필요)"; MISSING+=("helm>=3.8"); fi
    fi
    if command -v skopeo >/dev/null 2>&1; then
        echo "  OK   $(skopeo --version) ($(preserve_desc))"
    fi
    if ((${#MISSING[@]} > 0)); then
        warn "실제 실행은 사전 확인에서 멈춘다(Harbor 는 바뀌지 않는다): ${MISSING[*]}. README 4.2절의 도구 항목을 볼 것."
    fi
    ok "dry-run 끝 (Harbor 에 접속하지 않았다)"
}

if ((DRY_RUN)); then
    do_dry_run; exit 0
fi

#=====================================================================
# 0. 사전 확인 (Harbor 를 바꾸지 않는다)
#=====================================================================
step "사전 확인"
verify_manifest "$BUNDLE_ROOT"
check_bundle
find_missing_tools
((${#MISSING[@]} == 0)) \
    || die "필요한 명령이 없다: ${MISSING[*]}. 이 호스트에 설치하거나, 도구가 있고 Harbor 에 닿는 다른 호스트에서 실행할 것(README 4.2절)."
helm_oci_ok || die "helm 3.8 이상이 필요하다(OCI): $(helm version --short 2>/dev/null || echo '?')"
detect_preserve
ok "도구: $(skopeo --version) ($(preserve_desc)), helm $(helm version --short 2>/dev/null), curl"

[[ -n "$HARBOR_HOST" ]] || die "site.env 에 HARBOR_HOSTNAME 이 없다"
getent hosts "$HARBOR_HOST" >/dev/null \
    || die "${HARBOR_HOST} 를 해석하지 못한다. /etc/hosts 또는 사내 DNS 에 등록할 것."
[[ "$(hcurl "https://${HARBOR_HOST}/api/v2.0/ping" 2>/dev/null)" == "Pong" ]] \
    || die "https://${HARBOR_HOST} 에 닿지 않거나 인증서 검증에 실패했다(CA: ${HARBOR_CA_DESC}). 05-certs deploy-certs.sh --local 로 사내 CA 를 신뢰시킬 것."
ok "Harbor 응답 + 인증서 검증 (CA: ${HARBOR_CA_DESC})"

read_credentials
harbor_get "https://${HARBOR_HOST}/api/v2.0/projects/${PROJECT}"
case "$HTTP_CODE" in
    200) ;;
    401) die "Harbor 인증 실패(계정 ${PULL_USER}). 계정과 비밀번호를 확인할 것." ;;
    403|404) die "프로젝트 ${PROJECT} 가 없거나 계정 ${PULL_USER} 가 볼 수 없다(HTTP ${HTTP_CODE}). 프로젝트를 먼저 만들 것(상위 README 5.2.3). 이 도구는 프로젝트를 만들지 않는다." ;;
    *)   die "Harbor API 응답 ${HTTP_CODE}: projects/${PROJECT}" ;;
esac
VIS="private"; [[ "$HTTP_BODY" != *'"public":"true"'* ]] || VIS="public"
ok "프로젝트 ${PROJECT} (${VIS}), 계정 ${PULL_USER}"

#=====================================================================
# 1. Harbor 에 있는지 본다
#=====================================================================
step "Harbor 에 있는지 확인 (${HARBOR_REGISTRY})"
TODO_IMAGES=(); TODO_CHARTS=(); SKIPPED=0
for e in "${FEED_IMAGES[@]}"; do
    img="${e%%|*}"; path="${img#*/}"
    if artifact_exists "${path%:*}" "${path##*:}"; then
        log "있음, 건너뜀: ${path}"; SKIPPED=$((SKIPPED + 1))
    else
        log "없음, 올린다: ${path}"; TODO_IMAGES+=("$e")
    fi
done
for e in "${FEED_CHARTS[@]}"; do
    IFS='|' read -r ref ver pin <<<"$e"
    if artifact_exists "$ref" "$ver"; then
        log "있음, 건너뜀: ${ref}:${ver}"; SKIPPED=$((SKIPPED + 1))
    else
        log "없음, 올린다: ${ref}:${ver}"; TODO_CHARTS+=("$e")
    fi
done

#=====================================================================
# 2. 없는 것만 올린다
#=====================================================================
PUSHED=" "   # 이번에 올린 저장소:태그 (공백으로 감싼 목록)
if ((${#TODO_IMAGES[@]} + ${#TODO_CHARTS[@]} == 0)); then
    ok "${FEED_TOTAL}개 모두 Harbor 에 있다. 올릴 것이 없다."
else
    step "등록 (이미지 ${#TODO_IMAGES[@]}개, 차트 ${#TODO_CHARTS[@]}개)"
    for e in ${TODO_IMAGES[@]+"${TODO_IMAGES[@]}"}; do
        img="${e%%|*}"; path="${img#*/}"
        log "skopeo copy -> ${HARBOR_REGISTRY}/${path}"
        push_image "$(image_dir "$img")" "${HARBOR_REGISTRY}/${path}"
        PUSHED+="${path} "
        ok "올림: ${HARBOR_REGISTRY}/${path}"
    done
    if ((${#TODO_CHARTS[@]} > 0)); then
        harbor_helm_login
        for e in "${TODO_CHARTS[@]}"; do
            IFS='|' read -r ref ver pin <<<"$e"
            log "helm push -> oci://${HARBOR_REGISTRY}/${ref} ${ver}"
            push_chart "$(bundle_chart "$ref" "$ver")" "$ref"
            PUSHED+="${ref}:${ver} "
            ok "올림: oci://${HARBOR_REGISTRY}/${ref} ${ver}${PUSH_DIGEST:+ (매니페스트 ${PUSH_DIGEST})}"
        done
    fi
fi

#=====================================================================
# 3. 결과 확인 (8개 모두, 이미 있던 것 포함)
#=====================================================================
step "등록 결과 확인 (Harbor API, helm pull)"
for e in "${FEED_IMAGES[@]}"; do
    img="${e%%|*}"; pin="${e#*|}"; path="${img#*/}"
    harbor_get "$(harbor_artifact_url "${path%:*}" "${path##*:}")"
    if [[ "$HTTP_CODE" != "200" ]]; then
        check "이미지 ${PROJECT}/${path}: Harbor 에 있음 (HTTP ${HTTP_CODE})" false
        continue
    fi
    got="$(body_digest)"
    if [[ "$got" == "$pin" ]]; then
        check "이미지 ${PROJECT}/${path}: 다이제스트 ${got} = 핀" true
    elif [[ "$PUSHED" == *" ${path} "* ]]; then
        check "이미지 ${PROJECT}/${path}: 다이제스트 ${got:-?} = 핀 ${pin}" false
    else
        # hydrate 의 podman push 는 레이어를 다시 압축해 다이제스트가 원본과 다를 수 있다(README 4.3절).
        # install.sh 는 태그로 받으므로 설치에는 지장이 없다. 덮어쓰지 않는다.
        warn "이미지 ${PROJECT}/${path}: 이미 있던 이미지의 다이제스트 ${got:-?} 가 핀 ${pin} 과 다르다. 덮어쓰지 않는다(install.sh 는 태그로 받는다)."
        check "이미지 ${PROJECT}/${path}: 태그 있음 (이전에 올라간 것, 다이제스트 ≠ 핀)" true
    fi
done
harbor_helm_login
for e in "${FEED_CHARTS[@]}"; do
    IFS='|' read -r ref ver pin <<<"$e"
    harbor_get "$(harbor_artifact_url "$ref" "$ver")"
    if [[ "$HTTP_CODE" != "200" ]]; then
        check "차트 ${PROJECT}/${ref}:${ver}: Harbor 에 있음 (HTTP ${HTTP_CODE})" false
        continue
    fi
    got="$(body_digest)"
    if chart_matches_pin "$ref" "$ver" "$pin"; then
        check "차트 ${PROJECT}/${ref}:${ver} (매니페스트 ${got:-?}): ${CHART_NOTE}" true
    else
        check "차트 ${PROJECT}/${ref}:${ver} (매니페스트 ${got:-?}): ${CHART_NOTE}" false
    fi
done

rc=0
check_summary || rc=$?
step "요약"
echo "  Harbor ${HARBOR_REGISTRY}: 올림 $((FEED_TOTAL - SKIPPED)) / 건너뜀 ${SKIPPED} / 전체 ${FEED_TOTAL}"
if ((rc != 0)); then
    echo "  실패 항목은 덮어쓰지 않았다. 차트 내용이 다르면 hydrate 한 AS 버전과 UIPATH_AS_VERSION 을 대조할 것(README 12절)."
fi
step "다음 단계"
echo "  control plane 에서 sudo ./install.sh (private 프로젝트면 pull 계정을 stdin 으로, README 4.5절)"
echo "  이어서 sudo ./istio-configure.sh"
exit $rc
