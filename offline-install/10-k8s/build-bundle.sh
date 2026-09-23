#!/usr/bin/env bash
#---------------------------------------------------------------------
# 10-k8s : 오프라인 번들 빌드 (온라인 호스트에서 실행)
#
# 산출물: bundle/k8s-<K8S_VERSION>-<codename>/  + 같은 이름의 .tar.gz
#
# 중요 제약: 빌드 호스트의 OS 는 설치 대상과 같아야 한다.
#   deb 의존성 해석이 "지금 설치돼 있지 않은 것"을 기준으로 이뤄지므로,
#   같은 OS 이미지에서 빌드해야 타깃에 필요한 deb 가 정확히 담긴다.
#   22.04 타깃 번들은 22.04 에서, 24.04 타깃 번들은 24.04 에서 빌드한다.
#
# 이 스크립트가 빌드 호스트에 남기는 변경:
#   - /etc/apt/sources.list.d/{kubernetes,docker}.list 및 keyring 추가
#   - skopeo 설치 (이미지를 tar 로 받기 위한 빌드 도구)
#   위 둘 다 멱등이며 설치 대상 호스트에는 영향이 없다.
#---------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../00-common/common.sh"

ALLOW_DIRTY_HOST=0
while (($#)); do
    case "$1" in
        --allow-dirty-host) ALLOW_DIRTY_HOST=1 ;;
        -h|--help) sed -n '3,12p' "${BASH_SOURCE[0]}" | sed 's/^#//'; exit 0 ;;
        *) die "알 수 없는 인자: $1  (--allow-dirty-host)" ;;
    esac
    shift
done

require_online
require_cmds curl dpkg dpkg-deb tar

CODENAME="$(detect_codename)"
OSVER="$(codename_to_osversion "$CODENAME")"
detect_arch >/dev/null

BUNDLE_NAME="k8s-${K8S_VERSION}-${CODENAME}"
BUNDLE_DIR="${SCRIPT_DIR}/bundle/${BUNDLE_NAME}"
DEB_DIR="${BUNDLE_DIR}/debs"
IMG_DIR="${BUNDLE_DIR}/images"
BIN_DIR="${BUNDLE_DIR}/bin"
CONF_DIR="${BUNDLE_DIR}/conf"

step "빌드 대상: ${CODENAME} (Ubuntu ${OSVER}) / k8s ${K8S_VERSION}"
mkdir -p "$DEB_DIR" "$IMG_DIR" "$BIN_DIR" "$CONF_DIR"

#=====================================================================
# 1. 빌드 호스트에 apt 저장소 등록 (멱등)
#=====================================================================
step "apt 저장소 등록 (빌드 호스트)"

sudo install -d -m 0755 /etc/apt/keyrings

if [[ ! -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg ]]; then
    log "k8s 서명키 등록"
    curl -fsSL "$K8S_APT_KEY_URL" \
        | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
fi
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] ${K8S_APT_REPO}/ /" \
    | sudo tee /etc/apt/sources.list.d/kubernetes.list >/dev/null

if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
    log "docker 서명키 등록"
    curl -fsSL "$DOCKER_APT_KEY_URL" \
        | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
fi
echo "deb [arch=${BUNDLE_ARCH} signed-by=/etc/apt/keyrings/docker.gpg] ${DOCKER_REPO} ${CODENAME} stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

log "apt-get update"
sudo apt-get update -qq

# skopeo: 데몬 없이 레지스트리 -> tar 로 이미지를 받기 위한 빌드 도구.
# docker 데몬을 띄우지 않아도 되므로 빌드 호스트를 덜 오염시킨다.
if ! command -v skopeo >/dev/null 2>&1; then
    log "skopeo 설치(빌드 도구)"
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq skopeo
fi
ok "skopeo $(skopeo --version | awk '{print $3}')"

#=====================================================================
# 2. deb 다운로드
#=====================================================================
step "deb 다운로드"

