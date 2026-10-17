#!/usr/bin/env bash
#---------------------------------------------------------------------
# 10-k8s : 오프라인 번들 빌드 (온라인 호스트에서 실행)
#
# 산출물: bundle/k8s-<K8S_VERSION>-<OS 태그>/  + 같은 이름의 .tar.gz
#         OS 태그: Ubuntu 는 코드네임(jammy/noble/resolute)
#
# 중요 제약: 빌드 호스트의 OS 는 설치 대상과 같아야 한다.
#   패키지 의존성 해석이 "지금 설치돼 있지 않은 것"을 기준으로 이뤄지므로,
#   같은 OS 이미지에서 빌드해야 타깃에 필요한 패키지가 정확히 담긴다.
#   22.04 타깃 번들은 22.04 에서, 24.04 타깃 번들은 24.04 에서 빌드한다.
#
# OS 패키지 수집은 pkgs-<OS 계열>.sh 에 있다(현재 pkgs-debian.sh).
# 그 파일이 빌드 호스트에 남기는 변경은 파일 머리말에 적혀 있다.
# 그 밖에 skopeo 를 설치한다(이미지를 tar 로 받기 위한 빌드 도구, 멱등).
#---------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../00-common/common.sh"

# pkgs-<계열>.sh 의 pkgs_download 가 읽는다.
ALLOW_DIRTY_HOST=0
while (($#)); do
    case "$1" in
        --allow-dirty-host) ALLOW_DIRTY_HOST=1 ;;
        -h|--help) sed -n '3,14p' "${BASH_SOURCE[0]}" | sed 's/^#//'; exit 0 ;;
        *) die "알 수 없는 인자: $1  (--allow-dirty-host)" ;;
    esac
    shift
done

require_online
require_cmds curl tar

# OS 계열별 패키지 수집(pkgs_prepare_build_host / pkgs_download).
PKGS_IMPL="${SCRIPT_DIR}/pkgs-${OS_FAMILY}.sh"
[[ -f "$PKGS_IMPL" ]] \
    || die "이 OS 계열(${OS_FAMILY}, ID=${OS_ID:-?})용 패키지 수집 구현이 없다: $(basename "$PKGS_IMPL")"
# shellcheck source=pkgs-debian.sh
source "$PKGS_IMPL"

OS_TAG="$(os_bundle_tag)"
OS_LABEL="$(os_label)"
detect_arch >/dev/null

BUNDLE_NAME="k8s-${K8S_VERSION}-${OS_TAG}"
BUNDLE_DIR="${SCRIPT_DIR}/bundle/${BUNDLE_NAME}"
PKG_DIR="${BUNDLE_DIR}/${PKG_BUNDLE_SUBDIR}"
IMG_DIR="${BUNDLE_DIR}/images"
BIN_DIR="${BUNDLE_DIR}/bin"
CONF_DIR="${BUNDLE_DIR}/conf"

