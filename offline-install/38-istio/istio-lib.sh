#!/usr/bin/env bash
#---------------------------------------------------------------------
# 38-istio : install.sh / istio-configure.sh 공통 함수 (source 전용)
#
# 사용법: 00-common/common.sh 를 source 한 뒤
#   source "${BUNDLE_ROOT}/istio-lib.sh"
#   istio_parse_args "$@"
#
# 이미지·차트 출처(--source):
#   harbor (기본)  README 5.2 의 hydrate 가 Harbor 에 올린 경로에서 받는다.
#                  이미지 <HARBOR_HOSTNAME>/<ISTIO_HARBOR_PROJECT>/<원본 경로>:<태그>
#                  차트   oci://<HARBOR_HOSTNAME>/<ISTIO_HARBOR_PROJECT>/<차트 경로>
#   local          단일 노드 검증 전용. 차트는 번들 charts/, 이미지는 검증용 묶음
#                  (istio-local-images-<버전>, build-bundle.sh ISTIO_LOCAL_IMAGES=1)을
#                  containerd(k8s.io)에 직접 넣는다. 다중 노드에서는 쓰지 않는다
#                  (다른 노드의 사이드카가 proxyv2 를 받지 못한다).
#---------------------------------------------------------------------
# shellcheck disable=SC2034

NS="${ISTIO_NAMESPACE}"
GW="${ISTIO_GATEWAY_NAME}"
CHART_DIR="${BUNDLE_ROOT}/charts"
CONF_DIR="${BUNDLE_ROOT}/conf"
LOCAL_IMAGES_DIR="${ISTIO_LOCAL_IMAGES_DIR:-${BUNDLE_ROOT}/../istio-local-images-${ISTIO_VERSION}}"
KC=/etc/kubernetes/admin.conf

HARBOR_HOST="${HARBOR_HOSTNAME:-}"
PROJECT="${ISTIO_HARBOR_PROJECT}"
LOCAL_REGISTRY="${ISTIO_SOURCE_REGISTRY}"
HARBOR_REGISTRY="${HARBOR_HOST}/${PROJECT}"

MODE="install"
SOURCE=""

istio_parse_args() {
    while (($#)); do
        case "$1" in
            --check-only) MODE="check" ;;
            --uninstall)  MODE="uninstall" ;;
            --dry-run)    MODE="dry-run" ;;
            --source)     SOURCE="${2:?--source 에 값이 없다 (harbor | local)}"; shift ;;
            *)            die "알 수 없는 인자: $1 (--check-only | --uninstall | --dry-run | --source harbor|local)" ;;
        esac
        shift
    done
    [[ -z "$SOURCE" || "$SOURCE" == "harbor" || "$SOURCE" == "local" ]] \
        || die "--source 값이 잘못됐다: ${SOURCE} (harbor | local)"
}

# 출처별 레지스트리 접두사. 이미지 = <레지스트리>/<원본 경로>
registry_for() {
    if [[ "$1" == "local" ]]; then echo "$LOCAL_REGISTRY"; else echo "$HARBOR_REGISTRY"; fi
}

# 레지스트리 접두사 -> 출처(배포된 리소스에서 판별할 때)
source_of_registry() {
    case "$1" in
        "$LOCAL_REGISTRY")  echo local ;;
        "$HARBOR_REGISTRY") echo harbor ;;
        *)                  echo "" ;;
    esac
}

# 번들 안 차트 경로. $1=OCI 경로(vendor/base) $2=버전
bundle_chart() { echo "${CHART_DIR}/${1##*/}-${2}.tgz"; }

sha256_of() { sha256sum "$1" | cut -d' ' -f1; }

