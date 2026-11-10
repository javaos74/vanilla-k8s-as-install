#!/usr/bin/env bash
#---------------------------------------------------------------------
# 38-istio : UiPath istio-configure (WASM 라우팅 플러그인 + EnvoyFilter) 설치
#            (control plane 에서 root, install.sh 다음에 실행)
#
#   sudo ./istio-configure.sh                   # Harbor 에서 (= --source harbor, hydrate 또는 feed-istio-to-harbor.sh)
#   sudo ./istio-configure.sh --source local    # 단일 노드 검증: 번들 차트 + 검증용 이미지 묶음
#   sudo ./istio-configure.sh --check-only      # 판정만
#   sudo ./istio-configure.sh --uninstall       # 제거 (hook 리소스 포함)
#   ./istio-configure.sh --dry-run [--source ..]  # root·클러스터 없이 values 와 이미지만 출력
#
# UiPath 문서 Step 2 Option A 와 같다: 릴리스 custom-istio-configure, 네임스페이스 istio-system.
#   https://docs.uipath.com/automation-suite/automation-suite/<major.minor>/installation-guide-eks-aks/installing-and-configuring-the-service-mesh
# values 는 conf/istio-configure-values.yaml.tmpl(결정 A: vanilla / exclusive).
# AS_FQDN 을 바꾸면 다시 실행한다(WasmPlugin pluginConfig.fqdn).
# 이 차트를 여기서 설치했으면 AS input.json 의 exclude_components 에 istio-configure 를 넣는다.
#---------------------------------------------------------------------
# 판정용 함수는 check / retry_until 이 인자로 받아 부르므로 직접 호출이 없다.
# shellcheck disable=SC2329
BUNDLE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${BUNDLE_ROOT}/00-common/common.sh"
source "${BUNDLE_ROOT}/istio-lib.sh"

istio_parse_args "$@"

REL="custom-istio-configure"
IC_TGZ="$(bundle_chart "$UIPATH_ISTIO_CONFIGURE_CHART" "$UIPATH_ISTIO_CONFIGURE_VERSION")"
PLUGIN="${UIPATH_AS_NAMESPACE}-istio-plugin-http"
WASMPLUGIN="${UIPATH_AS_NAMESPACE}-routing-policy"
PLUGIN_URL="http://${PLUGIN}.${NS}.svc/plugin-${UIPATH_ISTIO_CONFIGURE_VERSION}.wasm"
# 레지스트리 호스트를 뗀 경로(hydrate 와 feed-istio-to-harbor.sh 가 Harbor 프로젝트 아래에 그대로 둔다).
WASM_PATH="${UIPATH_WASM_IMAGE#*/}"          # istio-wasm-plugin:<UIPATH_WASM_TAG>
CURL_PATH="${UIPATH_ISTIO_CURL_IMAGE#*/}"    # curlimages/curl:<UIPATH_ISTIO_CURL_TAG>
ENVOYFILTERS=(uipath-asrobots-filter uipath-response-server-passthrough-filter
              uipath-response-filter uipath-hsts-response-header)
# 차트의 post-install/post-upgrade hook 이 만든다. helm uninstall 로는 지워지지 않는다.
HOOK_RESOURCES=(job/update-wasm-plugin-version serviceaccount/wasmplugin-patcher
                role/wasmplugin-patch-role rolebinding/wasmplugin-patch-binding)

# values 를 임시 파일로 만든다. $1=출처 $2=pull secret 이름(없으면 "")
render_values() {
    local reg; reg="$(registry_for "$1")"
    mktemp_tracked; IC_VALUES="$TMP_LAST"
    sed -e "s|__FQDN__|${AS_FQDN}|g" -e "s|__UIPATH_REGISTRY__|${reg}|g" \
        -e "s|__PULL_SECRET__|${2}|g" -e "s|__UIPATH_NAMESPACE__|${UIPATH_AS_NAMESPACE}|g" \
        "${CONF_DIR}/istio-configure-values.yaml.tmpl" > "$IC_VALUES"
}

rendered_images() {   # $1=렌더링 파일
    grep -hoE '^\s*image:\s*"?[^"]+"?$' "$1" | sed -E 's/^\s*image:\s*//; s/^"//; s/"$//' | sort -u
}

