#!/usr/bin/env bash
#---------------------------------------------------------------------
# 38-istio : 오프라인 번들 빌드 (온라인 호스트에서 실행)
#
#   ./build-bundle.sh                       # 운영 번들만
#   ISTIO_LOCAL_IMAGES=1 ./build-bundle.sh  # + 단일 노드 검증용 이미지 묶음
#   (build-in-container.sh 도 ISTIO_LOCAL_IMAGES 를 컨테이너에 넘긴다)
#
# 산출물:
#   bundle/istio-<ISTIO_VERSION>/ + .tar.gz + .sha256          운영 번들
#     차트 4개(versions.env 의 ISTIO_{BASE,ISTIOD,GATEWAY}_CHART, UIPATH_ISTIO_CONFIGURE_CHART),
#     values·템플릿, install.sh, istio-configure.sh. **이미지는 넣지 않는다.**
#   bundle/istio-local-images-<ISTIO_VERSION>/ + .tar.gz + .sha256  (ISTIO_LOCAL_IMAGES=1)
#     pilot / proxyv2 / istio-wasm-plugin / curl 이미지 tar. 단일 노드 검증 전용.
#
# 왜 운영 번들에 이미지가 없는가:
#   이 Istio 는 UiPath AS(versions.env UIPATH_AS_VERSION) 오프라인 번들에 들어 있는 것과
#   같다. AS 버전을 바꾸면 versions.env 의 Istio 값도 함께 바꾼다(그 절의 주석).
#   운영에서는 README 5.2 의 hydrate(hydrate-registry.sh)가 이미지와 차트를 Harbor 에
#   올리고, install.sh 는 그 Harbor 경로에서 받는다. 번들에 다시 넣으면 같은 이미지를
#   두 번 옮기게 된다.
#
# 왜 차트는 넣는가:
#   --source local 설치와 --dry-run 렌더링에 쓴다. 합계 약 146KB 이고, Harbor 에
#   올라가는 차트와 같은 바이트다(sha256 핀). harbor 경로에서는 Harbor 에서 받은
#   차트를 이 핀과 대조한다.
#
# 원본은 registry.uipath.com 이다. 이미지·차트 모두 익명으로 받을 수 있다(2026-11-07 확인).
# OS 의존 없음. 22.04 / 24.04 / 26.04 / el9 / el10 공용.
#---------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../00-common/common.sh"

require_online
require_cmds curl tar

BUNDLE_NAME="istio-${ISTIO_VERSION}"
BUNDLE_DIR="${SCRIPT_DIR}/bundle/${BUNDLE_NAME}"
CHART_DIR="${BUNDLE_DIR}/charts"
CONF_DIR="${BUNDLE_DIR}/conf"

LOCAL_NAME="istio-local-images-${ISTIO_VERSION}"
LOCAL_DIR="${SCRIPT_DIR}/bundle/${LOCAL_NAME}"
WITH_LOCAL="${ISTIO_LOCAL_IMAGES:-0}"

