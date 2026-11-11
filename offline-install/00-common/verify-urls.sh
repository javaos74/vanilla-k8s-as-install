#!/usr/bin/env bash
#---------------------------------------------------------------------
# versions.env 에 적힌 모든 산출물이 실제로 내려받을 수 있는지 검증한다.
#
# 번들을 만들기 전에 반드시 통과시킨다. 버전을 올릴 때도 이것부터 돌린다.
# 업스트림이 배포를 내리는 일이 실제로 발생하므로(MinIO 사례) 정기 확인이 필요하다.
#
# 실행: ./verify-urls.sh          (온라인 호스트에서)
# 종료코드: 0 = 전부 접근 가능 / 1 = 하나 이상 실패
#---------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

require_cmds curl
require_online

#--- HTTP 산출물 -------------------------------------------------------
# HEAD 로 확인. 일부 CDN 이 HEAD 를 막으므로 실패 시 Range 로 1바이트만 GET 해 재확인한다.
http_ok() {
    local url="$1" code
    code="$(curl -sIL -o /dev/null -w '%{http_code}' --max-time 25 "$url" 2>/dev/null || echo 000)"
    if [[ "$code" == "200" ]]; then return 0; fi
    code="$(curl -sL -o /dev/null -w '%{http_code}' --max-time 25 -r 0-0 "$url" 2>/dev/null || echo 000)"
    [[ "$code" == "200" || "$code" == "206" ]]
}

#--- 컨테이너 이미지 ---------------------------------------------------
# 레지스트리 v2 API 로 매니페스트 존재를 확인한다.
# skopeo 가 있으면 그쪽이 정확하므로 우선 사용한다.
image_ok() {
    local ref="$1"
    if command -v skopeo >/dev/null 2>&1; then
        skopeo inspect --raw "docker://${ref}" >/dev/null 2>&1 && return 0
        return 1
    fi
    # skopeo 없을 때: 익명 토큰 -> manifest HEAD
    local repo="${ref%:*}" tag="${ref##*:}" registry path token
    # 다이제스트 참조(repo@sha256:...)는 ':' 로 자르면 깨진다.
    if [[ "$ref" == *@* ]]; then repo="${ref%@*}"; tag="${ref#*@}"; fi
    registry="${repo%%/*}"; path="${repo#*/}"
    case "$registry" in
        quay.io)
            curl -sfI --max-time 25 \
                -H 'Accept: application/vnd.oci.image.index.v1+json' \
                -H 'Accept: application/vnd.docker.distribution.manifest.list.v2+json' \
                -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' \
                "https://quay.io/v2/${path}/manifests/${tag}" >/dev/null 2>&1
            ;;
        *)  # Docker Hub (공식 이미지는 library/ 접두어)
            [[ "$repo" == */* ]] || path="library/${repo}"
            [[ "$registry" == *.* ]] || { path="library/${repo}"; }
            token="$(curl -s --max-time 20 \
                "https://auth.docker.io/token?service=registry.docker.io&scope=repository:${path}:pull" \
                | sed 's/.*"token":"\([^"]*\)".*/\1/')"
            [[ -n "$token" ]] || return 1
            curl -sfI --max-time 25 -H "Authorization: Bearer ${token}" \
                -H 'Accept: application/vnd.oci.image.index.v1+json' \
                -H 'Accept: application/vnd.docker.distribution.manifest.list.v2+json' \
                -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' \
                "https://registry-1.docker.io/v2/${path}/manifests/${tag}" >/dev/null 2>&1
            ;;
    esac
}

#--- apt 저장소 안의 특정 패키지 버전 ----------------------------------
# Packages 파일을 받아 Package/Version 조합이 실제로 있는지 본다.
# URL HEAD 만으로는 "저장소는 있지만 그 버전은 없다"를 못 잡는다.
# 색인을 한 번 변수에 담아 파이프를 없앤다(common.sh ctr_missing_images 와 같은 이유).
# `... | paste - - | grep -qF` 로 쓰면 grep -q 가 첫 일치에서 끝나고, 아직 쓰던 paste 가
# SIGPIPE(141)로 죽어 pipefail 때문에 "없음"이 된다. 목록 앞쪽 패키지에서만 생긴다
# (실측 2026-11-11: NVIDIA Packages 184KB 에서 libnvidia-container-tools 만 5/5 오탐).
apt_pkg_ok() {
    local packages_url="$1" pkg="$2" ver="$3" idx
    idx="$(curl -sL --max-time 60 "$packages_url" 2>/dev/null \
        | grep -E '^(Package|Version):' | paste - -)" || return 1
    grep -qF "Package: ${pkg}	Version: ${ver}" <<<"$idx"
}

deb_url() {   # $1=codename  $2=deb 파일명
    echo "${DOCKER_REPO}/dists/$1/pool/stable/${BUNDLE_ARCH}/$2"
}

#--- Ollama 모델 매니페스트 --------------------------------------------
# registry.ollama.ai 의 매니페스트 본문 sha256 이 핀과 같은지 본다($1=모델:태그 $2=sha256:...).
# 존재 여부만 보면 태그가 다른 가중치로 재지정된 것을 못 잡는다.
ollama_manifest_ok() {
    local name="${1%%:*}" tag="${1#*:}" sum
    sum="$(curl -fsSL --max-time 25 \
        -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' \
        "https://registry.ollama.ai/v2/library/${name}/manifests/${tag}" 2>/dev/null \
        | sha256sum | cut -d' ' -f1)" || return 1
    [[ "sha256:${sum}" == "$2" ]]
}

