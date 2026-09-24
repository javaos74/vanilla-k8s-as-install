#!/usr/bin/env bash
#---------------------------------------------------------------------
# 60-cilium : 오프라인 번들 빌드 (온라인 호스트에서 실행)
#
# 산출물: bundle/cilium-<CILIUM_VERSION>/ + .tar.gz
#
# 이미지 목록을 사람이 관리하지 않는다. helm template 으로 실제 렌더링한 뒤
# 거기서 image 참조를 뽑아낸다. 값(values)에 따라 필요한 이미지가 달라지므로
# 이 방식이 아니면 반드시 누락이 생긴다.
#
# 이 단계는 OS 에 의존하지 않는다(컨테이너 이미지 + 차트 + 정적 바이너리뿐).
# 따라서 22.04 / 24.04 공용 번들이다.
#---------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../00-common/common.sh"

require_online
require_cmds curl tar

BUNDLE_NAME="cilium-${CILIUM_VERSION}"
BUNDLE_DIR="${SCRIPT_DIR}/bundle/${BUNDLE_NAME}"
IMG_DIR="${BUNDLE_DIR}/images"
BIN_DIR="${BUNDLE_DIR}/bin"
CHART_DIR="${BUNDLE_DIR}/chart"
CONF_DIR="${BUNDLE_DIR}/conf"

step "Cilium ${CILIUM_VERSION} 번들 빌드 (OS 공용)"
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

mkdir -p "$IMG_DIR" "$BIN_DIR" "$CHART_DIR" "$CONF_DIR"

#=====================================================================
# 1. 빌드 도구
#=====================================================================
step "빌드 도구 확인"
if ! command -v skopeo >/dev/null 2>&1; then
    log "skopeo 설치"
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq skopeo
fi
ok "skopeo $(skopeo --version | awk '{print $3}')"

# helm 은 차트 렌더링에 필요하다. 번들에도 들어가지만(10-k8s) 빌드 호스트에
# 없을 수 있으니 임시로 내려받아 쓴다.
HELM_BIN="$(command -v helm || true)"
if [[ -z "$HELM_BIN" ]]; then
    log "helm 임시 설치(빌드용)"
    tmp="$(mktemp -d)"
    curl -fsSL "$HELM_URL" | tar -C "$tmp" -xz
    HELM_BIN="${tmp}/linux-${BUNDLE_ARCH}/helm"
    chmod +x "$HELM_BIN"
fi
ok "helm $("$HELM_BIN" version --short)"

#=====================================================================
# 2. 차트 + CLI
#=====================================================================
step "차트 및 cilium-cli"
CHART_TGZ="${CHART_DIR}/cilium-${CILIUM_VERSION}.tgz"
fetch "$CILIUM_CHART_URL" "$CHART_TGZ"
fetch "$CILIUM_CLI_URL"   "${BIN_DIR}/cilium-linux-${BUNDLE_ARCH}.tar.gz"

#=====================================================================
# 3. values.yaml 생성
#=====================================================================
step "values.yaml 생성"

# 결정 사항이 모두 여기 들어간다. 왜 이 값인지는 각 주석 참고.
cat > "${CONF_DIR}/values.yaml" <<EOF
#---------------------------------------------------------------------
# Cilium ${CILIUM_VERSION} — 단일 노드 에어갭용 값
#---------------------------------------------------------------------

# kube-proxy 를 유지한다(eBPF 로 대체하지 않음).
# 대체하려면 kubeadm init 에서 addon/kube-proxy 를 skip 해야 하고
# k8sServiceHost/Port 지정이 필요해 검증이 복잡해진다.
kubeProxyReplacement: "false"

# VXLAN 터널. 기존 운영 클러스터(Flannel VXLAN)와 같은 방식이라
# 네트워크 요구사항(UDP 8472)이 동일하다.
routingMode: tunnel
tunnelProtocol: vxlan

# Pod IP 는 kubeadm 이 노드에 할당한 spec.podCIDR 를 그대로 쓴다.
# (kubeadm-init.yaml 의 podSubnet=${POD_CIDR})
ipam:
  mode: kubernetes

# 단일 노드. 기본값 2 로 두면 operator 파드 하나가 영구 Pending 이 된다.
operator:
  replicas: 1
  image:
    # 에어갭에서는 다이제스트 고정을 끈다. 아래 image.useDigest 주석 참고.
    useDigest: false

image:
  # 중요: 차트 기본값은 useDigest=true 로 quay.io/cilium/cilium:vX@sha256:... 를 쓴다.
  # 번들은 이미지를 docker-archive tar 로 옮기는데, 이 변환 과정에서 매니페스트가
  # 재작성되어 원본 다이제스트가 보존되지 않는다. 그 결과 다이제스트 참조가
  # 로컬에 없는 것으로 판정되어 파드가 ImagePullBackOff 로 떨어진다.
  # 태그 참조로 바꿔야 오프라인에서 동작한다.
  useDigest: false
  pullPolicy: IfNotPresent