step "Istio ${ISTIO_VERSION} (${ISTIO_TAG}) 번들 빌드 (OS 공용)"
# 매번 다시 만드는 것은 지운다(이전 빌드의 site.env 잔존 방지, 60-cilium 주석 참고).
# charts/ 는 다운로드 캐시라 남긴다(sha256 이 맞을 때만 재사용한다).
rm -rf "${BUNDLE_DIR}/00-common" "${BUNDLE_DIR}/conf" "${BUNDLE_DIR}/90-verify"
rm -f  "${BUNDLE_DIR}"/*.sh "${BUNDLE_DIR}"/*.md \
       "${BUNDLE_DIR}/SHA256SUMS" "${BUNDLE_DIR}/BUNDLE-INFO"
mkdir -p "$CHART_DIR" "$CONF_DIR"

TMP_DIRS=()
cleanup() { ((${#TMP_DIRS[@]} == 0)) || rm -rf "${TMP_DIRS[@]}"; }
trap cleanup EXIT

#=====================================================================
# 1. 빌드 도구
#=====================================================================
step "빌드 도구 확인"
# helm 은 차트 pull 과 렌더링에 필요하다. 빌드 호스트에 없으면 임시로 내려받는다.
HELM_BIN="$(command -v helm || true)"
if [[ -z "$HELM_BIN" ]]; then
    log "helm 임시 설치(빌드용)"
    tmp="$(mktemp -d)"; TMP_DIRS+=("$tmp")
    curl -fsSL "$HELM_URL" | tar -C "$tmp" -xz
    HELM_BIN="${tmp}/linux-${BUNDLE_ARCH}/helm"
    chmod +x "$HELM_BIN"
fi
ok "helm $("$HELM_BIN" version --short)"

if [[ "$WITH_LOCAL" == "1" ]]; then
    if ! command -v skopeo >/dev/null 2>&1; then
        log "skopeo 설치(빌드 도구)"
        pkg_install_build_tool skopeo
    fi
    ok "skopeo $(skopeo --version | awk '{print $3}')"
fi

#=====================================================================
# 2. 차트 — registry.uipath.com 에서 받고 sha256 을 핀과 대조한다
#=====================================================================
step "차트 (oci://${ISTIO_SOURCE_REGISTRY})"
sha256_of() { sha256sum "$1" | cut -d' ' -f1; }

# $1=OCI 경로(vendor/base)  $2=버전  $3=sha256 핀
# helm pull 은 <Chart.yaml name>-<version>.tgz 로 저장한다. 네 차트 모두 name 이
# 경로의 마지막 부분과 같다(base / istiod / gateway / istio-configure).
pull_chart() {
    local ref="$1" ver="$2" pin="$3" out tmp
    out="${CHART_DIR}/${ref##*/}-${ver}.tgz"
    if [[ -s "$out" && "$(sha256_of "$out")" == "$pin" ]]; then
        log "이미 존재(sha256 일치), 건너뜀: $(basename "$out")"
        return 0
    fi
    rm -f "$out"
    tmp="$(mktemp -d)"; TMP_DIRS+=("$tmp")
    "$HELM_BIN" pull "oci://${ISTIO_SOURCE_REGISTRY}/${ref}" --version "$ver" -d "$tmp" >/dev/null \
        || die "차트 받기 실패: oci://${ISTIO_SOURCE_REGISTRY}/${ref} ${ver}"
    [[ -s "${tmp}/$(basename "$out")" ]] || die "예상한 파일이 없다: $(basename "$out") ($(ls "$tmp"))"
    [[ "$(sha256_of "${tmp}/$(basename "$out")")" == "$pin" ]] \
        || die "차트 sha256 이 핀과 다르다: ${ref} ${ver} (받은 값 $(sha256_of "${tmp}/$(basename "$out")"), 핀 ${pin})"
    mv "${tmp}/$(basename "$out")" "$out"
    ok "$(basename "$out") (sha256 = 핀)"
}

pull_chart "$ISTIO_BASE_CHART"    "$ISTIO_CHART_VERSION" "$ISTIO_BASE_CHART_SHA256"
pull_chart "$ISTIO_ISTIOD_CHART"  "$ISTIO_CHART_VERSION" "$ISTIO_ISTIOD_CHART_SHA256"
pull_chart "$ISTIO_GATEWAY_CHART" "$ISTIO_CHART_VERSION" "$ISTIO_GATEWAY_CHART_SHA256"
pull_chart "$UIPATH_ISTIO_CONFIGURE_CHART" "$UIPATH_ISTIO_CONFIGURE_VERSION" "$UIPATH_ISTIO_CONFIGURE_CHART_SHA256"