step "Kubernetes deb 패키지 (${K8S_APT_REPO})"
for pkg in kubeadm kubelet kubectl; do
    check "${pkg} ${K8S_PKG_VERSION}" apt_pkg_ok "${K8S_APT_REPO}/Packages" "$pkg" "$K8S_PKG_VERSION"
done
check "cri-tools ${CRI_TOOLS_PKG_VERSION}"      apt_pkg_ok "${K8S_APT_REPO}/Packages" cri-tools      "$CRI_TOOLS_PKG_VERSION"
check "kubernetes-cni ${KUBERNETES_CNI_PKG_VERSION}" apt_pkg_ok "${K8S_APT_REPO}/Packages" kubernetes-cni "$KUBERNETES_CNI_PKG_VERSION"
check "k8s apt 서명키"                          http_ok "$K8S_APT_KEY_URL"

step "컨테이너 런타임 / Docker (deb)"
# containerd.io 는 containerd + ctr + shim + runc 를 모두 제공하므로
# 별도 runc / cni-plugins tarball 검증 항목이 없다.
for cn in jammy noble resolute; do
    osv="$(codename_to_osversion "$cn")"
    check "containerd.io ${CONTAINERD_VERSION} (${cn})" \
        http_ok "$(deb_url "$cn" "containerd.io_${CONTAINERD_VERSION}-${CONTAINERD_DEB_REVISION}~ubuntu.${osv}~${cn}_${BUNDLE_ARCH}.deb")"
    check "docker-ce ${DOCKER_VERSION} (${cn})" \
        http_ok "$(deb_url "$cn" "docker-ce_${DOCKER_VERSION}-${DOCKER_DEB_REVISION}~ubuntu.${osv}~${cn}_${BUNDLE_ARCH}.deb")"
    check "docker-ce-cli ${DOCKER_VERSION} (${cn})" \
        http_ok "$(deb_url "$cn" "docker-ce-cli_${DOCKER_VERSION}-${DOCKER_DEB_REVISION}~ubuntu.${osv}~${cn}_${BUNDLE_ARCH}.deb")"
done
check "docker apt 서명키"                        http_ok "$DOCKER_APT_KEY_URL"

step "도구"
check "helm ${HELM_VERSION}"                     http_ok "$HELM_URL"
check "podman-static ${PODMAN_STATIC_VERSION}"   http_ok "$PODMAN_STATIC_URL"
check "podman-static 서명(.asc)"                 http_ok "$PODMAN_STATIC_ASC_URL"