# Hubble 은 끈다. 관측성 기능이라 인프라 검증에 필요하지 않고,
# relay/UI 이미지가 늘어나 번들과 메모리 사용이 커진다(검증 호스트 7.8GB).
hubble:
  enabled: false

# Envoy DaemonSet 도 끈다. L7 정책/Ingress 를 쓰지 않으므로 불필요하다.
envoy:
  enabled: false

# 단일 노드에서는 노드 간 암호화가 의미 없다.
encryption:
  enabled: false
EOF
ok "values.yaml 생성"

#=====================================================================
# 4. 렌더링해서 실제 필요한 이미지 목록 추출
#=====================================================================
step "helm template 으로 이미지 목록 추출"

RENDERED="$(mktemp)"
"$HELM_BIN" template cilium "$CHART_TGZ" \
    --namespace kube-system \
    -f "${CONF_DIR}/values.yaml" > "$RENDERED" \
    || die "helm template 실패. values.yaml 을 확인할 것."

# image: 로 시작하는 줄에서 참조만 뽑는다. 따옴표와 공백을 정리한다.
mapfile -t CILIUM_IMAGES < <(
    grep -hoE '^\s*image:\s*"?[^"]+"?$' "$RENDERED" \
    | sed -E 's/^\s*image:\s*//; s/^"//; s/"$//' \
    | grep -vE '^\s*$' | sort -u
)
rm -f "$RENDERED"

((${#CILIUM_IMAGES[@]} > 0)) || die "렌더링 결과에서 이미지를 찾지 못했다"

log "필요한 이미지 ${#CILIUM_IMAGES[@]}개:"
printf '    %s\n' "${CILIUM_IMAGES[@]}"
printf '%s\n' "${CILIUM_IMAGES[@]}" > "${CONF_DIR}/images.list"

# 다이제스트 참조가 남아 있으면 오프라인에서 실패한다. 빌드 단계에서 잡는다.
if printf '%s\n' "${CILIUM_IMAGES[@]}" | grep -q '@sha256:'; then
    printf '%s\n' "${CILIUM_IMAGES[@]}" | grep '@sha256:' | sed 's/^/    /'
    die "다이제스트 참조가 남아 있다. values.yaml 의 useDigest 설정을 보완할 것."
fi
ok "모든 이미지가 태그 참조 (다이제스트 참조 없음)"

#=====================================================================
# 5. 이미지 받기
#=====================================================================
step "이미지 다운로드"
for img in "${CILIUM_IMAGES[@]}"; do
    out="${IMG_DIR}/$(image_to_filename "$img").tar"
    if [[ -s "$out" ]]; then
        log "이미 존재, 건너뜀: $(basename "$out")"
        continue
    fi
    log "이미지 받기: $img"
    skopeo copy --retry-times 5 \
        "docker://${img}" "docker-archive:${out}.part:${img}" >/dev/null \
        || die "이미지 받기 실패: $img"
    mv "${out}.part" "$out"
    ok "$(basename "$out") ($(du -h "$out" | cut -f1))"
done

#=====================================================================
# 6. 패키징
#=====================================================================
step "번들 패키징"

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
cp "${SCRIPT_DIR}/README.md"                 "${BUNDLE_DIR}/" 2>/dev/null || true
chmod +x "${BUNDLE_DIR}/install.sh"

cat > "${BUNDLE_DIR}/BUNDLE-INFO" <<EOF
bundle        : ${BUNDLE_NAME}
bundle_version: ${BUNDLE_VERSION}
built_at      : $(date -Is)
built_on      : $(hostname)
target_os     : Ubuntu 22.04 / 24.04 공용 (OS 의존 없음)
cilium        : ${CILIUM_VERSION}
cilium-cli    : ${CILIUM_CLI_VERSION}
routing       : tunnel / vxlan
kube-proxy    : 유지 (eBPF 대체 안 함)
ipam          : kubernetes (podCIDR ${POD_CIDR})
hubble/envoy  : 비활성
이미지 개수   : ${#CILIUM_IMAGES[@]}
EOF

write_manifest "$BUNDLE_DIR"

TARBALL="${SCRIPT_DIR}/bundle/${BUNDLE_NAME}.tar.gz"
tar -C "${SCRIPT_DIR}/bundle" -czf "$TARBALL" "$BUNDLE_NAME"
# `sha256sum -c` 가 읽을 수 있는 형식으로 쓴다. 해시만 남기면
# "no properly formatted checksum lines found" 로 검증 자체가 되지 않는다.
# 경로가 아니라 파일명만 넣어야 타깃에서 같은 디렉터리에 두고 검증할 수 있다.
( cd "$(dirname "$TARBALL")" && sha256sum "$(basename "$TARBALL")" ) > "${TARBALL}.sha256"

step "완료"
cat "${BUNDLE_DIR}/BUNDLE-INFO"
echo
ok "번들: ${TARBALL} ($(du -h "$TARBALL" | cut -f1))"