BASE_TGZ="${CHART_DIR}/${ISTIO_BASE_CHART##*/}-${ISTIO_CHART_VERSION}.tgz"
ISTIOD_TGZ="${CHART_DIR}/${ISTIO_ISTIOD_CHART##*/}-${ISTIO_CHART_VERSION}.tgz"
GATEWAY_TGZ="${CHART_DIR}/${ISTIO_GATEWAY_CHART##*/}-${ISTIO_CHART_VERSION}.tgz"
IC_TGZ="${CHART_DIR}/${UIPATH_ISTIO_CONFIGURE_CHART##*/}-${UIPATH_ISTIO_CONFIGURE_VERSION}.tgz"
# 이전 버전의 차트 캐시가 남아 있으면 번들에 실리지 않게 지운다.
for f in "${CHART_DIR}"/*.tgz; do
    case "$f" in
        "$BASE_TGZ"|"$ISTIOD_TGZ"|"$GATEWAY_TGZ"|"$IC_TGZ") ;;
        *) rm -f "$f"; log "이전 차트 캐시 제거: $(basename "$f")" ;;
    esac
done

#=====================================================================
# 3. values / 템플릿 생성
#=====================================================================
step "conf 생성"

# istiod: UiPath 가 Istio 를 직접 설치할 때 쓰는 값과 같다.
# 원본은 AS 번들의 UiPath 래퍼 helm/istiod:<UIPATH_AS_VERSION> 안 values-air.yaml(비 HA)이다.
# AS 버전을 바꾸면 그 파일과 아래 값을 다시 대조한다(versions.env Istio 절 6).
# 래퍼 차트는 istiod.* 아래에 값을 두고 global 은 하위 차트와 공유하므로
# vendor/istiod 에 그대로 쓰려면 한 단계 평탄화한다. 렌더링 결과가 같음을 확인했다
# (README 2절). hub / tag / imagePullPolicy / imagePullSecrets 는 install.sh 가 --set 으로 준다.
cat > "${CONF_DIR}/istiod-values.yaml" <<EOF
#---------------------------------------------------------------------
# istiod (${ISTIO_ISTIOD_CHART} ${ISTIO_CHART_VERSION}) — UiPath values-air.yaml(helm/istiod:${UIPATH_AS_VERSION}) 평탄화
# hub / tag / imagePullPolicy / imagePullSecrets 는 install.sh 가 --set 으로 준다.
#---------------------------------------------------------------------
global:
  # 노드 압박 때 먼저 축출되지 않게 한다(UiPath 값).
  priorityClassName: system-cluster-critical
  proxy:
    accessLogFile: /dev/stdout
    logLevel: warning
    # 앱 컨테이너가 사이드카보다 먼저 네트워크를 쓰다 실패하는 것을 막는다(UiPath 값).
    holdApplicationUntilProxyStarts: true
    # 사이드카 리소스(UiPath 값). 차트 기본값보다 requests 가 작다.
    resources:
      requests:
        cpu: 50m
        memory: 96Mi
      limits:
        cpu: 500m
        memory: 512Mi
  # 단일 replica 에 PDB 가 있으면 단일 노드 drain 이 막힌다(UiPath 값도 false).
  defaultPodDisruptionBudget:
    enabled: false
pilot:
  env:
    # upstream 1.27+ 기본값은 native sidecar 다. UiPath 는 끈다.
    ENABLE_NATIVE_SIDECARS: "false"
meshConfig:
  accessLogEncoding: JSON
  accessLogFile: /dev/stdout
EOF
ok "conf/istiod-values.yaml"

# gateway: NodePort 고정. 40-haproxy 가 호스트 80/443/15021 을 받아 이 포트로 넘긴다.
# __NP_*__ 는 install.sh 가 versions.env 값(site.env 로 바꿀 수 있음)으로 바꾼다.
# 포트 이름(status-port / http2 / https)은 차트 기본값과 같다. 40-haproxy 의 NodePort
# 자동 탐지가 이 이름으로 찾는다.
# env(WASM_INSECURE_REGISTRIES) / imagePullSecrets 는 install.sh 가 --set 으로 준다.
#
# imagePullPolicy: IfNotPresent 를 명시한다(사용자 결정, charles-weed 실측 2026-11-08).
#   차트는 컨테이너 이미지를 태그 없는 image: auto(주입 자리표시)로 두고 imagePullPolicy
#   기본값이 "" 라 Deployment 에 쓰지 않는다. 그러면 Kubernetes 가 태그 없는 이미지의
#   기본값 Always 를 채운다. 이 값이 주입 템플릿(global.imagePullPolicy=IfNotPresent)보다
#   우선해서, 이미 노드에 있어도 파드가 뜰 때마다 레지스트리에서 다시 받았다.
#   그대로 두면 Harbor 가 내려갔을 때, 또는 --source local 에어갭에서 gateway 가 뜨지 못한다.
#   https://kubernetes.io/docs/concepts/containers/images/#imagepullpolicy-defaulting
#   이 값은 gateway Deployment 에만 쓰인다. 사이드카(proxyv2 주입)는 istiod 의
#   global.imagePullPolicy 를 따르고 이번에 바꾸지 않았다.
cat > "${CONF_DIR}/gateway-values.yaml.tmpl" <<EOF
#---------------------------------------------------------------------
# ${ISTIO_GATEWAY_NAME} (${ISTIO_GATEWAY_CHART} ${ISTIO_CHART_VERSION})
# 릴리스 이름 ${ISTIO_GATEWAY_NAME} -> Service/Deployment 이름이 같고,
# 라벨/selector 는 istio=ingressgateway 가 된다(차트 _helpers.tpl).
# imagePullPolicy: image: auto 때문에 Kubernetes 가 Always 를 채우는 것을 막는다(build-bundle.sh 주석).
#---------------------------------------------------------------------
imagePullPolicy: IfNotPresent
service:
  type: NodePort
  ports:
  - name: status-port
    port: 15021
    protocol: TCP
    targetPort: 15021
    nodePort: __NP_STATUS__
  - name: http2
    port: 80
    protocol: TCP
    targetPort: 80
    nodePort: __NP_HTTP__
  - name: https
    port: 443
    protocol: TCP
    targetPort: 443
    nodePort: __NP_HTTPS__
EOF
ok "conf/gateway-values.yaml.tmpl"

# istio-configure: UiPath 문서 Step 2 Option A 의 values + 결정 A(vanilla / exclusive).
#   https://docs.uipath.com/automation-suite/automation-suite/<major.minor>/installation-guide-eks-aks/installing-and-configuring-the-service-mesh
# 자리표시는 istio-configure.sh 가 바꾼다.
cat > "${CONF_DIR}/istio-configure-values.yaml.tmpl" <<EOF
#---------------------------------------------------------------------
# UiPath istio-configure ${UIPATH_ISTIO_CONFIGURE_VERSION} — release custom-istio-configure (${ISTIO_NAMESPACE})
#---------------------------------------------------------------------
fqdn: "__FQDN__"
gateway:
  selector:
    istio: ingressgateway
global:
  # vanilla Kubernetes 단일 테넌트(결정 A). 차트 기본값은 openshift / "" 이다.
  cluster_type: exclusive
  kubernetesDistribution: vanilla
  imagePullSecret:
    name: "__PULL_SECRET__"
minProtocolVersion: TLSV1_2
uipath:
  # 이미지 레지스트리. harbor: <HARBOR_HOSTNAME>/<프로젝트>, local: registry.uipath.com
  registry: "__UIPATH_REGISTRY__"
uipathServiceNamespace: "__UIPATH_NAMESPACE__"
# Service 를 고치지 않는다(NodePort 는 38-istio install.sh 가 관리한다).
# true 이면 sf-k8-utils-rhel 이미지가 더 필요하다.
patchIstioService: false
istioGatewayServiceName: "${ISTIO_GATEWAY_NAME}"
wasm:
  image:
    pullSecret: "__PULL_SECRET__"
    # 2026-11-07 에 확인한 차트 템플릿은 이 값을 참조하지 않는다(WasmPlugin url 은
    # 클러스터 안 http). UiPath 문서 형식대로 넣는다.
    registry: "oci://__UIPATH_REGISTRY__"
EOF
ok "conf/istio-configure-values.yaml.tmpl"

# smoke: 게이트웨이가 실제로 HTTP/HTTPS 를 받는지 본다. 백엔드 없이 200 을 돌려준다.
# 판정이 끝나면 install.sh 가 지운다.
cat > "${CONF_DIR}/smoke.yaml.tmpl" <<'EOF'
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: istio-smoke
  namespace: __NS__
spec:
  selector:
    istio: ingressgateway
  servers:
  - port:
      number: 80
      name: http-istio-smoke
      protocol: HTTP
    hosts:
    - "__HOST__"
  - port:
      number: 443
      name: https-istio-smoke
      protocol: HTTPS
    hosts:
    - "__HOST__"
    tls:
      mode: SIMPLE
      credentialName: __TLS_SECRET__
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: istio-smoke
  namespace: __NS__
spec:
  hosts:
  - "__HOST__"
  gateways:
  - istio-smoke
  http:
  - directResponse:
      status: 200
      body:
        string: "istio-smoke-ok"
EOF
ok "conf/smoke.yaml.tmpl"

#=====================================================================
# 4. 렌더링으로 단언한다
#=====================================================================
step "helm template 으로 이미지·서비스 확인"

# kind 가 $2 인 문서의 image: 값만 뽑는다. 주입 템플릿(ConfigMap) 안의 image: 는
# 들여쓰기된 kind 를 가진 문자열이라 제외된다(최상위 kind: 줄만 본다).
images_of_kind() {
    awk -v want="$2" '
        /^---/        { k = "" }
        /^kind: /     { k = $2 }
        k == want && /^[[:space:]]*image:[[:space:]]*/ {
            sub(/^[[:space:]]*image:[[:space:]]*/, ""); gsub(/"/, ""); print
        }' "$1" | sort -u
}