step "Cilium"
check "cilium chart ${CILIUM_VERSION}"      http_ok "$CILIUM_CHART_URL"
check "cilium-cli ${CILIUM_CLI_VERSION}"    http_ok "$CILIUM_CLI_URL"
check "cilium 이미지 v${CILIUM_VERSION}"    image_ok "quay.io/cilium/cilium:v${CILIUM_VERSION}"
check "cilium-operator 이미지"              image_ok "quay.io/cilium/operator-generic:v${CILIUM_VERSION}"

step "NFS CSI"
check "csi-driver-nfs ${CSI_DRIVER_NFS_VERSION}"             http_ok "$CSI_DRIVER_NFS_SRC_URL"
check "external-snapshotter ${EXTERNAL_SNAPSHOTTER_VERSION}" http_ok "$EXTERNAL_SNAPSHOTTER_SRC_URL"

step "Harbor"
check "harbor offline installer ${HARBOR_VERSION}" http_ok "$HARBOR_OFFLINE_URL"

step "MinIO (오픈소스 아카이브됨 - quay.io 이미지만 생존)"
check "minio 이미지"    image_ok "$MINIO_IMAGE"
check "mc 이미지"       image_ok "$MINIO_MC_IMAGE"
# dl.min.io 가 되살아났는지도 같이 본다. 200 이면 versions.env 를 재검토할 신호다.
if http_ok "https://dl.min.io/server/minio/release/linux-${BUNDLE_ARCH}/minio"; then
    warn "dl.min.io 가 다시 응답한다. 바이너리 배포가 복구됐는지 확인할 것."
else
    log "dl.min.io 는 여전히 410 Gone (예상된 상태)"
fi

step "SeaweedFS (MinIO 대안 검토, Apache-2.0)"
# 태그가 아니라 번들이 실제로 받는 다이제스트 참조를 확인한다.
check "seaweedfs 이미지 (${SEAWEEDFS_IMAGE##*:})" \
    image_ok "${SEAWEEDFS_IMAGE%:*}@${SEAWEEDFS_IMAGE_DIGEST}"
check "aws-cli 이미지 (${SEAWEEDFS_CLIENT_IMAGE##*:})" \
    image_ok "${SEAWEEDFS_CLIENT_IMAGE%:*}@${SEAWEEDFS_CLIENT_IMAGE_DIGEST}"

step "Metrics Server (registry.uipath.com 미러, 다이제스트 참조)"
check "metrics-server 이미지 (${METRICS_SERVER_SOURCE_IMAGE##*:})" \
    image_ok "${METRICS_SERVER_SOURCE_IMAGE%:*}@${METRICS_SERVER_SOURCE_DIGEST}"

step "Istio (38-istio, AS ${UIPATH_AS_VERSION} 번들과 같은 값)"
# 이미지는 번들(검증용 묶음)이 실제로 받는 다이제스트 참조를, 차트는 태그를 확인한다.
check "pilot 이미지 (${ISTIO_TAG})" \
    image_ok "${ISTIO_PILOT_IMAGE%:*}@${ISTIO_PILOT_DIGEST}"
check "proxyv2 이미지 (${ISTIO_TAG})" \
    image_ok "${ISTIO_PROXYV2_IMAGE%:*}@${ISTIO_PROXYV2_DIGEST}"
check "istio-wasm-plugin 이미지 (${UIPATH_WASM_TAG})" \
    image_ok "${UIPATH_WASM_IMAGE%:*}@${UIPATH_WASM_DIGEST}"
check "curl 이미지 (${UIPATH_ISTIO_CURL_TAG})" \
    image_ok "${UIPATH_ISTIO_CURL_IMAGE%:*}@${UIPATH_ISTIO_CURL_DIGEST}"
for c in "$ISTIO_BASE_CHART" "$ISTIO_ISTIOD_CHART" "$ISTIO_GATEWAY_CHART"; do
    check "차트 ${c}:${ISTIO_CHART_VERSION}" image_ok "${ISTIO_SOURCE_REGISTRY}/${c}:${ISTIO_CHART_VERSION}"
