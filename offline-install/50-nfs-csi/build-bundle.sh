#!/usr/bin/env bash
#---------------------------------------------------------------------
# 50-nfs-csi : 오프라인 번들 빌드 (온라인 호스트에서 실행)
#
# 산출물: bundle/nfs-csi-<CSI_DRIVER_NFS_VERSION>/ + .tar.gz
#
# 구성:
#   - external-snapshotter v8.6.0 : CRD + snapshot-controller
#   - csi-driver-nfs      v4.13.4 : 드라이버(controller/node/driverinfo/rbac)
#   - 생성물                      : StorageClass 2종 + VolumeSnapshotClass
#
# 왜 snapshot-controller 출처를 분리하는가:
#   csi-driver-nfs 의 deploy/ 에도 csi-snapshot-controller.yaml 이 들어 있는데
#   그쪽은 snapshot-controller:v8.4.0 을 참조한다. external-snapshotter v8.6.0 의
#   deploy 는 v8.5.0 을 참조한다. 둘을 다 적용하면 컨트롤러가 중복 배치되고
#   이미지도 두 버전을 받아야 한다. 그래서 스냅샷 쪽은 external-snapshotter 것만
#   쓰고, csi-driver-nfs 에서는 스냅샷 관련 파일을 제외한다.
#
# OS 에 의존하지 않는다(이미지 + 매니페스트뿐). 22.04 / 24.04 공용.
# 노드에 필요한 nfs-common deb 는 10-k8s 번들에 이미 포함돼 있다.
#---------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../00-common/common.sh"

require_online
require_cmds curl tar

BUNDLE_NAME="nfs-csi-${CSI_DRIVER_NFS_VERSION}"
BUNDLE_DIR="${SCRIPT_DIR}/bundle/${BUNDLE_NAME}"
IMG_DIR="${BUNDLE_DIR}/images"
MAN_DIR="${BUNDLE_DIR}/manifests"
CONF_DIR="${BUNDLE_DIR}/conf"
SRC_DIR="${SCRIPT_DIR}/.src"

step "NFS CSI 번들 빌드 (csi-driver-nfs ${CSI_DRIVER_NFS_VERSION} / external-snapshotter ${EXTERNAL_SNAPSHOTTER_VERSION})"
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

mkdir -p "$IMG_DIR" "$MAN_DIR" "$CONF_DIR" "$SRC_DIR"

if ! command -v skopeo >/dev/null 2>&1; then
    log "skopeo 설치(빌드 도구)"
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq skopeo
fi
ok "skopeo $(skopeo --version | awk '{print $3}')"

#=====================================================================
# 1. 소스 내려받기
#=====================================================================
step "소스 tarball"
fetch "$CSI_DRIVER_NFS_SRC_URL"       "${SRC_DIR}/csi-driver-nfs-${CSI_DRIVER_NFS_VERSION}.tar.gz"
fetch "$EXTERNAL_SNAPSHOTTER_SRC_URL" "${SRC_DIR}/external-snapshotter-${EXTERNAL_SNAPSHOTTER_VERSION}.tar.gz"

EXTRACT="$(mktemp -d)"
trap 'rm -rf "$EXTRACT"' EXIT
tar -C "$EXTRACT" -xzf "${SRC_DIR}/csi-driver-nfs-${CSI_DRIVER_NFS_VERSION}.tar.gz"
tar -C "$EXTRACT" -xzf "${SRC_DIR}/external-snapshotter-${EXTERNAL_SNAPSHOTTER_VERSION}.tar.gz"

NFS_SRC="${EXTRACT}/csi-driver-nfs-${CSI_DRIVER_NFS_VERSION#v}"
SNAP_SRC="${EXTRACT}/external-snapshotter-${EXTERNAL_SNAPSHOTTER_VERSION#v}"
[[ -d "${NFS_SRC}/deploy" ]]  || die "csi-driver-nfs deploy 디렉터리를 찾지 못했다: ${NFS_SRC}"
[[ -d "${SNAP_SRC}/client/config/crd" ]] || die "external-snapshotter CRD 디렉터리를 찾지 못했다"

#=====================================================================
# 2. 매니페스트 조립 (적용 순서를 파일명 번호로 고정)
#=====================================================================
step "매니페스트 조립"

# kubectl apply -f <dir> 는 파일명 알파벳 순으로 적용한다.
# CRD 가 VolumeSnapshotClass 보다 먼저 생성돼야 하므로 번호를 붙인다.

