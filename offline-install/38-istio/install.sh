#!/usr/bin/env bash
#---------------------------------------------------------------------
# 38-istio : Istio(base / istiod / ingressgateway) 설치 (control plane 에서 root)
#
#   sudo ./install.sh                     # hydrate 된 Harbor 에서 설치 (= --source harbor)
#   sudo ./install.sh --source local      # 단일 노드 검증: 번들 차트 + 검증용 이미지 묶음
#   sudo ./install.sh --check-only        # 판정만 (출처는 배포된 istiod 이미지로 판별)
#   sudo ./install.sh --uninstall         # 제거 (istio-configure.sh --uninstall 이 먼저)
#   ./install.sh --dry-run [--source ..]  # root·클러스터 없이 렌더링한 이미지와 명령만 출력
#
# 전제:
#   10-k8s + 60-cilium 설치 완료(노드 Ready)
#   TLS 원본 ${ISTIO_TLS_CERT_DIR:-/opt/pki/as}/{fullchain.crt,tls.key,ca.crt}
#     (05-certs deploy-certs.sh --local 이 배치한다. 다른 곳이면 ISTIO_TLS_CERT_DIR)
#   --source harbor: README 5.2 의 hydrate 로 Harbor 에 Istio 이미지·차트가 올라가 있고,
#     이 노드가 Harbor 이름을 해석하고 CA 를 신뢰한다(05-certs deploy-certs.sh --local).
#
# 설치하는 것(네임스페이스 istio-system):
#   helm 릴리스 istio-base (vendor/base) / istiod (vendor/istiod) / istio-ingressgateway (vendor/gateway)
#   Secret istio-ingressgateway-certs (tls.crt=fullchain, tls.key, ca.crt)
#   Secret uipathpullsecret (harbor 이고 프로젝트가 private 일 때만)
# ingressgateway 는 NodePort(versions.env ISTIO_NODEPORT_*)로 고정하고, 40-haproxy 가
# 호스트 80/443/15021 을 이 NodePort 로 넘긴다.
#---------------------------------------------------------------------
# 판정용 함수는 check / retry_until 이 인자로 받아 부르므로 직접 호출이 없다.
# shellcheck disable=SC2329
BUNDLE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${BUNDLE_ROOT}/00-common/common.sh"
source "${BUNDLE_ROOT}/istio-lib.sh"

istio_parse_args "$@"

TLS_DIR="${ISTIO_TLS_CERT_DIR:-/opt/pki/as}"
BASE_TGZ="$(bundle_chart "$ISTIO_BASE_CHART" "$ISTIO_CHART_VERSION")"
ISTIOD_TGZ="$(bundle_chart "$ISTIO_ISTIOD_CHART" "$ISTIO_CHART_VERSION")"
GATEWAY_TGZ="$(bundle_chart "$ISTIO_GATEWAY_CHART" "$ISTIO_CHART_VERSION")"

# gateway values 는 versions.env 의 NodePort 로 실행 때 만든다(site.env 를 따른다).
render_gateway_values() {
    mktemp_tracked; GW_VALUES="$TMP_LAST"
    sed -e "s/__NP_HTTP__/${ISTIO_NODEPORT_HTTP}/" -e "s/__NP_HTTPS__/${ISTIO_NODEPORT_HTTPS}/" \
        -e "s/__NP_STATUS__/${ISTIO_NODEPORT_STATUS}/" "${CONF_DIR}/gateway-values.yaml.tmpl" > "$GW_VALUES"
}

# helm --set 인자. $1=출처 $2=pull secret 을 쓰는가(1|0)
build_set_args() {
    local reg; reg="$(registry_for "$1")"
    HUB="${reg}/istio"
    ISTIOD_SET=(--set "global.hub=${HUB}" --set "global.tag=${ISTIO_TAG}" --set global.imagePullPolicy=IfNotPresent)
    GW_SET=()
    if [[ "$1" == "harbor" ]]; then
        # UiPath 문서는 kubectl patch 로 넣지만 helm 값으로 둔다. upgrade 때 사라지지 않고,
        # 문서의 JSON patch(add .../env)는 env 목록 전체를 바꾸기 때문이다.
        GW_SET+=(--set "env.WASM_INSECURE_REGISTRIES=${HARBOR_HOST}")
    fi
    if [[ "$2" == "1" ]]; then
        ISTIOD_SET+=(--set "global.imagePullSecrets[0]=${ISTIO_PULL_SECRET}")
        GW_SET+=(--set "imagePullSecrets[0].name=${ISTIO_PULL_SECRET}")
    fi
}

