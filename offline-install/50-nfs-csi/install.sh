#!/usr/bin/env bash
#---------------------------------------------------------------------
# 50-nfs-csi : 오프라인 설치 (에어갭 k8s 노드에서 root 로 실행)
#
#   # control plane (기본값) — 드라이버·컨트롤러·StorageClass 를 배포한다
#   sudo ./install.sh                 # 설치 + PVC 실제 쓰기 검증
#   sudo ./install.sh --check-only    # 판정만
#   sudo ./install.sh --uninstall     # 제거
#
#   # worker — nfs-common + 이미지만 준비한다
#   sudo ./install.sh --role worker
#   sudo ./install.sh --role worker --check-only
#
# 왜 worker 에서는 매니페스트를 적용하지 않는가:
#   csi-nfs-node 는 DaemonSet 이고 StorageClass 는 클러스터 자원이다. control
#   plane 에서 한 번 적용하면 조인한 노드에 자동으로 확장된다. worker 에 필요한
#   것은 두 가지뿐이다.
#     1) nfs-common : 노드 커널이 NFS 를 마운트할 수 있어야 한다. 없으면 PVC 는
#                     Bound 인데 파드가 ContainerCreating 에서 멈춘다.
#     2) 이미지     : 에어갭이므로 받아올 수 없다. 없으면 csi-nfs-node 파드가
#                     ImagePullBackOff 가 되고 그 노드에서는 NFS 볼륨을 쓸 수 없다.
#
# 전제: 10-k8s + 60-cilium 설치 완료(노드 Ready), NFS 서버 구성 완료.
#       NFS 서버는 이 스크립트가 아니라 setup-nfs-server.sh 로 별도 구성한다.
#---------------------------------------------------------------------
BUNDLE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${BUNDLE_ROOT}/00-common/common.sh"

MODE="install"
ROLE=""

while (($#)); do
    case "$1" in
        --check-only) MODE="check" ;;
        --uninstall)  MODE="uninstall" ;;
        --role)       ROLE="${2:?--role 에 값이 없다 (control-plane | worker)}"; shift ;;
        *)            die "알 수 없는 인자: $1 (--check-only | --uninstall | --role)" ;;
    esac
    shift
done

require_root

if [[ -z "$ROLE" ]]; then
    if   [[ -f /etc/kubernetes/admin.conf ]];   then ROLE="control-plane"
    elif [[ -f /etc/kubernetes/kubelet.conf ]]; then ROLE="worker"; log "역할 자동 판별: worker"
    else ROLE="control-plane"
    fi
fi
[[ "$ROLE" == "control-plane" || "$ROLE" == "worker" ]] \
    || die "--role 값이 잘못됐다: ${ROLE} (control-plane | worker)"

export KUBECONFIG=/etc/kubernetes/admin.conf
NODE_NAME="$(hostname | tr '[:upper:]' '[:lower:]')"

IMG_DIR="${BUNDLE_ROOT}/images"
MAN_DIR="${BUNDLE_ROOT}/manifests"
CONF_DIR="${BUNDLE_ROOT}/conf"

#=====================================================================
# nfs-common 설치 (두 역할 공통)
#
# 10-k8s 번들 안에 nfs-common deb 가 들어 있다. 번들을 푼 위치가 사람마다
# 다르므로 흔한 경로를 훑는다.
#=====================================================================
ensure_nfs_common() {
    if dpkg -s nfs-common >/dev/null 2>&1; then
        ok "nfs-common 이미 설치됨"
        return 0
    fi
    local deb
    deb="$(ls /root/k8s-*/debs/nfs-common_*.deb \
              /root/deploy*/k8s-*/debs/nfs-common_*.deb \
              /home/*/k8s-*/debs/nfs-common_*.deb \
              /home/*/deploy*/k8s-*/debs/nfs-common_*.deb \
              "${BUNDLE_ROOT}"/debs/nfs-common_*.deb 2>/dev/null | head -1)"
    [[ -n "$deb" ]] || die "nfs-common 이 없다. 10-k8s 번들의 debs/nfs-common_*.deb 를 설치할 것."
    dpkg -i "$deb" >/dev/null || die "nfs-common 설치 실패"
    ok "nfs-common 설치 ($(basename "$deb"))"
}

