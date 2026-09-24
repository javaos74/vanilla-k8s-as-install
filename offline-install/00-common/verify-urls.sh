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
apt_pkg_ok() {
    local packages_url="$1" pkg="$2" ver="$3"
    curl -sL --max-time 60 "$packages_url" 2>/dev/null \
        | grep -E '^(Package|Version):' | paste - - \
        | grep -qF "Package: ${pkg}	Version: ${ver}"
}

deb_url() {   # $1=codename  $2=deb 파일명
    echo "${DOCKER_REPO}/dists/$1/pool/stable/${BUNDLE_ARCH}/$2"
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
for cn in jammy noble; do
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

step "HAProxy"
check "haproxy 이미지 ${HAPROXY_IMAGE}" image_ok "$HAPROXY_IMAGE"

check_summary