#=====================================================================
# --dry-run: root·클러스터·레지스트리 없이 렌더링 결과만 보여 준다
#=====================================================================
deployment_images() {   # $1=렌더링 파일. 최상위 kind: Deployment 문서의 image 만.
    awk '/^---/{k=""} /^kind: /{k=$2} k=="Deployment" && /^[[:space:]]*image:[[:space:]]*/{
        sub(/^[[:space:]]*image:[[:space:]]*/, ""); gsub(/"/, ""); print}' "$1" | sort -u
}

do_dry_run() {
    local src="${SOURCE:-harbor}" r
    require_cmds helm
    step "dry-run (출처: ${src})"
    verify_manifest "$BUNDLE_ROOT"
    if [[ "$src" == "harbor" ]]; then
        [[ -n "$HARBOR_HOST" ]] || die "site.env 에 HARBOR_HOSTNAME 이 없다"
        build_set_args harbor 0
    else
        build_set_args local 0
    fi
    render_gateway_values
    mktemp_tracked; r="$TMP_LAST"

    helm template istiod "$ISTIOD_TGZ" -n "$NS" -f "${CONF_DIR}/istiod-values.yaml" "${ISTIOD_SET[@]}" > "$r" \
        || die "istiod 렌더링 실패"
    echo "  istiod Deployment 이미지 : $(deployment_images "$r" | tr '\n' ' ')"
    if ! grep -qF "\"hub\": \"${HUB}\"" "$r" || ! grep -qF "\"tag\": \"${ISTIO_TAG}\"" "$r"; then
        die "주입 values 의 hub/tag 가 예상과 다르다"
    fi
    echo "  주입 프록시 이미지        : ${HUB}/proxyv2:${ISTIO_TAG}  (사이드카 + ingressgateway)"
    helm template "$GW" "$GATEWAY_TGZ" -n "$NS" -f "$GW_VALUES" ${GW_SET[@]+"${GW_SET[@]}"} > "$r" \
        || die "gateway 렌더링 실패"
    echo "  ingressgateway Service    : $(awk '/^---/{k=""} /^kind: /{k=$2} k=="Service" && /type:|nodePort:/{gsub(/^ +/,""); printf "%s  ", $0}' "$r")"
    if [[ "$src" == "harbor" ]]; then
        echo "  ingressgateway env        : WASM_INSECURE_REGISTRIES=$(grep -A1 'name: WASM_INSECURE_REGISTRIES' "$r" | sed -n 's/.*value: *"*\([^"]*\)"*/\1/p')"
    fi

    step "dry-run: 실행할 순서"
    if [[ "$src" == "harbor" ]]; then
        echo "  Harbor 확인(사전): https://${HARBOR_HOST}/api/v2.0/ping, projects/${PROJECT} (public 여부)"
        for a in "istio/pilot:${ISTIO_TAG}" "istio/proxyv2:${ISTIO_TAG}"; do
            echo "    $(harbor_artifact_url "${a%:*}" "${a##*:}")"
            echo "    crictl pull ${HARBOR_REGISTRY}/${a}"
        done
        for c in "$ISTIO_BASE_CHART" "$ISTIO_ISTIOD_CHART" "$ISTIO_GATEWAY_CHART"; do
            echo "    helm pull oci://${HARBOR_REGISTRY}/${c} --version ${ISTIO_CHART_VERSION} --ca-file <CA>  (sha256 대조)"
        done
        echo "  private 프로젝트이면 Secret ${NS}/${ISTIO_PULL_SECRET} 를 만들고"
        echo "    --set global.imagePullSecrets[0]=${ISTIO_PULL_SECRET} / --set imagePullSecrets[0].name=${ISTIO_PULL_SECRET} 를 더한다."
    else
        local have="없음"; [[ ! -d "$LOCAL_IMAGES_DIR" ]] || have="있음"
    echo "  검증용 이미지 묶음: ${LOCAL_IMAGES_DIR} (${have})"
        echo "    ctr -n k8s.io images import <tar>  ← ${ISTIO_PILOT_IMAGE}, ${ISTIO_PROXYV2_IMAGE}"
    fi
    local chart_src="<Harbor 에서 받은 tgz>"; [[ "$src" == "local" ]] && chart_src="charts/"
    echo "  kubectl create namespace ${NS}; Secret ${NS}/${ISTIO_TLS_SECRET} ← ${TLS_DIR}/{fullchain.crt,tls.key,ca.crt}"
    echo "  helm upgrade --install istio-base ${chart_src}${BASE_TGZ##*/} -n ${NS}"
    echo "  helm upgrade --install istiod ${chart_src}${ISTIOD_TGZ##*/} -n ${NS} -f conf/istiod-values.yaml ${ISTIOD_SET[*]}"
    echo "  helm upgrade --install ${GW} ${chart_src}${GATEWAY_TGZ##*/} -n ${NS} -f conf/gateway-values.yaml.tmpl(NodePort) ${GW_SET[*]}"
    ok "dry-run 끝 (클러스터는 바뀌지 않았다)"
}

#=====================================================================
# 판정
#=====================================================================
# 아래 함수들은 check / retry_until 이 현재 셸에서 그대로 부른다.
bin_version() {   # $1=deploy $2=container $3=binary -> x.y.z
    kubectl -n "$NS" exec "deploy/$1" -c "$2" -- "$3" version -s 2>/dev/null \
        | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | tail -1
}
version_is() { [[ "$(bin_version "$1" "$2" "$3")" == "$ISTIO_VERSION" ]]; }

deploy_image_is() {   # $1=deploy $2=기대 이미지
    [[ "$(kubectl -n "$NS" get deploy "$1" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)" == "$2" ]]
}

# gateway 파드의 istio-proxy 이미지. Deployment 에는 image: auto 라 파드를 본다.
gateway_proxy_image_is() {
    local got
    got="$(kubectl -n "$NS" get pods -l istio=ingressgateway \
        -o jsonpath='{range .items[*]}{.spec.containers[?(@.name=="istio-proxy")].image}{"\n"}{end}' 2>/dev/null)"
    [[ -n "$got" ]] && ! grep -vxF "$1" <<<"$got" >/dev/null
}

deploy_label_is() {   # $1=deploy $2=라벨 $3=기대값
    [[ "$(kubectl -n "$NS" get deploy "$1" -o jsonpath="{.metadata.labels.${2}}" 2>/dev/null)" == "$3" ]]
}

svc_field_is() {   # $1=jsonpath $2=기대값
    [[ "$(kubectl -n "$NS" get svc "$GW" -o jsonpath="$1" 2>/dev/null)" == "$2" ]]
}

nodeports_ok() {
    svc_field_is "{.spec.ports[?(@.name=='http2')].nodePort}"       "$ISTIO_NODEPORT_HTTP" \
        && svc_field_is "{.spec.ports[?(@.name=='https')].nodePort}"  "$ISTIO_NODEPORT_HTTPS" \
        && svc_field_is "{.spec.ports[?(@.name=='status-port')].nodePort}" "$ISTIO_NODEPORT_STATUS"
}

endpoints_ready() {
    [[ -n "$(kubectl -n "$NS" get endpointslices -l "kubernetes.io/service-name=${GW}" \
        -o jsonpath='{.items[*].endpoints[?(@.conditions.ready==true)].addresses[0]}' 2>/dev/null)" ]]
}

crds_present() {
    kubectl get crd gateways.networking.istio.io virtualservices.networking.istio.io \
        wasmplugins.extensions.istio.io >/dev/null 2>&1
}

# istiod·gateway 컨테이너가 Harbor 에서 받은 이미지로 돈다(imageID 접두사).
imageids_from_harbor() {
    local ids
    ids="$(kubectl -n "$NS" get pods -l 'app in (istiod,istio-ingressgateway)' \
        -o jsonpath='{range .items[*].status.containerStatuses[*]}{.imageID}{"\n"}{end}' 2>/dev/null)"
    [[ -n "$ids" ]] && ! grep -v "^${HARBOR_HOST}/" <<<"$ids" >/dev/null
}

gateway_env_is() {   # $1=이름 $2=값
    [[ "$(kubectl -n "$NS" get deploy "$GW" \
        -o jsonpath="{.spec.template.spec.containers[0].env[?(@.name=='$1')].value}" 2>/dev/null)" == "$2" ]]
}

# TLS secret 을 임시 디렉터리로 꺼낸다. 판정은 파일로 한다.
extract_tls_secret() {
    local k
    mktemp_tracked -d; TLS_OUT="$TMP_LAST"
    for k in tls.crt tls.key ca.crt; do
        kubectl -n "$NS" get secret "$ISTIO_TLS_SECRET" -o jsonpath="{.data.${k//./\\.}}" 2>/dev/null \
            | base64 -d > "${TLS_OUT}/${k}" 2>/dev/null || true
    done
}
tls_keys_present() { test -s "$1/tls.crt" && test -s "$1/tls.key" && test -s "$1/ca.crt"; }
tls_san_ok() {   # $1=인증서. AS_FQDN 과 *.AS_FQDN 이 SAN 에 있다.
    local san; san=",$(cert_san "$1" | tr -d ' '),"
    [[ "$san" == *",DNS:${AS_FQDN},"* && "$san" == *",DNS:*.${AS_FQDN},"* ]]
}
tls_pair_ok() {  # $1=인증서 $2=키
    [[ -n "$(openssl x509 -in "$1" -noout -pubkey 2>/dev/null)" \
        && "$(openssl x509 -in "$1" -noout -pubkey 2>/dev/null)" == "$(openssl pkey -in "$2" -pubout 2>/dev/null)" ]]
}
tls_ca_ok() { openssl verify -CAfile "$2" "$1" >/dev/null 2>&1; }   # $1=인증서 $2=CA

body_is_smoke() { [[ "$(curl -sf --max-time 5 "$@" 2>/dev/null)" == "istio-smoke-ok" ]]; }

l4_running() {
    command -v docker >/dev/null 2>&1 \
        && [[ "$(docker inspect -f '{{.State.Running}}' l4 2>/dev/null)" == "true" ]]
}

run_checks() {
    local hub_src="$1" node
    local reg; reg="$(registry_for "$hub_src")"
    HUB="${reg}/istio"
    node="$(node_ip)"
    step "Istio 판정 (출처 ${hub_src}: ${HUB}, 노드 ${node:-?})"

    for r in istio-base istiod "$GW"; do
        check "helm 릴리스 ${r} deployed" release_deployed "$r"
    done
    check "Istio CRD(gateways/virtualservices/wasmplugins)" crds_present
    check "istiod Available" retry_until 180 deploy_available istiod
    check "istiod 이미지 ${HUB}/pilot:${ISTIO_TAG}" deploy_image_is istiod "${HUB}/pilot:${ISTIO_TAG}"
    check "pilot-discovery version = ${ISTIO_VERSION}" version_is istiod discovery pilot-discovery
    check "${GW} Available" retry_until 180 deploy_available "$GW"
    check "${GW} istio-proxy 이미지 ${HUB}/proxyv2:${ISTIO_TAG}" retry_until 60 gateway_proxy_image_is "${HUB}/proxyv2:${ISTIO_TAG}"
    check "pilot-agent version = ${ISTIO_VERSION}" version_is "$GW" istio-proxy pilot-agent
    check "Service ${GW} type NodePort" svc_field_is '{.spec.type}' NodePort
    check "Service selector istio=ingressgateway" svc_field_is '{.spec.selector.istio}' ingressgateway
    # UiPath 문서가 input.json gateway_selector 를 확인할 때 쓰는 명령과 같은 값이다.
    check "Deployment ${GW} 라벨 istio=ingressgateway" deploy_label_is "$GW" istio ingressgateway
    check "NodePort http2=${ISTIO_NODEPORT_HTTP} https=${ISTIO_NODEPORT_HTTPS} status-port=${ISTIO_NODEPORT_STATUS}" nodeports_ok
    check "EndpointSlice 에 ready 주소" retry_until 60 endpoints_ready

    extract_tls_secret
    check "TLS secret ${ISTIO_TLS_SECRET} 키 3개(tls.crt/tls.key/ca.crt)" tls_keys_present "$TLS_OUT"
    check "TLS SAN 에 ${AS_FQDN:-?} 와 *.${AS_FQDN:-?}" tls_san_ok "${TLS_OUT}/tls.crt"
    check "TLS 인증서와 키가 짝" tls_pair_ok "${TLS_OUT}/tls.crt" "${TLS_OUT}/tls.key"
    check "TLS 인증서가 ca.crt 로 검증됨" tls_ca_ok "${TLS_OUT}/tls.crt" "${TLS_OUT}/ca.crt"

    if [[ "$hub_src" == "local" ]]; then
        check "이미지 containerd(k8s.io)에 적재됨" images_in_containerd "$ISTIO_PILOT_IMAGE" "$ISTIO_PROXYV2_IMAGE"
    else
        check "istiod·gateway 가 Harbor 에서 받은 이미지(imageID ${HARBOR_HOST}/)" imageids_from_harbor
        check "gateway env WASM_INSECURE_REGISTRIES=${HARBOR_HOST}" gateway_env_is WASM_INSECURE_REGISTRIES "$HARBOR_HOST"
    fi

    check "NodePort status http://${node}:${ISTIO_NODEPORT_STATUS}/healthz/ready" retry_until 60 \
        curl -sf --max-time 5 -o /dev/null "http://${node}:${ISTIO_NODEPORT_STATUS}/healthz/ready"

    # smoke: 백엔드 없이 200 을 돌려주는 Gateway/VirtualService 를 잠시 만든다.
    # Host 헤더에 포트를 붙이지 않는다(VirtualService hosts 와 맞춘다).
    if smoke_apply; then
        check "smoke HTTP  NodePort ${ISTIO_NODEPORT_HTTP} -> istio-smoke-ok" retry_until 60 \
            body_is_smoke -H "Host: ${SMOKE_HOST}" "http://${node}:${ISTIO_NODEPORT_HTTP}/"
        check "smoke HTTPS NodePort ${ISTIO_NODEPORT_HTTPS} (사내 CA 검증) -> istio-smoke-ok" retry_until 60 \
            body_is_smoke --cacert "${TLS_OUT}/ca.crt" --resolve "${SMOKE_HOST}:${ISTIO_NODEPORT_HTTPS}:${node}" \
            -H "Host: ${SMOKE_HOST}" "https://${SMOKE_HOST}:${ISTIO_NODEPORT_HTTPS}/"
        if l4_running; then
            check "HAProxy 경유 HTTP  127.0.0.1:80 -> istio-smoke-ok" retry_until 30 \
                body_is_smoke -H "Host: ${SMOKE_HOST}" "http://127.0.0.1:80/"
            check "HAProxy 경유 HTTPS 127.0.0.1:443 (사내 CA 검증) -> istio-smoke-ok" retry_until 30 \
                body_is_smoke --cacert "${TLS_OUT}/ca.crt" --resolve "${SMOKE_HOST}:443:127.0.0.1" \
                "https://${SMOKE_HOST}/"
            check "HAProxy 경유 127.0.0.1:15021/healthz/ready" retry_until 30 \
                curl -sf --max-time 5 -o /dev/null "http://127.0.0.1:15021/healthz/ready"
        else
            log "40-haproxy 컨테이너 l4 가 없다. HAProxy 경유 판정은 건너뛴다(40-haproxy 설치 뒤 --check-only 로 다시 본다)."
        fi
        smoke_delete
    else
        check "smoke Gateway/VirtualService 적용" false
    fi

    check_summary
}

#=====================================================================
# 제거
#=====================================================================
do_uninstall() {
    step "Istio 제거"
    export KUBECONFIG="$KC"
    if helm -n "$NS" status custom-istio-configure >/dev/null 2>&1; then
        die "custom-istio-configure 릴리스가 있다. 먼저 sudo ./istio-configure.sh --uninstall 을 실행할 것."
    fi
    # 이전 판정이 남긴 smoke 가 있을 수 있으니 무조건 지운다. 값은 istio-lib.sh 의 smoke_delete 가 읽는다.
    # shellcheck disable=SC2034
    SMOKE_APPLIED=1; smoke_delete
    helm -n "$NS" uninstall "$GW"   2>/dev/null || warn "${GW} 릴리스가 없다"
    helm -n "$NS" uninstall istiod  2>/dev/null || warn "istiod 릴리스가 없다"
    warn "istio-base 를 지우면 Istio CRD 가 함께 지워진다(클러스터의 Gateway/VirtualService 등도 사라진다)."
    helm -n "$NS" uninstall istio-base 2>/dev/null || warn "istio-base 릴리스가 없다"
    kubectl -n "$NS" delete secret "$ISTIO_TLS_SECRET" "$ISTIO_PULL_SECRET" --ignore-not-found >/dev/null 2>&1 || true
    ok "제거 완료. 네임스페이스 ${NS} 는 남겼다(kubectl delete ns ${NS} 로 지울 수 있다)."
    exit 0
}

case "$MODE" in
    dry-run)
        do_dry_run; exit 0 ;;
    uninstall)
        require_root; require_cmds kubectl helm; do_uninstall ;;
    check)
        require_root; require_cmds kubectl helm curl openssl
        cluster_ready
        if [[ -z "$SOURCE" ]]; then
            img="$(kubectl -n "$NS" get deploy istiod -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
            SOURCE="$(source_of_registry "${img%/istio/pilot:*}")"
            [[ -n "$SOURCE" ]] || { warn "배포된 istiod 이미지(${img:-없음})로 출처를 판별하지 못했다. harbor 로 본다."; SOURCE="harbor"; }
            log "출처 판별: ${SOURCE} (istiod 이미지 ${img:-없음})"
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
if is_online; then
    warn "인터넷 연결 상태다. 오프라인 검증이라면 90-verify/airgap-on.sh 를 먼저 실행할 것."
else
    ok "인터넷 차단 상태 (에어갭 검증 조건 충족)"
fi
require_cmds kubectl helm curl openssl
cluster_ready

[[ -n "${AS_FQDN:-}" ]] || die "site.env 에 AS_FQDN 이 없다(TLS SAN·smoke 판정에 쓴다)."
for f in fullchain.crt tls.key ca.crt; do
    [[ -s "${TLS_DIR}/${f}" ]] || die "TLS 원본이 없다: ${TLS_DIR}/${f} (05-certs deploy-certs.sh --local, 또는 ISTIO_TLS_CERT_DIR)"
done
tls_san_ok  "${TLS_DIR}/fullchain.crt" || die "인증서 SAN 에 ${AS_FQDN} 과 *.${AS_FQDN} 이 없다: ${TLS_DIR}/fullchain.crt"
tls_pair_ok "${TLS_DIR}/fullchain.crt" "${TLS_DIR}/tls.key" || die "인증서와 키가 짝이 아니다: ${TLS_DIR}"
tls_ca_ok   "${TLS_DIR}/fullchain.crt" "${TLS_DIR}/ca.crt"  || die "인증서가 ca.crt 로 검증되지 않는다: ${TLS_DIR}"
ok "TLS 원본 ${TLS_DIR} (SAN ${AS_FQDN}, *.${AS_FQDN} / 키 짝 / CA 검증)"

# 같은 NodePort 를 다른 Service 가 쓰면 gateway 설치가 실패한다. 미리 알려 준다.
NP_USERS="$(kubectl get svc -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name} {.spec.ports[*].nodePort}{"\n"}{end}' 2>/dev/null \
    | awk -v self="${NS}/${GW}" -v a="$ISTIO_NODEPORT_HTTP" -v b="$ISTIO_NODEPORT_HTTPS" -v c="$ISTIO_NODEPORT_STATUS" \
        '$1 != self { for (i = 2; i <= NF; i++) if ($i == a || $i == b || $i == c) print $1 " " $i }')"
[[ -z "$NP_USERS" ]] || die "NodePort 를 이미 다른 Service 가 쓴다: ${NP_USERS} (site.env 의 ISTIO_NODEPORT_* 로 바꿀 수 있다)"
ok "NodePort ${ISTIO_NODEPORT_HTTP}/${ISTIO_NODEPORT_HTTPS}/${ISTIO_NODEPORT_STATUS} 사용 가능"

USE_PULL_SECRET=0
if [[ "$SOURCE" == "harbor" ]]; then
    harbor_preflight
    [[ "$HARBOR_PUBLIC" == "true" ]] || USE_PULL_SECRET=1
    harbor_require_artifact istio/pilot   "$ISTIO_TAG"
    harbor_require_artifact istio/proxyv2 "$ISTIO_TAG"
    harbor_cri_pull "${HARBOR_REGISTRY}/istio/pilot:${ISTIO_TAG}"
    harbor_cri_pull "${HARBOR_REGISTRY}/istio/proxyv2:${ISTIO_TAG}"
    harbor_chart_pull "$ISTIO_BASE_CHART"    "$ISTIO_CHART_VERSION" "$ISTIO_BASE_CHART_SHA256";    BASE_TGZ="$PULLED_CHART"
    harbor_chart_pull "$ISTIO_ISTIOD_CHART"  "$ISTIO_CHART_VERSION" "$ISTIO_ISTIOD_CHART_SHA256";  ISTIOD_TGZ="$PULLED_CHART"
    harbor_chart_pull "$ISTIO_GATEWAY_CHART" "$ISTIO_CHART_VERSION" "$ISTIO_GATEWAY_CHART_SHA256"; GATEWAY_TGZ="$PULLED_CHART"
else
    warn "--source local 은 단일 노드 검증 전용이다. 다른 노드의 사이드카는 proxyv2 를 받지 못한다."
    step "이미지 적재 (검증용 묶음 -> k8s.io)"
    local_images_import images-istio.list
    for t in "$BASE_TGZ" "$ISTIOD_TGZ" "$GATEWAY_TGZ"; do
        [[ -f "$t" ]] || die "번들에 차트가 없다: ${t}"
    done
    ok "번들 차트 사용 (SHA256SUMS 로 검증됨)"
fi
build_set_args "$SOURCE" "$USE_PULL_SECRET"
render_gateway_values

#=====================================================================
# 1. 네임스페이스와 secret
#=====================================================================
step "네임스페이스 ${NS} 와 secret"
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null \
    || die "네임스페이스 생성 실패"
# UiPath 형식: tls.crt = 서버 인증서 + 체인, tls.key, ca.crt = CA 번들.
#   https://docs.uipath.com/automation-suite/automation-suite/<major.minor>/installation-guide-eks-aks/managing-the-certificates
kubectl -n "$NS" create secret generic "$ISTIO_TLS_SECRET" \
    --from-file=tls.crt="${TLS_DIR}/fullchain.crt" \
    --from-file=tls.key="${TLS_DIR}/tls.key" \
    --from-file=ca.crt="${TLS_DIR}/ca.crt" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null || die "TLS secret 생성 실패"
ok "TLS secret ${NS}/${ISTIO_TLS_SECRET}"
[[ "$SOURCE" != "harbor" ]] || harbor_pull_secret

#=====================================================================
# 2. helm (base -> istiod -> gateway)
#=====================================================================
# --wait 를 쓰지 않는다(60-cilium 과 같은 이유). rollout status 와 판정에서 기다린다.
step "helm: istio-base"
helm upgrade --install istio-base "$BASE_TGZ" -n "$NS" >/dev/null || die "istio-base 설치 실패"
ok "istio-base"

step "helm: istiod"
helm upgrade --install istiod "$ISTIOD_TGZ" -n "$NS" \
    -f "${CONF_DIR}/istiod-values.yaml" "${ISTIOD_SET[@]}" >/dev/null || die "istiod 설치 실패"
kubectl -n "$NS" rollout status deploy/istiod --timeout=300s \
    || die "istiod rollout 실패: kubectl -n ${NS} describe pod -l app=istiod"
ok "istiod"

step "helm: ${GW}"
helm upgrade --install "$GW" "$GATEWAY_TGZ" -n "$NS" \
    -f "$GW_VALUES" ${GW_SET[@]+"${GW_SET[@]}"} >/dev/null || die "${GW} 설치 실패"
kubectl -n "$NS" rollout status "deploy/${GW}" --timeout=300s \
    || die "${GW} rollout 실패: kubectl -n ${NS} describe pod -l istio=ingressgateway"
ok "${GW}"

#=====================================================================
# 3. 판정
#=====================================================================
rc=0
run_checks "$SOURCE" || rc=$?

step "다음 단계"
echo "  1) 40-haproxy 번들 디렉터리에서 sudo ./install.sh 를 (다시) 실행해 NodePort 를 반영한다."
echo "     그 뒤 여기서 HAProxy 경유까지 본다:  sudo ./install.sh --check-only"
echo "  2) UiPath istio-configure(WASM 플러그인):              sudo ./istio-configure.sh$([[ "$SOURCE" == local ]] && echo ' --source local')"
echo "  3) input.json: exclude_components 에 istio, istio-configure / ingress 블록 (README 5.3절)"
exit $rc