#=====================================================================
# 판정 — worker
#=====================================================================
run_worker_checks() {
    step "설치 상태 판정 (역할: worker)"

    local KC=/etc/kubernetes/kubelet.conf
    local -a _miss=()
    local img

    check "조인 완료(kubelet.conf 존재)" test -f "$KC"
    check "nfs-common 설치됨"            dpkg -s nfs-common
    check "mount.nfs4 존재"              test -x /sbin/mount.nfs4
    check "NFS 서버 ${NFS_SERVER_HOST} export 조회" \
        bash -c "showmount -e ${NFS_SERVER_HOST} | grep -q '${NFS_EXPORT_PATH}'"

    mapfile -t _miss < <(ctr_missing_images "${CONF_DIR}/images.list")
    for img in "${_miss[@]}"; do warn "이미지 없음: $img"; done
    check "CSI 이미지 적재(k8s.io 네임스페이스)" test "${#_miss[@]}" -eq 0

    # 노드에서 export 에 직접 쓰기. 이 노드에 스케줄된 파드가 볼륨을 쓸 수 있는지를
    # 가장 빠르게 확인하는 방법이다(파드·이미지 없이 커널 마운트만으로 판정).
    local mp; mp="$(mktemp -d)"
    if mount -t nfs4 -o "$NFS_MOUNT_OPTIONS" \
             "${NFS_SERVER_HOST}:${NFS_EXPORT_PATH}" "$mp" 2>/dev/null; then
        check "NFS export 에 쓰기/읽기 가능" bash -c "
            f='${mp}/.write-test-\$\$'; echo ok > \"\$f\" && grep -q ok \"\$f\" && rm -f \"\$f\""
        umount "$mp" 2>/dev/null || warn "언마운트 실패(수동 확인 필요): $mp"
    else
        warn "노드에서 export 직접 마운트 실패. 쓰기 검증을 건너뛴다."
    fi
    rmdir "$mp" 2>/dev/null || true

    check_summary
}