step "빌드 대상: ${OS_LABEL} / k8s ${K8S_VERSION}"
#---------------------------------------------------------------------
# 매 빌드에 다시 만드는 것은 먼저 지운다
#
# mkdir -p 만 쓰면 이전 빌드의 파일이 그대로 남아 새 아카이브에 실린다.
# 실측 사고: site.env 를 뺀 뒤 다시 빌드했는데도 이전 빌드의 site.env 가
# 번들에 남아 내부 IP·사내 호스트명이 그대로 들어갔다. SHA256SUMS 는 그것까지
# 포함해 만들어지므로 무결성 검사로도 걸러지지 않는다.
#
# debs / images / bin 은 의도적 다운로드 캐시라 남긴다. 아래는 매번
# 스크립트가 생성·복사하는 것들이므로 지워도 재빌드 비용이 없다.
#---------------------------------------------------------------------
rm -rf "${BUNDLE_DIR}/00-common" "${BUNDLE_DIR}/conf" "${BUNDLE_DIR}/90-verify"
rm -f  "${BUNDLE_DIR}"/*.sh "${BUNDLE_DIR}"/*.md \
       "${BUNDLE_DIR}/SHA256SUMS" "${BUNDLE_DIR}/BUNDLE-INFO"

mkdir -p "$PKG_DIR" "$IMG_DIR" "$BIN_DIR" "$CONF_DIR"

#=====================================================================
# 1. 빌드 호스트 준비 — 패키지 저장소 등록 (pkgs-<계열>.sh)
#=====================================================================
pkgs_prepare_build_host

# skopeo: 데몬 없이 레지스트리 -> tar 로 이미지를 받기 위한 빌드 도구.
# docker 데몬을 띄우지 않아도 되므로 빌드 호스트를 덜 오염시킨다.
if ! command -v skopeo >/dev/null 2>&1; then
    log "skopeo 설치(빌드 도구)"
    pkg_install_build_tool skopeo
fi
ok "skopeo $(skopeo --version | awk '{print $3}')"

#=====================================================================
# 2. OS 패키지 다운로드 (pkgs-<계열>.sh). PKG_COUNT 를 설정한다.
#=====================================================================
pkgs_download "$PKG_DIR"

#=====================================================================
# 3. k8s 컨트롤 플레인 이미지
#=====================================================================
step "k8s 이미지 목록 확인 및 다운로드"

# kubeadm 을 설치하지 않고 패키지 파일에서 바이너리만 꺼내 쓴다.
# 빌드 호스트를 오염시키지 않으면서 정확한 이미지 목록을 얻는 방법이다.
KUBEADM_EXTRACT="$(mktemp -d)"
trap 'rm -rf "$KUBEADM_EXTRACT"' EXIT
# shellcheck disable=SC2046  # glob 확장이 목적이다
pkg_extract "$(ls "$PKG_DIR"/$(pkg_file_glob kubeadm) | head -1)" "$KUBEADM_EXTRACT"
KUBEADM_BIN="${KUBEADM_EXTRACT}/usr/bin/kubeadm"
[[ -x "$KUBEADM_BIN" ]] || die "${PKG_EXT} 에서 kubeadm 바이너리를 찾지 못했다"

mapfile -t K8S_IMAGES < <("$KUBEADM_BIN" config images list \
                            --kubernetes-version "$K8S_VERSION" 2>/dev/null)
((${#K8S_IMAGES[@]} > 0)) || die "kubeadm 이미지 목록을 가져오지 못했다"

log "이미지 ${#K8S_IMAGES[@]}개:"
printf '    %s\n' "${K8S_IMAGES[@]}"

# 이미지 목록을 번들에 남긴다. install.sh 가 이 목록으로 적재를 검증한다.
printf '%s\n' "${K8S_IMAGES[@]}" > "${CONF_DIR}/images.list"

# pause 이미지는 containerd 설정(pinned_images.sandbox)에 그대로 들어가야 한다.
# kubeadm 이 기대하는 값과 다르면 파드가 sandbox 생성 단계에서 실패한다.
PAUSE_IMAGE="$(printf '%s\n' "${K8S_IMAGES[@]}" | grep '/pause:' || true)"
[[ -n "$PAUSE_IMAGE" ]] || die "pause 이미지를 목록에서 찾지 못했다"
echo "$PAUSE_IMAGE" > "${CONF_DIR}/pause-image"
ok "sandbox(pause) 이미지: ${PAUSE_IMAGE}"

for img in "${K8S_IMAGES[@]}"; do
    out="${IMG_DIR}/$(image_to_filename "$img").tar"
    if [[ -s "$out" ]]; then
        log "이미 존재, 건너뜀: $(basename "$out")"
        continue
    fi
    log "이미지 받기: $img"
    # docker-archive 형식으로 저장한다. ctr images import 가 태그를 보존한 채
    # 그대로 읽을 수 있어 OCI layout 보다 취급이 단순하다.
    rm -f "${out}.part"
    skopeo copy --retry-times 5 \
        "docker://${img}" \
        "docker-archive:${out}.part:${img}" >/dev/null \
        || die "이미지 받기 실패: $img"
    mv "${out}.part" "$out"
    ok "$(basename "$out") ($(du -h "$out" | cut -f1))"
done

#=====================================================================
# 4. 도구 바이너리
#=====================================================================
step "도구 바이너리"
fetch "$HELM_URL"              "${BIN_DIR}/helm-${HELM_VERSION}-linux-${BUNDLE_ARCH}.tar.gz"
fetch "$PODMAN_STATIC_URL"     "${BIN_DIR}/podman-linux-${BUNDLE_ARCH}.tar.gz"
fetch "$PODMAN_STATIC_ASC_URL" "${BIN_DIR}/podman-linux-${BUNDLE_ARCH}.tar.gz.asc"

#=====================================================================
# 5. 설정 파일 생성
#=====================================================================
step "설정 파일 생성"

# kubeadm 설정. 단일 노드 기준.
# criSocket 을 명시하지 않으면 여러 런타임이 감지될 때 init 이 실패한다.
cat > "${CONF_DIR}/kubeadm-init.yaml" <<EOF
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
nodeRegistration:
  criSocket: unix:///run/containerd/containerd.sock
  kubeletExtraArgs:
    - name: node-ip
      value: __NODE_IP__
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: v${K8S_VERSION}
# __CONTROL_PLANE_ENDPOINT__ 는 install.sh 가 치환하거나 줄째로 지운다.
#   --control-plane-endpoint 를 준 경우  -> controlPlaneEndpoint: <LB>:6443
#   주지 않은 경우(단일 CP)              -> 줄 삭제
# 이 값이 없으면 CP 를 나중에 추가할 수 없다. kubeadm 이 각 CP 의 kubelet.conf 와
# 컴포넌트 kubeconfig 에 자기 IP 를 직접 박아버리기 때문이다.
__CONTROL_PLANE_ENDPOINT__
networking:
  podSubnet: ${POD_CIDR}
  serviceSubnet: ${SERVICE_CIDR}
apiServer:
  certSANs:
    - __NODE_IP__
    - __NODE_NAME__
    - 127.0.0.1
    - localhost
# LB 주소와 다른 CP 들의 이름·IP 가 여기 들어간다. 빠지면 그 주소로 접속할 때
# 인증서 검증이 실패한다. certSAN 은 init 후에 추가하기 번거로우므로
# 처음부터 넉넉히 넣는다.
__EXTRA_CERT_SANS__
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
# containerd 를 SystemdCgroup=true 로 설정하므로 kubelet 도 systemd 로 맞춘다.
# 둘이 어긋나면 kubelet 이 기동 후 파드가 무작위로 재시작된다.
cgroupDriver: systemd
EOF

# worker 조인 설정.
#
# KubeletConfiguration 을 넣지 않는다. kubeadm join 은 클러스터의
# kube-system/kubelet-config ConfigMap 에서 kubelet 설정을 받아오므로
# (cgroupDriver: systemd 포함) 여기서 또 정의하면 출처가 둘로 갈린다.
#
# nodeRegistration.name 을 박아두는 이유: 기본값은 hostname 이지만,
# install.sh 가 소문자로 정규화한 이름을 쓰므로 양쪽을 일치시킨다.
# 대문자가 섞인 호스트명이면 kubelet 이 등록에 실패한다.
# 추가 control plane 조인용. worker 조인과 다른 점은 controlPlane 절이다.
#   localAPIEndpoint : 이 노드의 apiserver 가 listen 할 주소
#   certificateKey   : init 이 --upload-certs 로 올려둔 CA 등을 복호화할 키
#                      kubeadm-certs Secret 은 2시간 뒤 사라진다.
cat > "${CONF_DIR}/kubeadm-cp-join.yaml" <<'EOF'
apiVersion: kubeadm.k8s.io/v1beta4
kind: JoinConfiguration
discovery:
  bootstrapToken:
    apiServerEndpoint: __API_ENDPOINT__
    token: __TOKEN__
    caCertHashes:
      - __CA_CERT_HASH__
controlPlane:
  localAPIEndpoint:
    advertiseAddress: __NODE_IP__
    bindPort: 6443
  certificateKey: __CERT_KEY__
nodeRegistration:
  name: __NODE_NAME__
  criSocket: unix:///run/containerd/containerd.sock
  kubeletExtraArgs:
    - name: node-ip
      value: __NODE_IP__
EOF
ok "kubeadm-cp-join.yaml"

cat > "${CONF_DIR}/kubeadm-join.yaml" <<'EOF'
apiVersion: kubeadm.k8s.io/v1beta4
kind: JoinConfiguration
discovery:
  bootstrapToken:
    apiServerEndpoint: __API_ENDPOINT__
    token: __TOKEN__
    caCertHashes:
      - __CA_CERT_HASH__
nodeRegistration:
  name: __NODE_NAME__
  criSocket: unix:///run/containerd/containerd.sock
  kubeletExtraArgs:
    - name: node-ip
      value: __NODE_IP__
EOF

# 커널 모듈 / sysctl. kubeadm preflight 가 요구하는 항목들이다.
cat > "${CONF_DIR}/k8s-modules.conf" <<'EOF'
overlay
br_netfilter
EOF

cat > "${CONF_DIR}/k8s-sysctl.conf" <<'EOF'
# kubeadm 필수 항목
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

ok "conf 생성 완료"

#=====================================================================
# 6. 번들 자기완결화 + 매니페스트
#=====================================================================
step "번들 패키징"

# 타깃에서 이 저장소 없이도 설치가 되도록 공통 파일과 설치 스크립트를 함께 담는다.
mkdir -p "${BUNDLE_DIR}/00-common"
cp "${SCRIPT_DIR}/../00-common/versions.env" "${BUNDLE_DIR}/00-common/"
# site.env(내부 IP·사내 호스트명)는 git 추적 대상이 아니지만 번들에는 넣는다.
# 에어갭 타깃에서 값을 다시 입력할 필요가 없어야 하고, 번들 자체는 사내 자산이다.
# 없으면 install.sh 가 예시 값으로 돌아 NFS 마운트 등이 실패하므로 경고한다.
if [[ -f "${SCRIPT_DIR}/../00-common/site.env" ]]; then
    cp "${SCRIPT_DIR}/../00-common/site.env" "${BUNDLE_DIR}/00-common/"
else
    cp "${SCRIPT_DIR}/../00-common/site.env.example" "${BUNDLE_DIR}/00-common/"
    warn "site.env 가 없어 예시 값으로 번들을 만든다. 타깃에서 값을 채워야 한다."
fi
cp "${SCRIPT_DIR}/../00-common/common.sh"    "${BUNDLE_DIR}/00-common/"
cp -R "${SCRIPT_DIR}/../00-common/os"       "${BUNDLE_DIR}/00-common/"
cp "${SCRIPT_DIR}/install.sh"                "${BUNDLE_DIR}/"
# 다중 CP 용 apiserver LB 구성 스크립트. haproxy 이미지는 넣지 않는다
# (40-haproxy 번들에 이미 있고 45M 을 중복 보관할 이유가 없다).
cp "${SCRIPT_DIR}/apiserver-lb.sh"           "${BUNDLE_DIR}/"
cp "${SCRIPT_DIR}/README.md"                 "${BUNDLE_DIR}/" 2>/dev/null || true
mkdir -p "${BUNDLE_DIR}/90-verify"
cp "${SCRIPT_DIR}/../90-verify/airgap-on.sh"  "${BUNDLE_DIR}/90-verify/"
cp "${SCRIPT_DIR}/../90-verify/airgap-off.sh" "${BUNDLE_DIR}/90-verify/"
chmod +x "${BUNDLE_DIR}/install.sh" "${BUNDLE_DIR}"/90-verify/*.sh

cat > "${BUNDLE_DIR}/BUNDLE-INFO" <<EOF
bundle        : ${BUNDLE_NAME}
bundle_version: ${BUNDLE_VERSION}
built_at      : $(date -Is)
built_on      : $(hostname) / ${OS_LABEL} / ${BUNDLE_ARCH}
target_os     : ${OS_LABEL} ${BUNDLE_ARCH} 전용
k8s           : ${K8S_VERSION} (${PKG_EXT} ${K8S_PKG_VERSION})
containerd    : ${CONTAINERD_VERSION} (containerd.io ${PKG_EXT}, runc ${RUNC_VERSION} 포함)
docker        : ${DOCKER_VERSION}
helm          : ${HELM_VERSION}
podman        : ${PODMAN_STATIC_VERSION} (static)
${PKG_EXT} 개수      : ${PKG_COUNT}
이미지 개수   : ${#K8S_IMAGES[@]}
EOF

write_manifest "$BUNDLE_DIR"

TARBALL="${SCRIPT_DIR}/bundle/${BUNDLE_NAME}.tar.gz"
log "tar.gz 생성"
tar -C "${SCRIPT_DIR}/bundle" -czf "$TARBALL" "$BUNDLE_NAME"
# `sha256sum -c` 가 읽을 수 있는 형식으로 쓴다. 해시만 남기면
# "no properly formatted checksum lines found" 로 검증 자체가 되지 않는다.
# 경로가 아니라 파일명만 넣어야 타깃에서 같은 디렉터리에 두고 검증할 수 있다.
( cd "$(dirname "$TARBALL")" && sha256sum "$(basename "$TARBALL")" ) > "${TARBALL}.sha256"

step "완료"
cat "${BUNDLE_DIR}/BUNDLE-INFO"
echo
ok "번들 디렉터리: ${BUNDLE_DIR} ($(du -sh "$BUNDLE_DIR" | cut -f1))"
ok "번들 아카이브: ${TARBALL} ($(du -h "$TARBALL" | cut -f1))"
echo
echo "다음: 타깃으로 전송 후 설치"
echo "  scp ${TARBALL}{,.sha256} <타깃>:~/"
echo "  tar xzf ${BUNDLE_NAME}.tar.gz && cd ${BUNDLE_NAME} && sudo ./install.sh"