RENDERED="$(mktemp)"; TMP_DIRS+=("$RENDERED")
LOCAL_HUB="${ISTIO_SOURCE_REGISTRY}/istio"

"$HELM_BIN" template istiod "$ISTIOD_TGZ" --namespace "$ISTIO_NAMESPACE" \
    -f "${CONF_DIR}/istiod-values.yaml" \
    --set "global.hub=${LOCAL_HUB}" --set "global.tag=${ISTIO_TAG}" > "$RENDERED" \
    || die "istiod helm template 실패"
mapfile -t DEP_IMAGES < <(images_of_kind "$RENDERED" Deployment)
[[ "${#DEP_IMAGES[@]}" -eq 1 && "${DEP_IMAGES[0]}" == "$ISTIO_PILOT_IMAGE" ]] \
    || die "istiod Deployment 이미지가 예상과 다르다: ${DEP_IMAGES[*]:-없음} (예상 ${ISTIO_PILOT_IMAGE})"
ok "istiod Deployment 이미지 = ${ISTIO_PILOT_IMAGE}"
# 사이드카·게이트웨이 프록시 이미지는 주입 values 의 hub/tag/proxy.image 로 정해진다.
for k in "\"hub\": \"${LOCAL_HUB}\"" "\"tag\": \"${ISTIO_TAG}\"" '"image": "proxyv2"'; do
    grep -qF "$k" "$RENDERED" || die "주입 values 에 ${k} 가 없다"