#=====================================================================
# 판정 — control plane
#=====================================================================
run_checks() {
    step "설치 상태 판정 (역할: control-plane)"

    check "nfs-common 설치됨(노드 마운트용)" dpkg -s nfs-common
    check "mount.nfs4 존재"                  test -x /sbin/mount.nfs4

    # 노드에서 NFS 서버에 직접 도달하는지. 여기서 실패하면 CSI 도 실패한다.
    check "NFS 서버 ${NFS_SERVER_HOST} export 조회" \
        bash -c "showmount -e ${NFS_SERVER_HOST} | grep -q '${NFS_EXPORT_PATH}'"

    check "CSIDriver nfs.csi.k8s.io 등록" \
        bash -c "kubectl get csidriver nfs.csi.k8s.io >/dev/null 2>&1"
    check "csi-nfs-controller Available" retry_until 180 bash -c '
        kubectl -n kube-system get deploy csi-nfs-controller \
            -o jsonpath="{.status.availableReplicas}" 2>/dev/null | grep -qE "^[1-9]"'
    check "csi-nfs-node DaemonSet Ready" retry_until 180 bash -c '
        d=$(kubectl -n kube-system get ds csi-nfs-node -o jsonpath="{.status.desiredNumberScheduled}" 2>/dev/null)
        r=$(kubectl -n kube-system get ds csi-nfs-node -o jsonpath="{.status.numberReady}" 2>/dev/null)
        [[ -n "$d" && "$d" != "0" && "$d" == "$r" ]]'
    check "snapshot-controller Available" retry_until 180 bash -c '
        kubectl -n kube-system get deploy snapshot-controller \
            -o jsonpath="{.status.availableReplicas}" 2>/dev/null | grep -qE "^[1-9]"'

    check "VolumeSnapshot CRD 등록" \
        bash -c "kubectl get crd volumesnapshots.snapshot.storage.k8s.io >/dev/null 2>&1"
    check "StorageClass nfs-csi 가 기본 클래스" bash -c '
        kubectl get sc nfs-csi -o jsonpath="{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}" \
            2>/dev/null | grep -q true'
    check "StorageClass nfs-csi-retain 존재" bash -c "kubectl get sc nfs-csi-retain >/dev/null 2>&1"
    check "VolumeSnapshotClass csi-nfs-snapclass 존재" \
        bash -c "kubectl get volumesnapshotclass csi-nfs-snapclass >/dev/null 2>&1"

    # mountOptions 에 noresvport 가 섞여 있으면 PVC 가 Pending 이 된다.
    # 설정 단계에서 걸러내기 위한 항목이다.
    check "mountOptions 에 noresvport 없음" bash -c '
        ! kubectl get sc nfs-csi -o jsonpath="{.mountOptions[*]}" 2>/dev/null | grep -q noresvport'

    #--- 실제 동작 검증: PVC 생성 -> 파드에서 쓰기 -> 서버에 파일 생성 확인 ---
    step "PVC 실제 쓰기 검증"
    local ns="nfs-csi-smoke"
    kubectl delete ns "$ns" --ignore-not-found --wait=true --timeout=90s >/dev/null 2>&1 || true
    kubectl create ns "$ns" >/dev/null 2>&1

    cat <<'YAML' | sed "s/__NS__/${ns}/" | kubectl apply -f - >/dev/null 2>&1
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: smoke-pvc
  namespace: __NS__
spec:
  accessModes: [ReadWriteMany]
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: smoke-writer
  namespace: __NS__
spec:
  restartPolicy: Never
  containers:
    - name: w
      image: registry.k8s.io/pause:3.10.2
      volumeMounts:
        - { name: v, mountPath: /data }
  volumes:
    - name: v
      persistentVolumeClaim:
        claimName: smoke-pvc
YAML

    check "PVC Bound" retry_until 180 bash -c "
        kubectl -n ${ns} get pvc smoke-pvc -o jsonpath='{.status.phase}' 2>/dev/null | grep -q Bound"
    check "파드가 NFS 볼륨 마운트 후 Running" retry_until 180 bash -c "
        kubectl -n ${ns} get pod smoke-writer -o jsonpath='{.status.phase}' 2>/dev/null | grep -q Running"

    local pv="" sub=""
    if kubectl -n "$ns" get pvc smoke-pvc >/dev/null 2>&1; then
        pv="$(kubectl -n "$ns" get pvc smoke-pvc -o jsonpath='{.spec.volumeName}' 2>/dev/null)"
        # csi-driver-nfs 가 기록하는 키는 소문자 subdir 이다(v4.13.4 실측).
        # 카멜케이스 subDir 로 읽으면 항상 빈 값이 나온다.
        sub="$(kubectl get pv "$pv" -o jsonpath='{.spec.csi.volumeAttributes.subdir}' 2>/dev/null)"
        log "PV=${pv:-없음}  서버 하위 디렉터리=${sub:-확인불가}"
        log "  서버에서 확인: ls -la ${NFS_EXPORT_PATH}/${sub:-}"
    fi

    #--- 노드에서 export 에 직접 쓰기 ------------------------------------
    # 위 파드는 pause 이미지라 아무것도 쓰지 않는다. 즉 "마운트가 성립한다"까지만
    # 증명한다. 쓰기 권한과 프로비저너 산출물은 노드에서 직접 마운트해 확인한다.
    # nfs-common 이 이미 있으므로 추가 이미지가 필요하지 않다.
    local mp; mp="$(mktemp -d)"
    if mount -t nfs4 -o "$NFS_MOUNT_OPTIONS" \
             "${NFS_SERVER_HOST}:${NFS_EXPORT_PATH}" "$mp" 2>/dev/null; then
        check "NFS export 에 쓰기/읽기 가능" bash -c "
            f='${mp}/.write-test-\$\$'; echo ok > \"\$f\" && grep -q ok \"\$f\" && rm -f \"\$f\""
        if [[ -n "$sub" ]]; then
            check "프로비저너가 만든 ${sub} 가 서버에 존재" test -d "${mp}/${sub}"
        fi
        umount "$mp" 2>/dev/null || warn "언마운트 실패(수동 확인 필요): $mp"
    else
        warn "노드에서 export 직접 마운트 실패. 쓰기 검증을 건너뛴다."
    fi
    rmdir "$mp" 2>/dev/null || true

    # 정리. 실패해도 판정 결과에는 영향을 주지 않는다.
    kubectl delete ns "$ns" --ignore-not-found --wait=false >/dev/null 2>&1 || true

    check_summary
}

do_uninstall() {
    step "NFS CSI 제거"
    kubectl delete -f "$MAN_DIR" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    ok "제거 요청 완료. PV 가 남아 있으면 수동 확인할 것: kubectl get pv"
    exit 0
}

[[ "$MODE" == "uninstall" ]] && do_uninstall
if [[ "$MODE" == "check" ]]; then
    if [[ "$ROLE" == "worker" ]]; then run_worker_checks; else run_checks; fi
    exit $?
fi