#=====================================================================
# --dry-run
#=====================================================================
do_dry_run() {
    local src="${SOURCE:-harbor}" r reg
    require_cmds helm
    step "dry-run (출처: ${src})"
    verify_manifest "$BUNDLE_ROOT"
    [[ -n "${AS_FQDN:-}" ]] || die "site.env 에 AS_FQDN 이 없다"
    [[ "$src" == "local" || -n "$HARBOR_HOST" ]] || die "site.env 에 HARBOR_HOSTNAME 이 없다"
    reg="$(registry_for "$src")"
    render_values "$src" ""
    echo "  values (pull secret 은 ${NS}/${ISTIO_PULL_SECRET} 가 있을 때만 들어간다):"
    grep -vE '^\s*#|^\s*$' "$IC_VALUES" | sed 's/^/    /'
    mktemp_tracked; r="$TMP_LAST"
    helm template "$REL" "$IC_TGZ" -n "$NS" -f "$IC_VALUES" > "$r" || die "istio-configure 렌더링 실패"
    echo "  렌더링 이미지:"
    rendered_images "$r" | sed 's/^/    /'
    echo "  WasmPlugin ${WASMPLUGIN} url (hook Job 이 바꾼 뒤): ${PLUGIN_URL}"

    step "dry-run: 실행할 순서"
    if [[ "$src" == "harbor" ]]; then
        for a in "$WASM_PATH" "$CURL_PATH"; do
            echo "  $(harbor_artifact_url "${a%:*}" "${a##*:}")"
            echo "  crictl pull ${reg}/${a}"
        done
        echo "  helm pull oci://${reg}/${UIPATH_ISTIO_CONFIGURE_CHART} --version ${UIPATH_ISTIO_CONFIGURE_VERSION} --ca-file ${HARBOR_CA:-<없음: OS 신뢰 저장소>}  (sha256 대조, 다르면 번들 차트와 내용 대조)"
    else
        echo "  ctr -n k8s.io images import <tar>  ← ${UIPATH_WASM_IMAGE}, ${UIPATH_ISTIO_CURL_IMAGE} (${LOCAL_IMAGES_DIR})"
    fi
    echo "  helm upgrade --install --wait --timeout 10m ${REL} ${IC_TGZ##*/} -n ${NS} -f <values>"
    ok "dry-run 끝 (클러스터는 바뀌지 않았다)"
}

#=====================================================================
# 판정
#=====================================================================
plugin_image_is() {
    [[ "$(kubectl -n "$NS" get deploy "$PLUGIN" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)" == "$1" ]]
}
job_succeeded() {
    [[ "$(kubectl -n "$NS" get job update-wasm-plugin-version -o jsonpath='{.status.succeeded}' 2>/dev/null)" == "1" ]]
}
wasmplugin_field_is() {   # $1=jsonpath $2=기대값
    [[ "$(kubectl -n "$NS" get wasmplugin "$WASMPLUGIN" -o jsonpath="$1" 2>/dev/null)" == "$2" ]]
}
envoyfilters_present() {
    kubectl -n "$NS" get envoyfilter "${ENVOYFILTERS[@]}" >/dev/null 2>&1
}
# plugin-http 파드(busybox httpd)에서 Service 이름으로 plugin 파일을 받아 본다.
# gateway 의 proxyv2(Echo mini) 이미지에는 curl/wget/sh 가 없어 그쪽에서는 받을 수 없다.
plugin_url_served() {
    kubectl -n "$NS" exec "deploy/${PLUGIN}" -- busybox wget -q -O /dev/null "$PLUGIN_URL" >/dev/null 2>&1
}
# gateway Envoy 에 Wasm 필터가 실제로 들어갔는가.
#
# WasmPlugin 은 ECDS(필터 설정 탐색)로 내려온다. 그래서 ECDS 덤프만 보고, 그 안에서
# 플러그인 이름(<네임스페이스>.<WasmPlugin>)이 든 항목의 타입이 Wasm 인지 본다.
#   - 전체 config_dump 를 grep 하면 안 된다. 부트스트랩의 지원 확장 목록에 Wasm 타입 URL 이
#     늘 들어 있어 타입 조건은 항상 참이 된다(실측: charles-weed 2026-11-08).
#   - 원격 모듈을 받지 못하면 istio-agent 가 같은 이름의 다른 필터(RBAC 등)로 바꾼다.
#     그래서 이름과 Wasm 타입이 같은 항목에 있어야 한다.
wasm_loaded_in_gateway() {
    local dump
    dump="$(kubectl -n "$NS" exec "deploy/${GW}" -c istio-proxy -- \
        pilot-agent request GET 'config_dump?resource=ecds_filters' 2>/dev/null)" || return 1
    awk -v name="${NS}.${WASMPLUGIN}" '
        /"ecds_filter"/ { if (n && w) ok = 1; n = 0; w = 0 }
        index($0, name) { n = 1 }
        /"type\.googleapis\.com\/envoy\.extensions\.filters\.http\.wasm\.v3\.Wasm"/ { w = 1 }
        END { if (n && w) ok = 1; exit !ok }' <<<"$dump"
}
plugin_imageid_from_harbor() {
    local ids
    ids="$(kubectl -n "$NS" get pods -l "app.kubernetes.io/name=${PLUGIN}" \
        -o jsonpath='{range .items[*].status.containerStatuses[*]}{.imageID}{"\n"}{end}' 2>/dev/null)"
    [[ -n "$ids" ]] && ! grep -v "^${HARBOR_HOST}/" <<<"$ids" >/dev/null
}
gateway_env_is() {   # $1=이름 $2=값
    [[ "$(kubectl -n "$NS" get deploy "$GW" \
        -o jsonpath="{.spec.template.spec.containers[0].env[?(@.name=='$1')].value}" 2>/dev/null)" == "$2" ]]
}

run_checks() {
    local src="$1" reg
    reg="$(registry_for "$src")"
    step "istio-configure 판정 (출처 ${src}: ${reg})"
    check "helm 릴리스 ${REL} deployed" release_deployed "$REL"
    check "Deployment ${PLUGIN} Available" retry_until 180 deploy_available "$PLUGIN"
    check "plugin 이미지 ${reg}/${WASM_PATH}" plugin_image_is "${reg}/${WASM_PATH}"
    check "Job update-wasm-plugin-version succeeded=1" retry_until 120 job_succeeded
    check "WasmPlugin ${WASMPLUGIN} url = ${PLUGIN_URL}" retry_until 60 wasmplugin_field_is '{.spec.url}' "$PLUGIN_URL"
    check "pluginConfig cluster_type=exclusive" wasmplugin_field_is '{.spec.pluginConfig.cluster_type}' exclusive
    check "pluginConfig k8s_distribution=vanilla" wasmplugin_field_is '{.spec.pluginConfig.k8s_distribution}' vanilla
    check "pluginConfig fqdn=${AS_FQDN:-?}" wasmplugin_field_is '{.spec.pluginConfig.fqdn}' "${AS_FQDN:-}"
    check "EnvoyFilter 4개(${ENVOYFILTERS[*]})" envoyfilters_present
    check "plugin URL 응답(${PLUGIN} 파드에서 ${PLUGIN_URL})" retry_until 60 plugin_url_served
    # Wasm 필터는 HTTP 리스너에 붙는다. Gateway 리소스가 없으면(AS 설치 전) gateway 에는
    # 정적 리스너 15090/15021 만 있어 필터가 어디에도 들어가지 않는다(실측: charles-weed
    # 2026-11-08). 그래서 install.sh 와 같은 smoke Gateway 를 판정 동안만 만든다.
    if smoke_apply; then
        check "${GW} Envoy 에 Wasm 필터 ${WASMPLUGIN} 적재(config_dump ECDS, smoke Gateway)" \
            retry_until 120 wasm_loaded_in_gateway
        smoke_delete
    else
        check "smoke Gateway/VirtualService 적용" false
    fi
    check "${GW} Available" retry_until 120 deploy_available "$GW"
    if [[ "$src" == "local" ]]; then
        check "wasm·curl 이미지 containerd(k8s.io)에 적재됨" images_in_containerd "$UIPATH_WASM_IMAGE" "$UIPATH_ISTIO_CURL_IMAGE"
    else
        check "plugin 파드가 Harbor 에서 받은 이미지(imageID ${HARBOR_HOST}/)" plugin_imageid_from_harbor
        check "gateway env WASM_INSECURE_REGISTRIES=${HARBOR_HOST}" gateway_env_is WASM_INSECURE_REGISTRIES "$HARBOR_HOST"
    fi
    check_summary
}

do_uninstall() {
    step "istio-configure 제거"
    export KUBECONFIG="$KC"
    helm -n "$NS" uninstall "$REL" 2>/dev/null || warn "${REL} 릴리스가 없다"
    kubectl -n "$NS" delete "${HOOK_RESOURCES[@]}" --ignore-not-found >/dev/null 2>&1 || true
    ok "제거 완료 (hook 리소스 ${HOOK_RESOURCES[*]} 포함)"
    exit 0
}

case "$MODE" in
    dry-run)
        do_dry_run; exit 0 ;;
    uninstall)
        require_root; require_cmds kubectl helm; do_uninstall ;;
    check)
        require_root; require_cmds kubectl helm
        cluster_ready
        if [[ -z "$SOURCE" ]]; then
            img="$(kubectl -n "$NS" get deploy "$PLUGIN" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
            SOURCE="$(source_of_registry "${img%/istio-wasm-plugin:*}")"
            [[ -n "$SOURCE" ]] || { warn "배포된 plugin 이미지(${img:-없음})로 출처를 판별하지 못했다. harbor 로 본다."; SOURCE="harbor"; }
            log "출처 판별: ${SOURCE} (plugin 이미지 ${img:-없음})"
        fi
        run_checks "$SOURCE"; exit $? ;;