#--- 10: 스냅샷 CRD ---------------------------------------------------
for f in "${SNAP_SRC}"/client/config/crd/snapshot.storage.k8s.io_*.yaml; do
    cp "$f" "${MAN_DIR}/10-crd-$(basename "$f")"
done
# VolumeGroupSnapshot 계열 CRD 도 넣는다. 컨트롤러가 이 CRD 를 watch 하므로
# 없으면 로그에 지속적으로 오류가 남는다(기능은 쓰지 않아도 CRD 는 필요).
for f in "${SNAP_SRC}"/client/config/crd/groupsnapshot.storage.k8s.io_*.yaml; do
    [[ -f "$f" ]] && cp "$f" "${MAN_DIR}/10-crd-$(basename "$f")"
done
ok "CRD $(ls "${MAN_DIR}"/10-crd-* | wc -l)개"

#--- 20: snapshot-controller (external-snapshotter) -------------------
cp "${SNAP_SRC}/deploy/kubernetes/snapshot-controller/rbac-snapshot-controller.yaml" \
   "${MAN_DIR}/20-rbac-snapshot-controller.yaml"
cp "${SNAP_SRC}/deploy/kubernetes/snapshot-controller/setup-snapshot-controller.yaml" \
   "${MAN_DIR}/21-setup-snapshot-controller.yaml"

# 단일 노드이므로 replicas 를 1 로 내린다. 기본 2 면 하나가 영구 Pending 이다.
sed -i -E 's/^(\s*)replicas:\s*[0-9]+/\1replicas: 1/' "${MAN_DIR}/21-setup-snapshot-controller.yaml"
ok "snapshot-controller (replicas=1)"