#=====================================================================
# worker: nfs-common + 이미지만 준비한다
#=====================================================================
if [[ "$ROLE" == "worker" ]]; then
    step "사전 확인 (worker)"
    verify_manifest "$BUNDLE_ROOT"
    is_online && warn "인터넷 연결 상태다. 오프라인 검증이라면 airgap-on.sh 를 먼저 실행할 것." \
              || ok "인터넷 차단 상태 (에어갭 검증 조건 충족)"
    require_cmds ctr
    [[ -f /etc/kubernetes/kubelet.conf ]] \
        || die "조인되지 않은 노드다. 10-k8s 를 --role worker 로 먼저 실행할 것."
    ok "조인 상태 확인 (kubelet.conf)"

    step "nfs-common 확인"
    ensure_nfs_common
    showmount -e "$NFS_SERVER_HOST" >/dev/null 2>&1 \
        || die "NFS 서버 ${NFS_SERVER_HOST} 에 도달할 수 없다. 방화벽과 export 를 확인할 것."
    ok "NFS export 확인: $(showmount -e "$NFS_SERVER_HOST" | tail -n +2 | tr '\n' ' ')"

    step "이미지 적재 (k8s.io 네임스페이스)"
    shopt -s nullglob
    for tar in "${IMG_DIR}"/*.tar; do ctr_import "$tar"; done
    shopt -u nullglob

    MISSING=()
    mapfile -t MISSING < <(ctr_missing_images "${CONF_DIR}/images.list")
    ((${#MISSING[@]} == 0)) || die "적재되지 않은 이미지: ${MISSING[*]}"
    ok "이미지 $(wc -l < "${CONF_DIR}/images.list")개 적재 확인"

    run_worker_checks
    rc=$?

    step "다음 단계"
    echo "  control plane 에서 이 노드의 csi-nfs-node 파드를 확인할 것:"
    echo "    kubectl -n kube-system get pods -o wide -l app=csi-nfs-node"
    echo "  이 노드에 PVC 파드를 강제로 띄워 검증하려면:"
    echo "    kubectl run ... --overrides '{\"spec\":{\"nodeName\":\"${NODE_NAME}\"}}'"
    echo
    echo "  재판정: sudo ./install.sh --role worker --check-only"
    exit $rc
fi

#=====================================================================
# 0. 사전 확인
#=====================================================================
step "사전 확인"
verify_manifest "$BUNDLE_ROOT"

is_online && warn "인터넷 연결 상태다. 오프라인 검증이라면 airgap-on.sh 를 먼저 실행할 것." \
          || ok "인터넷 차단 상태 (에어갭 검증 조건 충족)"

require_cmds kubectl ctr
[[ -f /etc/kubernetes/admin.conf ]] || die "10-k8s 가 먼저 설치돼야 한다"

# CNI 가 없으면 CSI 파드가 스케줄되지 않는다. 먼저 걸러낸다.
kubectl get nodes -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' \
    | grep -q True || die "노드가 Ready 가 아니다. 60-cilium 을 먼저 설치할 것."
ok "노드 Ready 확인"

#=====================================================================
# 1. nfs-common (노드 마운트에 필요)
#=====================================================================
step "nfs-common 확인"
ensure_nfs_common

# NFS 서버 도달을 먼저 확인한다. 여기서 막히면 뒤 단계가 모두 무의미하다.
showmount -e "$NFS_SERVER_HOST" >/dev/null 2>&1 \
    || die "NFS 서버 ${NFS_SERVER_HOST} 에 도달할 수 없다. setup-nfs-server.sh 를 먼저 실행하고 방화벽을 확인할 것."
ok "NFS export 확인: $(showmount -e "$NFS_SERVER_HOST" | tail -n +2 | tr '\n' ' ')"

#=====================================================================
# 2. 이미지 적재
#=====================================================================
step "이미지 적재 (k8s.io 네임스페이스)"
shopt -s nullglob
for tar in "${IMG_DIR}"/*.tar; do ctr_import "$tar"; done
shopt -u nullglob

MISSING=()
mapfile -t MISSING < <(ctr_missing_images "${CONF_DIR}/images.list")
((${#MISSING[@]} == 0)) || die "적재되지 않은 이미지: ${MISSING[*]}"
ok "이미지 $(wc -l < "${CONF_DIR}/images.list")개 적재 확인"

#=====================================================================
# 3. 매니페스트 적용
#=====================================================================
step "매니페스트 적용"

# CRD 를 먼저 적용하고 등록을 기다린다. 한꺼번에 적용하면
# VolumeSnapshotClass 가 "no matches for kind" 로 실패할 수 있다.
kubectl apply -f <(cat "${MAN_DIR}"/10-crd-*.yaml) >/dev/null \
    || die "CRD 적용 실패"
retry_until 60 kubectl get crd volumesnapshots.snapshot.storage.k8s.io \
    || die "VolumeSnapshot CRD 가 등록되지 않았다"
ok "CRD 적용 및 등록 확인"

for f in "${MAN_DIR}"/2*.yaml "${MAN_DIR}"/3*.yaml "${MAN_DIR}"/4*.yaml; do
    [[ -f "$f" ]] || continue
    kubectl apply -f "$f" >/dev/null || die "적용 실패: $(basename "$f")"
done
ok "나머지 매니페스트 적용 완료"

#=====================================================================
# 4. 판정
#=====================================================================
run_checks
rc=$?

step "다음 단계"
echo "  다음: 40-haproxy -> 30-harbor -> 20-minio"
echo
echo "  상태:   kubectl -n kube-system get pods -l app=csi-nfs-controller"
echo "  재판정: sudo ./install.sh --check-only"
exit $rc