esac

#=====================================================================
# 0. 사전 확인
#=====================================================================
SOURCE="${SOURCE:-harbor}"
require_root
step "사전 확인 (출처: ${SOURCE})"
verify_manifest "$BUNDLE_ROOT"
require_cmds kubectl helm
cluster_ready
[[ -n "${AS_FQDN:-}" ]] || die "site.env 에 AS_FQDN 이 없다(pluginConfig.fqdn)."
if ! release_deployed istiod || ! deploy_available "$GW"; then
    die "istiod 또는 ${GW} 가 없다. 먼저 sudo ./install.sh 를 실행할 것."
fi
ok "istiod / ${GW} 확인"

if [[ "$SOURCE" == "harbor" ]]; then
    harbor_preflight
    harbor_require_artifact "${WASM_PATH%:*}" "${WASM_PATH##*:}"
    harbor_require_artifact "${CURL_PATH%:*}" "${CURL_PATH##*:}"
    harbor_cri_pull "${HARBOR_REGISTRY}/${WASM_PATH}"
    harbor_cri_pull "${HARBOR_REGISTRY}/${CURL_PATH}"
    harbor_chart_pull "$UIPATH_ISTIO_CONFIGURE_CHART" "$UIPATH_ISTIO_CONFIGURE_VERSION" "$UIPATH_ISTIO_CONFIGURE_CHART_SHA256"
    IC_TGZ="$PULLED_CHART"