done
ok "주입 프록시 이미지 = ${LOCAL_HUB}/proxyv2:${ISTIO_TAG} (= ${ISTIO_PROXYV2_IMAGE})"
[[ "${LOCAL_HUB}/proxyv2:${ISTIO_TAG}" == "$ISTIO_PROXYV2_IMAGE" ]] \
    || die "versions.env 의 ISTIO_PROXYV2_IMAGE 가 hub/tag 와 맞지 않는다"
for k in 'holdApplicationUntilProxyStarts": true' 'ENABLE_NATIVE_SIDECARS' 'system-cluster-critical'; do
    grep -qF "$k" "$RENDERED" || die "istiod 렌더링에 UiPath 값이 반영되지 않았다: ${k}"
done
ok "UiPath values-air 값 반영 확인"

GW_VALUES="$(mktemp)"; TMP_DIRS+=("$GW_VALUES")
sed -e "s/__NP_HTTP__/${ISTIO_NODEPORT_HTTP}/" -e "s/__NP_HTTPS__/${ISTIO_NODEPORT_HTTPS}/" \
    -e "s/__NP_STATUS__/${ISTIO_NODEPORT_STATUS}/" "${CONF_DIR}/gateway-values.yaml.tmpl" > "$GW_VALUES"
"$HELM_BIN" template "$ISTIO_GATEWAY_NAME" "$GATEWAY_TGZ" --namespace "$ISTIO_NAMESPACE" \
    -f "$GW_VALUES" > "$RENDERED" || die "gateway helm template 실패"