done
check "차트 ${UIPATH_ISTIO_CONFIGURE_CHART}:${UIPATH_ISTIO_CONFIGURE_VERSION}" \
    image_ok "${ISTIO_SOURCE_REGISTRY}/${UIPATH_ISTIO_CONFIGURE_CHART}:${UIPATH_ISTIO_CONFIGURE_VERSION}"

# AS 번들 목록과 versions.env 의 Istio 값이 맞는지 대조한다. UIPATH_AS_VERSION 만 바꾸고
# Istio 값을 그대로 두면 여기서 실패한다(versions.env Istio 절 주석).
# 목록의 항목은 레지스트리 호스트가 없는 "<경로>:<태그>" 형식이다.
as_list_has() { grep -qxF "$2" <<<"$1"; }
AS_AIR="$(curl -fsSL --max-time 30 "${UIPATH_AS_DOWNLOAD_URL}/air-images.txt" 2>/dev/null | tr -d '\r' || true)"
AS_CHARTS="$(curl -fsSL --max-time 30 "${UIPATH_AS_DOWNLOAD_URL}/embedded-helm-charts.txt" 2>/dev/null | tr -d '\r' || true)"
for i in "$ISTIO_PILOT_IMAGE" "$ISTIO_PROXYV2_IMAGE" "$UIPATH_WASM_IMAGE" "$UIPATH_ISTIO_CURL_IMAGE"; do
    check "AS ${UIPATH_AS_VERSION} air-images.txt 에 ${i#*/}" as_list_has "$AS_AIR" "${i#*/}"
done
for c in "${ISTIO_BASE_CHART}:${ISTIO_CHART_VERSION}" "${ISTIO_ISTIOD_CHART}:${ISTIO_CHART_VERSION}" \
         "${ISTIO_GATEWAY_CHART}:${ISTIO_CHART_VERSION}" \
         "${UIPATH_ISTIO_CONFIGURE_CHART}:${UIPATH_ISTIO_CONFIGURE_VERSION}"; do
    check "AS ${UIPATH_AS_VERSION} embedded-helm-charts.txt 에 ${c}" as_list_has "$AS_CHARTS" "$c"
done

step "HAProxy"
check "haproxy 이미지 ${HAPROXY_IMAGE}" image_ok "$HAPROXY_IMAGE"

step "Ollama 임베딩 (85-ollama-embedding)"
# 태그가 아니라 빌드가 실제로 쓰는 다이제스트 참조를 확인한다.
check "ollama 베이스 이미지 (${OLLAMA_VERSION})" \
    image_ok "${OLLAMA_BASE_IMAGE%:*}@${OLLAMA_BASE_DIGEST}"
check "nginx 이미지 (${OLLAMA_EMBED_NGINX_IMAGE##*:})" \
    image_ok "${OLLAMA_EMBED_NGINX_IMAGE%:*}@${OLLAMA_EMBED_NGINX_DIGEST}"
check "CPU 모델 ${OLLAMA_EMBED_CPU_MODEL} 매니페스트 = 핀" \
    ollama_manifest_ok "$OLLAMA_EMBED_CPU_MODEL" "$OLLAMA_EMBED_CPU_MODEL_DIGEST"
check "GPU 모델 ${OLLAMA_EMBED_GPU_MODEL} 매니페스트 = 핀" \
    ollama_manifest_ok "$OLLAMA_EMBED_GPU_MODEL" "$OLLAMA_EMBED_GPU_MODEL_DIGEST"

step "NVIDIA GPU 사전 준비 (85-ollama-embedding)"
# 드라이버·커널 모듈은 커널별이라 build-gpu-prep.sh 가 빌드 때 확인한다.
for pkg in nvidia-container-toolkit nvidia-container-toolkit-base libnvidia-container-tools libnvidia-container1; do
    check "${pkg} ${NVIDIA_CTK_VERSION}" \
        apt_pkg_ok "${NVIDIA_CTK_REPO}/${BUNDLE_ARCH}/Packages" "$pkg" "$NVIDIA_CTK_VERSION"
done
check "nvidia-container-toolkit apt 서명키" http_ok "$NVIDIA_CTK_KEY_URL"

check_summary