else
    warn "--source local 은 단일 노드 검증 전용이다."
    step "이미지 적재 (검증용 묶음 -> k8s.io)"
    local_images_import images-uipath.list
    [[ -f "$IC_TGZ" ]] || die "번들에 차트가 없다: ${IC_TGZ}"
fi

# pull secret 은 install.sh 가 만든 것이 있을 때만 쓴다(harbor + private 프로젝트).
PS=""
if pull_secret_exists; then PS="$ISTIO_PULL_SECRET"; fi
[[ "$SOURCE" != "harbor" || "$HARBOR_PUBLIC" == "true" || -n "$PS" ]] \
    || die "프로젝트가 private 인데 ${NS}/${ISTIO_PULL_SECRET} 가 없다. 먼저 sudo ./install.sh 를 실행할 것."
render_values "$SOURCE" "$PS"
step "values"
grep -vE '^\s*#|^\s*$' "$IC_VALUES" | sed 's/^/    /'

#=====================================================================
# 1. helm
#=====================================================================
# UiPath 문서처럼 --wait 를 쓴다. post-install hook Job(update-wasm-plugin-version)이
# WasmPlugin url 을 버전 파일로 바꾸므로 그 Job 이 끝나야 설치가 끝난 것이다.
step "helm: ${REL}"
helm upgrade --install --wait --timeout 10m "$REL" "$IC_TGZ" -n "$NS" -f "$IC_VALUES" >/dev/null \
    || die "${REL} 설치 실패: kubectl -n ${NS} get pods,jobs ; kubectl -n ${NS} logs job/update-wasm-plugin-version"
ok "${REL}"

rc=0
run_checks "$SOURCE" || rc=$?

step "다음 단계"
echo "  게이트웨이·smoke 가 그대로인지 본다:  sudo ./install.sh --check-only"
echo "  AS input.json: exclude_components 에 istio, istio-configure (상위 README 5.1절)"
exit $rc