SVC_DOC="$(awk '/^---/{k=""} /^kind: /{k=$2} k=="Service"' "$RENDERED")"
grep -q 'type: NodePort' <<<"$SVC_DOC" || die "gateway Service 가 NodePort 가 아니다"
for np in "$ISTIO_NODEPORT_HTTP" "$ISTIO_NODEPORT_HTTPS" "$ISTIO_NODEPORT_STATUS"; do
    grep -qE "nodePort: ${np}\$" <<<"$SVC_DOC" || die "gateway Service 에 nodePort ${np} 가 없다"
done
# metadata.labels 에도 같은 줄이 있으므로 spec.selector 블록만 본다.
SVC_SEL="$(awk '/^  selector:/{s=1; next} s && /^  [^ ]/{s=0} s' <<<"$SVC_DOC")"
grep -qx '    istio: ingressgateway' <<<"$SVC_SEL" || die "gateway Service selector 에 istio: ingressgateway 가 없다"
[[ "$(images_of_kind "$RENDERED" Deployment)" == "auto" ]] \
    || die "gateway Deployment 이미지가 auto(주입)가 아니다"
awk '/^---/{k=""} /^kind: /{k=$2} k=="Deployment"' "$RENDERED" | grep -qE '^\s*imagePullPolicy: IfNotPresent$' \
    || die "gateway Deployment 에 imagePullPolicy: IfNotPresent 가 없다(없으면 Kubernetes 가 Always 를 채운다)"
ok "gateway Service NodePort ${ISTIO_NODEPORT_HTTP}/${ISTIO_NODEPORT_HTTPS}/${ISTIO_NODEPORT_STATUS}, selector istio=ingressgateway, 이미지 주입(auto), imagePullPolicy IfNotPresent"

IC_VALUES="$(mktemp)"; TMP_DIRS+=("$IC_VALUES")
sed -e "s|__FQDN__|${AS_FQDN:-as.example.internal}|g" -e "s|__UIPATH_REGISTRY__|${ISTIO_SOURCE_REGISTRY}|g" \
    -e "s|__PULL_SECRET__||g" -e "s|__UIPATH_NAMESPACE__|${UIPATH_AS_NAMESPACE}|g" \
    "${CONF_DIR}/istio-configure-values.yaml.tmpl" > "$IC_VALUES"
"$HELM_BIN" template custom-istio-configure "$IC_TGZ" --namespace "$ISTIO_NAMESPACE" \
    -f "$IC_VALUES" > "$RENDERED" || die "istio-configure helm template 실패"