# 버전을 못 박아 내려받는다. 저장소에 더 새 버전이 생겨도 번들은 고정된다.
# docker-ce / docker-ce-cli 는 apt 버전 문자열에 epoch "5:" 가 붙는다(실측).
DOCKER_SUFFIX="${DOCKER_DEB_REVISION}~ubuntu.${OSVER}~${CODENAME}"
PINNED_DEBS=(
    "kubeadm=${K8S_PKG_VERSION}"
    "kubelet=${K8S_PKG_VERSION}"
    "kubectl=${K8S_PKG_VERSION}"
    "cri-tools=${CRI_TOOLS_PKG_VERSION}"
    "kubernetes-cni=${KUBERNETES_CNI_PKG_VERSION}"
    "containerd.io=${CONTAINERD_VERSION}-${DOCKER_SUFFIX}"
    "docker-ce=${DOCKER_DEB_EPOCH}${DOCKER_VERSION}-${DOCKER_SUFFIX}"
    "docker-ce-cli=${DOCKER_DEB_EPOCH}${DOCKER_VERSION}-${DOCKER_SUFFIX}"
    "docker-buildx-plugin=${DOCKER_BUILDX_VERSION}-${DOCKER_SUFFIX}"
    "docker-compose-plugin=${DOCKER_COMPOSE_VERSION}-${DOCKER_SUFFIX}"
)

# OS 기본 패키지지만 최소 설치 이미지에는 없을 수 있는 것들.
# 이미 빌드 호스트에 설치돼 있어도 apt-get download 는 항상 받아온다.
OS_DEPS=(
    conntrack socat ebtables ethtool iptables iproute2 kmod
    nfs-common          # 50-nfs-csi 단계에서 필요
    nftables            # 90-verify 에어갭 전환에 필요
)