#--- 임시 파일 정리 -----------------------------------------------------
# 자격증명이 든 helm registry config 도 여기서 지운다.
TMP_PATHS=()
CLEANUP_HOOKS=()
istio_cleanup() {
    local h
    for h in ${CLEANUP_HOOKS[@]+"${CLEANUP_HOOKS[@]}"}; do "$h" || true; done
    ((${#TMP_PATHS[@]} == 0)) || rm -rf "${TMP_PATHS[@]}"
}
trap istio_cleanup EXIT

mktemp_tracked() {   # $1=-d 이면 디렉터리. 결과는 TMP_LAST 에 둔다(서브셸을 피한다).
    if [[ "${1:-}" == "-d" ]]; then TMP_LAST="$(mktemp -d)"; else TMP_LAST="$(mktemp)"; fi
    TMP_PATHS+=("$TMP_LAST")
}

#--- 클러스터 -----------------------------------------------------------
cluster_ready() {
    export KUBECONFIG="$KC"
    [[ -f "$KC" ]] || die "control plane 이 아니다(${KC} 없음). 10-k8s 를 먼저 설치할 것."
    kubectl get nodes -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null \
        | grep -q True || die "Ready 노드가 없다. 60-cilium 을 먼저 설치할 것."
    ok "클러스터 Ready"
}

# 이 노드의 IP. 10-k8s 와 같은 방식이다. 기본 경로가 없으면 첫 주소를 쓴다.
node_ip() {
    local ip
    ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="src"){print $(i+1); exit}}')"
    [[ -n "$ip" ]] || ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    echo "$ip"
}

deploy_available() {
    [[ "$(kubectl -n "$NS" get deploy "$1" -o jsonpath='{.status.availableReplicas}' 2>/dev/null)" =~ ^[1-9] ]]
}

release_deployed() {
    local l
    l="$(helm -n "$NS" list --deployed -q 2>/dev/null)"
    grep -qxF "$1" <<<"$l"
}

#--- local: 검증용 이미지 묶음 --------------------------------------------
# $1 = 묶음 안 conf/ 의 목록 파일 이름(images-istio.list | images-uipath.list)
local_images_import() {
    local list="${LOCAL_IMAGES_DIR}/conf/$1" img tar
    local -a miss=()
    [[ -d "$LOCAL_IMAGES_DIR" ]] \
        || die "검증용 이미지 묶음이 없다: ${LOCAL_IMAGES_DIR}
       build-bundle.sh 를 ISTIO_LOCAL_IMAGES=1 로 빌드하고 istio-local-images-${ISTIO_VERSION}.tar.gz 를
       이 번들과 같은 디렉터리에 풀 것(또는 ISTIO_LOCAL_IMAGES_DIR 지정). 운영은 --source harbor."
    verify_manifest "$LOCAL_IMAGES_DIR"
    [[ -f "$list" ]] || die "목록이 없다: ${list}"
    require_cmds ctr
    while read -r img; do
        [[ -n "$img" ]] || continue
        tar="${LOCAL_IMAGES_DIR}/images/$(image_to_filename "$img").tar"
        [[ -f "$tar" ]] || die "이미지 tar 가 없다: ${tar}"
        ctr_import "$tar"
    done < "$list"
    mapfile -t miss < <(ctr_missing_images "$list")
    ((${#miss[@]} == 0)) || die "적재되지 않은 이미지: ${miss[*]}"
    ok "이미지 $(grep -c . "$list")개 적재 확인 (k8s.io)"
}

# 이미지들이 containerd(k8s.io)에 있는가. 인자는 이미지 ref 들.
images_in_containerd() {
    mktemp_tracked
    printf '%s\n' "$@" > "$TMP_LAST"
    [[ -z "$(ctr_missing_images "$TMP_LAST")" ]]
}

#--- harbor -------------------------------------------------------------
# Harbor 접속에 쓸 CA. 35-metrics-server 와 같은 후보 순서다(05-certs deploy-certs 가 배치).
HARBOR_CA=""
for _c in "/etc/docker/certs.d/${HARBOR_HOST}/ca.crt" \
          "/etc/containerd/certs.d/${HARBOR_HOST}/ca.crt" \
          /opt/pki/ca/ca.crt; do
    [[ -n "$HARBOR_HOST" && -f "$_c" ]] && { HARBOR_CA="$_c"; break; }
done
unset _c

hcurl() {   # Harbor API 호출. CA 검증을 끄지 않는다.
    curl -fsS --max-time 15 ${HARBOR_CA:+--cacert "$HARBOR_CA"} "$@"
}

# pull 자격증명. private 프로젝트일 때만 쓴다.
#   1) HARBOR_PULL_USER / HARBOR_PULL_PASSWORD (Harbor robot 계정 권장)
#   2) 35-metrics-server 와 같은 순서: HARBOR_USER / HARBOR_PASSWORD
#      -> site.env 의 HARBOR_ADMIN_PASSWORD(admin) -> /opt/harbor/.harbor-credentials
harbor_pull_creds() {
    PULL_USER="${HARBOR_PULL_USER:-}"
    PULL_PASS="${HARBOR_PULL_PASSWORD:-}"
    if [[ -z "$PULL_USER" || -z "$PULL_PASS" ]]; then
        PULL_USER="${HARBOR_USER:-admin}"
        PULL_PASS="${HARBOR_PASSWORD:-${HARBOR_ADMIN_PASSWORD:-}}"
        if [[ -z "$PULL_PASS" && -f /opt/harbor/.harbor-credentials ]]; then
            PULL_PASS="$(grep -E '^HARBOR_ADMIN_PASSWORD=' /opt/harbor/.harbor-credentials | cut -d= -f2-)"
        fi
        [[ -n "$PULL_PASS" ]] || return 1
        warn "HARBOR_PULL_USER 가 없어 ${PULL_USER} 계정으로 pull 한다. 운영에서는 Harbor robot 계정을 쓸 것."
    fi
}

# Harbor API 의 아티팩트 URL. 저장소 이름의 '/' 는 두 번 인코딩한다(%252F, 35 와 같다).
harbor_artifact_url() {   # $1=저장소(istio/pilot) $2=태그
    echo "https://${HARBOR_HOST}/api/v2.0/projects/${PROJECT}/repositories/${1//\//%252F}/artifacts/${2}"
}

# harbor 경로 사전 확인. 결과: HARBOR_PUBLIC=true|false, private 이면 PULL_USER/PULL_PASS.
HARBOR_PUBLIC=""
harbor_preflight() {
    step "Harbor 확인 (${HARBOR_REGISTRY})"
    [[ -n "$HARBOR_HOST" ]] || die "site.env 에 HARBOR_HOSTNAME 이 없다"
    getent hosts "$HARBOR_HOST" >/dev/null \
        || die "${HARBOR_HOST} 를 해석하지 못한다. /etc/hosts 또는 사내 DNS 에 등록할 것(모든 노드)."
    [[ -n "$HARBOR_CA" ]] \
        || die "Harbor CA 를 찾지 못했다. 05-certs 의 deploy-certs.sh --local 을 먼저 실행할 것."
    [[ -f "/etc/containerd/certs.d/${HARBOR_HOST}/hosts.toml" ]] \
        || die "containerd 가 ${HARBOR_HOST} 를 신뢰하도록 설정되지 않았다(/etc/containerd/certs.d/${HARBOR_HOST}/hosts.toml 없음). 05-certs deploy-certs.sh --local."
    [[ "$(hcurl "https://${HARBOR_HOST}/api/v2.0/ping" 2>/dev/null)" == "Pong" ]] \
        || die "https://${HARBOR_HOST} 에 닿지 않거나 인증서 검증에 실패했다(CA: ${HARBOR_CA})."
    ok "Harbor 응답 + 인증서 검증 (CA: ${HARBOR_CA})"

    # 익명으로 프로젝트를 읽을 수 있으면 public 이다. 아니면 자격증명으로 다시 본다.
    local body
    body="$(hcurl "https://${HARBOR_HOST}/api/v2.0/projects/${PROJECT}" 2>/dev/null || true)"
    if [[ "$body" == *'"public":"true"'* ]]; then
        HARBOR_PUBLIC="true"
        ok "프로젝트 ${PROJECT} public — pull secret 없이 받는다"
    else
        HARBOR_PUBLIC="false"
        harbor_pull_creds \
            || die "프로젝트 ${PROJECT} 를 익명으로 읽을 수 없다(private 이거나 없음). HARBOR_PULL_USER/HARBOR_PULL_PASSWORD 를 줄 것."
        hcurl -u "${PULL_USER}:${PULL_PASS}" "https://${HARBOR_HOST}/api/v2.0/projects/${PROJECT}" >/dev/null 2>&1 \
            || die "프로젝트 ${PROJECT} 를 읽지 못했다(사용자 ${PULL_USER}). README 5.2 의 hydrate 와 프로젝트 이름(ISTIO_HARBOR_PROJECT)을 확인할 것."
        ok "프로젝트 ${PROJECT} private — ${NS} 에 pull secret ${ISTIO_PULL_SECRET} 를 만든다 (사용자 ${PULL_USER})"
    fi
}

# hydrate 결과 확인: 저장소:태그 가 Harbor 에 있는가.
harbor_require_artifact() {   # $1=저장소 $2=태그
    local auth=()
    [[ "$HARBOR_PUBLIC" == "true" ]] || auth=(-u "${PULL_USER}:${PULL_PASS}")
    hcurl "${auth[@]}" "$(harbor_artifact_url "$1" "$2")" >/dev/null 2>&1 \
        || die "Harbor 에 ${PROJECT}/${1}:${2} 가 없다. README 5.2 의 hydrate(hydrate-registry.sh)를 먼저 실행할 것."
    ok "Harbor 에 있음: ${PROJECT}/${1}:${2}"
}

# 노드(containerd = kubelet 경로)에서 실제로 받아지는지 미리 본다(35 와 같은 방식).
# 실패하면 파드가 ImagePullBackOff 가 되므로 설치 전에 멈춘다.
harbor_cri_pull() {   # $1=이미지 ref
    local creds=()
    require_cmds crictl
    [[ "$HARBOR_PUBLIC" == "true" ]] || creds=(--creds "${PULL_USER}:${PULL_PASS}")
    crictl --runtime-endpoint unix:///run/containerd/containerd.sock pull "${creds[@]}" "$1" >/dev/null 2>&1 \
        || die "containerd 가 ${1} 를 받지 못했다. 05-certs deploy-certs.sh --local 로 containerd 신뢰를 설정했는지, hydrate 가 끝났는지 확인할 것."
    ok "containerd 에서 Harbor pull 확인: ${1}"
}

# Harbor OCI 에서 차트를 받아 sha256 을 핀과 대조한다. 결과 경로는 PULLED_CHART.
# hydrate 는 차트 tgz 를 helm push 로 그대로 올리므로 레이어 = 원본 tgz 이어야 한다.
HELM_REGCFG=""
harbor_chart_pull() {   # $1=OCI 경로(vendor/base) $2=버전 $3=sha256 핀
    local ref="$1" ver="$2" pin="$3" f got
    local args=(--version "$ver" --ca-file "$HARBOR_CA")
    if [[ "$HARBOR_PUBLIC" != "true" ]]; then
        if [[ -z "$HELM_REGCFG" ]]; then
            mktemp_tracked; HELM_REGCFG="$TMP_LAST"
            printf '%s' "$PULL_PASS" | helm registry login "$HARBOR_HOST" --ca-file "$HARBOR_CA" \
                --registry-config "$HELM_REGCFG" --username "$PULL_USER" --password-stdin >/dev/null 2>&1 \
                || die "helm registry login ${HARBOR_HOST} 실패 (사용자 ${PULL_USER})"
        fi
        args+=(--registry-config "$HELM_REGCFG")
    fi
    mktemp_tracked -d
    helm pull "oci://${HARBOR_REGISTRY}/${ref}" "${args[@]}" -d "$TMP_LAST" >/dev/null 2>&1 \
        || die "차트를 받지 못했다: oci://${HARBOR_REGISTRY}/${ref} ${ver}. README 5.2 의 hydrate 를 확인할 것."
    f="${TMP_LAST}/${ref##*/}-${ver}.tgz"
    [[ -f "$f" ]] || die "받은 차트 파일이 예상과 다르다: $(ls "$TMP_LAST")"
    got="$(sha256_of "$f")"
    [[ "$got" == "$pin" ]] \
        || die "Harbor 의 차트 ${ref} ${ver} sha256(${got})이 versions.env 핀(${pin})과 다르다. hydrate 한 AS 번들 버전을 확인할 것."
    ok "Harbor 차트 oci://${HARBOR_REGISTRY}/${ref} ${ver} (sha256 = 핀)"
    PULLED_CHART="$f"
}

# private 이면 pull secret 을 만든다(멱등: apply).
harbor_pull_secret() {
    [[ "$HARBOR_PUBLIC" == "true" ]] && return 0
    kubectl -n "$NS" create secret docker-registry "$ISTIO_PULL_SECRET" \
        --docker-server="$HARBOR_HOST" --docker-username="$PULL_USER" --docker-password="$PULL_PASS" \
        --dry-run=client -o yaml | kubectl apply -f - >/dev/null || die "pull secret 생성 실패"
    ok "pull secret ${NS}/${ISTIO_PULL_SECRET}"
}

pull_secret_exists() {
    kubectl -n "$NS" get secret "$ISTIO_PULL_SECRET" >/dev/null 2>&1
}