#--- 30: csi-driver-nfs ------------------------------------------------
# 아래 파일들은 제외한다.
#   csi-snapshot-controller.yaml / rbac-snapshot-controller.yaml
#       -> 스냅샷 컨트롤러는 external-snapshotter 것만 쓴다(위 20/21). 넣으면 중복 배치.
#   crd-csi-snapshot.yaml
#       -> volumesnapshots / volumesnapshotclasses / volumesnapshotcontents 3종을
#          다시 정의한다(실측 확인). 10-crd-* 뒤에 적용되면 external-snapshotter
#          v8.6.0 CRD 를 csi-driver-nfs 쪽 사본으로 덮어써 버린다.
#          스냅샷 CRD 의 authority 는 external-snapshotter 로 통일한다.
#   storageclass.yaml / snapshotclass.yaml
#       -> 예시 파일이다. 우리 환경 값으로 새로 만든다(40/41).
for f in "${NFS_SRC}"/deploy/*.yaml; do
    b="$(basename "$f")"
    case "$b" in
        csi-snapshot-controller.yaml|rbac-snapshot-controller.yaml) continue ;;
        crd-csi-snapshot.yaml)                                      continue ;;
        storageclass*.yaml|snapshotclass*.yaml)                     continue ;;
    esac
    cp "$f" "${MAN_DIR}/30-${b}"
done
ok "csi-driver-nfs 매니페스트 $(ls "${MAN_DIR}"/30-* | wc -l)개"

# 스냅샷 CRD 가 두 곳에서 정의되지 않았는지 확인한다.
DUP_CRD="$(grep -l 'volumesnapshots.snapshot.storage.k8s.io' "${MAN_DIR}"/*.yaml 2>/dev/null | wc -l)"
[[ "$DUP_CRD" -le 1 ]] || die "volumesnapshots CRD 를 정의하는 파일이 ${DUP_CRD}개다. 중복을 제거할 것."
ok "스냅샷 CRD 중복 없음"

#--- 40: StorageClass / VolumeSnapshotClass (우리 환경 값) -------------
cat > "${MAN_DIR}/40-storageclass.yaml" <<EOF
#---------------------------------------------------------------------
# StorageClass 2종
#   nfs-csi        : 기본 클래스. PVC 삭제 시 데이터도 삭제(Delete)
#   nfs-csi-retain : PVC 삭제 후에도 데이터 보존(Retain)
#
# mountOptions 에 noresvport 를 넣지 말 것.
#   서버 export 에 insecure 가 없으면 비특권 포트 마운트를 거부해
#   mount.nfs: Operation not permitted (exit 32) 로 PVC 가 Pending 이 된다.
#   mountOptions 는 불변 필드라 나중에 고치려면 SC 를 삭제·재생성해야 한다.
#   (setup-nfs-server.sh 는 서버에 insecure 를 넣어 이중으로 방어한다)
#
# allowVolumeExpansion 은 true 지만 NFS 는 실제 용량 쿼터를 적용하지 않는다.
# PVC 의 용량 값은 사실상 라벨이다.
#---------------------------------------------------------------------
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: nfs-csi
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: nfs.csi.k8s.io
parameters:
  server: ${NFS_SERVER_HOST}
  share: ${NFS_EXPORT_PATH}
  # 0777 은 넓다. 워크로드의 fsGroup 이 정해지면 0770 등으로 좁힐 것.
  mountPermissions: "0777"
reclaimPolicy: Delete
volumeBindingMode: Immediate
allowVolumeExpansion: true
mountOptions:
$(printf '  - %s\n' ${NFS_MOUNT_OPTIONS//,/ })
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: nfs-csi-retain
provisioner: nfs.csi.k8s.io
parameters:
  server: ${NFS_SERVER_HOST}
  share: ${NFS_EXPORT_PATH}
  mountPermissions: "0777"
reclaimPolicy: Retain
volumeBindingMode: Immediate
allowVolumeExpansion: true
mountOptions:
$(printf '  - %s\n' ${NFS_MOUNT_OPTIONS//,/ })
EOF

cat > "${MAN_DIR}/41-snapshotclass.yaml" <<EOF
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshotClass
metadata:
  name: csi-nfs-snapclass
driver: nfs.csi.k8s.io
deletionPolicy: Delete
EOF
ok "StorageClass 2종 + VolumeSnapshotClass"

#=====================================================================
# 3. 이미지 목록 추출 (실제 적용할 매니페스트에서만)
#=====================================================================
step "이미지 목록 추출"

mapfile -t CSI_IMAGES < <(
    grep -rhoE '^\s*image:\s*"?[^"]+"?\s*$' "$MAN_DIR" \
    | sed -E 's/^\s*image:\s*//; s/^"//; s/"\s*$//; s/\s+$//' \
    | grep -vE '^\s*$' | sort -u
)
((${#CSI_IMAGES[@]} > 0)) || die "매니페스트에서 이미지를 찾지 못했다"

log "필요한 이미지 ${#CSI_IMAGES[@]}개:"
printf '    %s\n' "${CSI_IMAGES[@]}"
printf '%s\n' "${CSI_IMAGES[@]}" > "${CONF_DIR}/images.list"

if printf '%s\n' "${CSI_IMAGES[@]}" | grep -q '@sha256:'; then
    die "다이제스트 참조가 있다. docker-archive 변환에서 보존되지 않으므로 태그로 바꿔야 한다."
fi

#=====================================================================
# 4. 이미지 받기
#=====================================================================
step "이미지 다운로드"
for img in "${CSI_IMAGES[@]}"; do
    out="${IMG_DIR}/$(image_to_filename "$img").tar"
    [[ -s "$out" ]] && { log "이미 존재: $(basename "$out")"; continue; }
    log "이미지 받기: $img"
    skopeo copy --retry-times 5 "docker://${img}" "docker-archive:${out}.part:${img}" >/dev/null \
        || die "이미지 받기 실패: $img"
    mv "${out}.part" "$out"
    ok "$(basename "$out") ($(du -h "$out" | cut -f1))"
done

#=====================================================================
# 5. 패키징
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
cp "${SCRIPT_DIR}/setup-nfs-server.sh"       "${BUNDLE_DIR}/"
cp "${SCRIPT_DIR}/README.md"                 "${BUNDLE_DIR}/" 2>/dev/null || true
chmod +x "${BUNDLE_DIR}/install.sh" "${BUNDLE_DIR}/setup-nfs-server.sh"

cat > "${BUNDLE_DIR}/BUNDLE-INFO" <<EOF
bundle           : ${BUNDLE_NAME}
bundle_version   : ${BUNDLE_VERSION}
built_at         : $(date -Is)
built_on         : $(hostname)
target_os        : Ubuntu 22.04 / 24.04 공용 (OS 의존 없음)
csi-driver-nfs   : ${CSI_DRIVER_NFS_VERSION}
ext-snapshotter  : ${EXTERNAL_SNAPSHOTTER_VERSION}
NFS 서버         : ${NFS_SERVER_HOST}:${NFS_EXPORT_PATH}
mountOptions     : ${NFS_MOUNT_OPTIONS}
StorageClass     : nfs-csi(기본,Delete) / nfs-csi-retain(Retain)
매니페스트 개수  : $(ls "$MAN_DIR" | wc -l)
이미지 개수      : ${#CSI_IMAGES[@]}
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