# apt-get download 는 인자 중 하나라도 해석에 실패하면 전체를 중단한다.
# 그래서 패키지별로 호출하고 실패 목록을 모아 한 번에 보고한다.
download_debs() {
    local label="$1"; shift
    local -a failed=()
    log "${label} (${#@}개)"
    for spec in "$@"; do
        if ! ( cd "$DEB_DIR" && apt-get download "$spec" >/dev/null 2>&1 ); then
            failed+=("$spec")
        fi
    done
    if ((${#failed[@]} > 0)); then
        for f in "${failed[@]}"; do
            warn "다운로드 실패: ${f}  (apt-cache madison ${f%%=*} 로 실제 버전 확인)"
        done
        return 1
    fi
    ok "${label} 완료"
}

download_debs "고정 버전 패키지" "${PINNED_DEBS[@]}" \
    || die "고정 버전 패키지를 받지 못했다. versions.env 의 버전 핀을 확인할 것."
download_debs "OS 의존 패키지" "${OS_DEPS[@]}" \
    || warn "일부 OS 패키지를 받지 못했다. 타깃에 이미 설치돼 있으면 문제되지 않는다."

#---------------------------------------------------------------------
# 빌드 호스트는 **깨끗해야** 한다
#
# 아래 `apt-get install --download-only --reinstall` 은 명시한 패키지는 다시
# 받지만, **이미 설치된 전이 의존성은 받지 않는다**(apt 가 충족된 것으로 본다).
# 그래서 k8s/docker 가 이미 설치된 호스트에서 빌드하면 번들에 구멍이 생긴다.
#
# 실측: CP 로 쓰던 노드에서 다시 빌드했더니 deb 가 23개 -> 19개로 줄었다.
#   docker-ce-rootless-extras / libnfsidmap1 / pigz / rpcbind 누락
# 이 번들로 깨끗한 타깃에 설치하면 dpkg 의존성 오류가 난다.
#
# 폐쇄집합을 직접 계산해 채우는 방법은 쓰지 않는다. libc6 같은 기반 패키지까지
# 끌어와 타깃에서 dpkg -i 로 기반 라이브러리를 바꿔버릴 위험이 있다.
# 대신 오염을 감지해 멈춘다. --allow-dirty-host 로 넘길 수 있지만 권장하지 않는다.
#---------------------------------------------------------------------
DIRTY=()
for _p in kubelet kubeadm kubectl containerd.io docker-ce nfs-common; do
    if dpkg -s "$_p" >/dev/null 2>&1; then DIRTY+=("$_p"); fi
done
if ((${#DIRTY[@]} > 0)); then
    warn "빌드 호스트에 이미 설치된 대상 패키지가 있다: ${DIRTY[*]}"
    warn "이 상태로 빌드하면 **전이 의존성이 누락된 불완전한 번들**이 된다."
    if ((ALLOW_DIRTY_HOST)); then
        warn "--allow-dirty-host 가 지정돼 계속한다. 번들 완전성을 직접 확인할 것."
    else
        die "$(cat <<'MSG'
깨끗한 호스트에서 빌드할 것. 설치 대상과 같은 OS 의 새 VM 이면 된다.

이 검사가 있는 이유:
  apt 는 이미 설치된 의존성을 다시 내려받지 않는다. 그래서 설치가 끝난
  노드에서 번들을 만들면 그 노드에 이미 있는 패키지만큼 번들에 구멍이 생기고,
  깨끗한 타깃에서 dpkg 의존성 오류로 드러난다.

정말 이 호스트에서 만들어야 한다면:
  ./build-bundle.sh --allow-dirty-host
MSG
)"
    fi
fi

# 위에서 받지 못한 추가 의존성을 apt 가 계산해 채운다.
# (예: docker-ce 가 요구하는 libslirp / pigz 등 OS 버전마다 다르다)
log "잔여 의존성 계산 및 다운로드"
mkdir -p "${DEB_DIR}/partial"
sudo apt-get install -y --download-only --reinstall \
     -o Dir::Cache::archives="${DEB_DIR}" \
     "${PINNED_DEBS[@]}" "${OS_DEPS[@]}" >/dev/null 2>&1 || \
  warn "일부 의존성 다운로드를 건너뜀(이미 최신이거나 충돌). 설치 단계에서 확인된다."
sudo chown -R "$(id -u):$(id -g)" "$DEB_DIR" 2>/dev/null || true
rm -rf "${DEB_DIR}/partial" "${DEB_DIR}/lock"

DEB_COUNT="$(find "$DEB_DIR" -name '*.deb' | wc -l)"
# 깨끗한 24.04 에서 23개였다(실측). 크게 적으면 빌드 호스트 오염을 의심할 것.
if (( DEB_COUNT < 20 )); then
    warn "deb 가 ${DEB_COUNT}개뿐이다. 깨끗한 호스트에서는 23개 내외였다."
    warn "빌드 호스트 오염으로 전이 의존성이 누락됐을 수 있다."
fi
[[ "$DEB_COUNT" -gt 0 ]] || die "deb 를 하나도 받지 못했다"
ok "deb ${DEB_COUNT}개 ($(du -sh "$DEB_DIR" | cut -f1))"

#=====================================================================
# 3. k8s 컨트롤 플레인 이미지
#=====================================================================
step "k8s 이미지 목록 확인 및 다운로드"

# kubeadm 을 설치하지 않고 deb 에서 바이너리만 꺼내 쓴다.
# 빌드 호스트를 오염시키지 않으면서 정확한 이미지 목록을 얻는 방법이다.
KUBEADM_EXTRACT="$(mktemp -d)"
trap 'rm -rf "$KUBEADM_EXTRACT"' EXIT
dpkg-deb -x "$(ls "$DEB_DIR"/kubeadm_*.deb | head -1)" "$KUBEADM_EXTRACT"
KUBEADM_BIN="${KUBEADM_EXTRACT}/usr/bin/kubeadm"
[[ -x "$KUBEADM_BIN" ]] || die "deb 에서 kubeadm 바이너리를 찾지 못했다"

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
built_on      : $(hostname) / Ubuntu ${OSVER} (${CODENAME}) / ${BUNDLE_ARCH}
target_os     : Ubuntu ${OSVER} (${CODENAME}) ${BUNDLE_ARCH} 전용
k8s           : ${K8S_VERSION} (deb ${K8S_PKG_VERSION})
containerd    : ${CONTAINERD_VERSION} (containerd.io deb, runc ${RUNC_VERSION} 포함)
docker        : ${DOCKER_VERSION}
helm          : ${HELM_VERSION}
podman        : ${PODMAN_STATIC_VERSION} (static)
deb 개수      : ${DEB_COUNT}
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