# 60-cilium 과 같은 방식으로 image: 줄을 모두 뽑는다(Deployment·Job 모두).
IC_IMAGES="$(grep -hoE '^\s*image:\s*"?[^"]+"?$' "$RENDERED" \
    | sed -E 's/^\s*image:\s*//; s/^"//; s/"$//' | sort -u)"
IC_WANT="$(printf '%s\n' "$UIPATH_WASM_IMAGE" "$UIPATH_ISTIO_CURL_IMAGE" | sort -u)"
[[ "$IC_IMAGES" == "$IC_WANT" ]] \
    || die "istio-configure 이미지 집합이 예상과 다르다: $(tr '\n' ' ' <<<"$IC_IMAGES")"
ok "istio-configure 이미지 = $(tr '\n' ' ' <<<"$IC_WANT")"
for k in "k8s_distribution: vanilla" "cluster_type: exclusive"; do
    grep -qF "$k" "$RENDERED" || die "istio-configure pluginConfig 에 ${k} 가 없다"
done
ok "istio-configure pluginConfig: cluster_type=exclusive, k8s_distribution=vanilla"

#=====================================================================
# 5. 검증용 이미지 묶음 (ISTIO_LOCAL_IMAGES=1 일 때만)
#=====================================================================
if [[ "$WITH_LOCAL" == "1" ]]; then
    step "검증용 이미지 묶음 ${LOCAL_NAME} (다이제스트 핀)"
    rm -rf "${LOCAL_DIR}/conf"
    rm -f "${LOCAL_DIR}/SHA256SUMS" "${LOCAL_DIR}/BUNDLE-INFO"
    mkdir -p "${LOCAL_DIR}/images" "${LOCAL_DIR}/conf"

    # 태그 ref 와 다이제스트 핀. 받는 것은 핀이고, tar 안의 이름은 태그 ref 다
    # (ctr import 뒤 install.sh 가 그 이름으로 참조한다).
    LOCAL_REFS=(
        "${ISTIO_PILOT_IMAGE}|${ISTIO_PILOT_DIGEST}"
        "${ISTIO_PROXYV2_IMAGE}|${ISTIO_PROXYV2_DIGEST}"
        "${UIPATH_WASM_IMAGE}|${UIPATH_WASM_DIGEST}"
        "${UIPATH_ISTIO_CURL_IMAGE}|${UIPATH_ISTIO_CURL_DIGEST}"
    )
    KEEP=()
    for e in "${LOCAL_REFS[@]}"; do
        img="${e%%|*}"; pin="${e#*|}"
        [[ "$pin" =~ ^sha256:[0-9a-f]{64}$ ]] || die "다이제스트 형식 오류: ${img} ${pin}"
        out="${LOCAL_DIR}/images/$(image_to_filename "$img").tar"
        KEEP+=("$out")
        if [[ -s "$out" ]]; then
            log "이미 존재, 건너뜀: $(basename "$out")"
            continue
        fi
        rm -f "${out}.part"
        skopeo copy --override-os linux --override-arch amd64 --retry-times 5 \
            "docker://${img%:*}@${pin}" "docker-archive:${out}.part:${img}" >/dev/null \
            || die "이미지 받기 실패: ${img%:*}@${pin}"
        mv "${out}.part" "$out"
        ok "$(basename "$out") ($(du -h "$out" | cut -f1))"
    done
    # 이전 버전의 tar 가 남아 있으면 지운다.
    for f in "${LOCAL_DIR}"/images/*.tar; do
        [[ " ${KEEP[*]} " == *" ${f} "* ]] || { rm -f "$f"; log "이전 이미지 캐시 제거: $(basename "$f")"; }
    done
    printf '%s\n' "$ISTIO_PILOT_IMAGE" "$ISTIO_PROXYV2_IMAGE" > "${LOCAL_DIR}/conf/images-istio.list"
    printf '%s\n' "$UIPATH_WASM_IMAGE" "$UIPATH_ISTIO_CURL_IMAGE" > "${LOCAL_DIR}/conf/images-uipath.list"

    cat > "${LOCAL_DIR}/BUNDLE-INFO" <<EOF
bundle        : ${LOCAL_NAME}
bundle_version: ${BUNDLE_VERSION}
built_at      : $(date -Is)
built_on      : $(hostname)
용도          : 단일 노드 검증 전용(install.sh / istio-configure.sh --source local).
                운영은 hydrate 된 Harbor 에서 받는다(--source harbor).
위치          : ${BUNDLE_NAME}/ 와 같은 디렉터리에 푼다(또는 ISTIO_LOCAL_IMAGES_DIR).
pilot         : ${ISTIO_PILOT_IMAGE%:*}@${ISTIO_PILOT_DIGEST}
proxyv2       : ${ISTIO_PROXYV2_IMAGE%:*}@${ISTIO_PROXYV2_DIGEST}
wasm-plugin   : ${UIPATH_WASM_IMAGE%:*}@${UIPATH_WASM_DIGEST}
curl          : ${UIPATH_ISTIO_CURL_IMAGE%:*}@${UIPATH_ISTIO_CURL_DIGEST}
EOF
    write_manifest "$LOCAL_DIR"
    LOCAL_TARBALL="${SCRIPT_DIR}/bundle/${LOCAL_NAME}.tar.gz"
    tar -C "${SCRIPT_DIR}/bundle" -czf "$LOCAL_TARBALL" "$LOCAL_NAME"
    ( cd "$(dirname "$LOCAL_TARBALL")" && sha256sum "$(basename "$LOCAL_TARBALL")" ) > "${LOCAL_TARBALL}.sha256"
    ok "검증용 묶음: ${LOCAL_TARBALL} ($(du -h "$LOCAL_TARBALL" | cut -f1))"
else
    log "검증용 이미지 묶음은 만들지 않는다(ISTIO_LOCAL_IMAGES=1 일 때만). 운영은 hydrate 된 Harbor 를 쓴다."
fi

#=====================================================================
# 6. 패키징 (운영 번들)
#=====================================================================
step "번들 패키징"
mkdir -p "${BUNDLE_DIR}/00-common"
cp "${SCRIPT_DIR}/../00-common/versions.env" "${BUNDLE_DIR}/00-common/"
if [[ -f "${SCRIPT_DIR}/../00-common/site.env" ]]; then
    cp "${SCRIPT_DIR}/../00-common/site.env" "${BUNDLE_DIR}/00-common/"
else
    cp "${SCRIPT_DIR}/../00-common/site.env.example" "${BUNDLE_DIR}/00-common/"
    warn "site.env 가 없어 예시 값으로 번들을 만든다. 타깃에서 값을 채워야 한다."
fi
cp "${SCRIPT_DIR}/../00-common/common.sh" "${BUNDLE_DIR}/00-common/"
cp -R "${SCRIPT_DIR}/../00-common/os"     "${BUNDLE_DIR}/00-common/"
cp "${SCRIPT_DIR}/install.sh" "${SCRIPT_DIR}/istio-configure.sh" "${SCRIPT_DIR}/istio-lib.sh" "${BUNDLE_DIR}/"
cp "${SCRIPT_DIR}/README.md"  "${BUNDLE_DIR}/" 2>/dev/null || true
chmod +x "${BUNDLE_DIR}/install.sh" "${BUNDLE_DIR}/istio-configure.sh"

H="<HARBOR_HOSTNAME>/${ISTIO_HARBOR_PROJECT}"
cat > "${BUNDLE_DIR}/BUNDLE-INFO" <<EOF
bundle        : ${BUNDLE_NAME}
bundle_version: ${BUNDLE_VERSION}
built_at      : $(date -Is)
built_on      : $(hostname)
target_os     : 공용 (OS 의존 없음)
as_version    : ${UIPATH_AS_VERSION}
istio         : ${ISTIO_VERSION} (이미지 태그 ${ISTIO_TAG}, AS ${UIPATH_AS_VERSION} 번들과 같음)
charts        : ${ISTIO_BASE_CHART} / ${ISTIO_ISTIOD_CHART} / ${ISTIO_GATEWAY_CHART} ${ISTIO_CHART_VERSION},
                ${UIPATH_ISTIO_CONFIGURE_CHART} ${UIPATH_ISTIO_CONFIGURE_VERSION}
images        : 번들에 없음. hydrate 된 Harbor 에서 받는다(--source harbor, 기본).
harbor 경로   : ${H}/istio/pilot:${ISTIO_TAG}
                ${H}/istio/proxyv2:${ISTIO_TAG}
                ${H}/${UIPATH_WASM_IMAGE#*/}
                ${H}/${UIPATH_ISTIO_CURL_IMAGE#*/}
                oci://${H}/${ISTIO_BASE_CHART%/*}/{base,istiod,gateway} ${ISTIO_CHART_VERSION}
                oci://${H}/${UIPATH_ISTIO_CONFIGURE_CHART} ${UIPATH_ISTIO_CONFIGURE_VERSION}
nodeport      : http2 ${ISTIO_NODEPORT_HTTP} / https ${ISTIO_NODEPORT_HTTPS} / status-port ${ISTIO_NODEPORT_STATUS}
EOF

write_manifest "$BUNDLE_DIR"
TARBALL="${SCRIPT_DIR}/bundle/${BUNDLE_NAME}.tar.gz"
tar -C "${SCRIPT_DIR}/bundle" -czf "$TARBALL" "$BUNDLE_NAME"
( cd "$(dirname "$TARBALL")" && sha256sum "$(basename "$TARBALL")" ) > "${TARBALL}.sha256"

step "완료"
cat "${BUNDLE_DIR}/BUNDLE-INFO"
echo
ok "번들: ${TARBALL} ($(du -h "$TARBALL" | cut -f1))"
