#!/usr/bin/env bash
#---------------------------------------------------------------------
# 60-cilium : 오프라인 설치 (에어갭 타깃에서 root 로 실행)
#
#   # control plane (기본값) — helm 으로 Cilium 을 설치한다
#   sudo ./install.sh
#   sudo ./install.sh --check-only    # 판정만
#   sudo ./install.sh --uninstall     # 제거
#
#   # worker — 이미지만 적재한다
#   sudo ./install.sh --role worker
#   sudo ./install.sh --role worker --check-only
#
# 왜 worker 에서는 helm 을 돌리지 않는가:
#   Cilium 은 DaemonSet 이다. control plane 에서 한 번 설치하면 조인한 노드에도
#   자동으로 파드가 배치된다. worker 에서 helm 을 다시 돌리면 같은 릴리스를
#   두 번 관리하는 셈이 되어 위험하다. worker 에 필요한 것은 에어갭이라
#   받아올 수 없는 컨테이너 이미지를 containerd 에 미리 넣어두는 것뿐이다.
#   이미지가 없으면 cilium 파드가 ImagePullBackOff 로 떨어지고 노드는
#   영구 NotReady 가 된다.
#
# 전제:
#   control plane : 10-k8s 설치 완료(kubeadm init)
#   worker        : 10-k8s --role worker 로 조인 완료
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

# 역할 자동 판별: admin.conf 가 있으면 control plane, kubelet.conf 만 있으면 worker.
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
BIN_DIR="${BUNDLE_ROOT}/bin"
CHART_DIR="${BUNDLE_ROOT}/chart"
CONF_DIR="${BUNDLE_ROOT}/conf"
CHART_TGZ="$(ls "${CHART_DIR}"/cilium-*.tgz 2>/dev/null | head -1)"

#=====================================================================
# 판정 — worker
#=====================================================================
run_worker_checks() {
    step "설치 상태 판정 (역할: worker)"

    local KC=/etc/kubernetes/kubelet.conf
    local -a _miss=()
    local img

    check "조인 완료(kubelet.conf 존재)" test -f "$KC"

    mapfile -t _miss < <(ctr_missing_images "${CONF_DIR}/images.list")
    for img in "${_miss[@]}"; do warn "이미지 없음: $img"; done
    check "cilium 이미지 적재(k8s.io 네임스페이스)" test "${#_miss[@]}" -eq 0

    # 아래 둘은 control plane 의 DaemonSet 이 이 노드에 파드를 배치한 결과다.
    # 이미지가 준비돼 있으면 보통 1분 내에 끝난다.
    check "cilium CNI 설정 파일 생성됨(/etc/cni/net.d)" retry_until 240 \
        bash -c "ls /etc/cni/net.d/*cilium* >/dev/null 2>&1"
    check "cilium-cni 플러그인 배치됨" retry_until 120 test -x /opt/cni/bin/cilium-cni
    check "이 노드가 Ready" retry_until 240 bash -c "
        kubectl --kubeconfig ${KC} get node ${NODE_NAME} \
            -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' 2>/dev/null | grep -q True"

    check_summary
}

#=====================================================================
# 판정 — control plane
#=====================================================================
run_checks() {
    step "설치 상태 판정 (역할: control-plane)"

    check "helm 릴리스 cilium 존재" \
        bash -c "helm -n kube-system list -q | grep -qx cilium"

    # DaemonSet/Deployment 가 원하는 수만큼 준비됐는지. 기동에 시간이 걸리므로 대기한다.
    check "cilium DaemonSet 전부 Ready" retry_until 180 bash -c '
        d=$(kubectl -n kube-system get ds cilium -o jsonpath="{.status.desiredNumberScheduled}" 2>/dev/null)
        r=$(kubectl -n kube-system get ds cilium -o jsonpath="{.status.numberReady}" 2>/dev/null)
        [[ -n "$d" && "$d" != "0" && "$d" == "$r" ]]'
    check "cilium-operator Available" retry_until 180 bash -c '
        kubectl -n kube-system get deploy cilium-operator \
            -o jsonpath="{.status.availableReplicas}" 2>/dev/null | grep -qE "^[1-9]"'

    # 이 단계의 핵심 목표. CNI 가 동작하면 노드가 Ready 로 바뀐다.
    # worker 가 조인돼 있으면 그쪽도 함께 본다. 문자열에 True 가 하나라도 있으면
    # 통과하는 식으로 쓰면 안 된다(노드가 둘일 때 하나만 Ready 여도 통과한다).
    check "모든 노드 Ready" retry_until 180 bash -c '
        total=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
        ready=$(kubectl get nodes --no-headers 2>/dev/null | awk "\$2==\"Ready\"" | wc -l)
        [[ "$total" -gt 0 && "$total" == "$ready" ]]'
    check "CoreDNS Running" retry_until 180 bash -c '
        kubectl -n kube-system get pods -l k8s-app=kube-dns \
            -o jsonpath="{.items[*].status.phase}" 2>/dev/null | grep -q Running'

    check "CNI 설정 파일 생성됨(/etc/cni/net.d)" \
        bash -c "ls /etc/cni/net.d/*cilium* >/dev/null 2>&1"

    # kube-proxy 를 유지하는 설계이므로 살아 있어야 한다.
    check "kube-proxy 유지됨(대체 안 함)" \
        bash -c "kubectl -n kube-system get ds kube-proxy >/dev/null 2>&1"

    # cilium-cli 상태. 내부 진단이 모두 ok 인지 본다.
    if command -v cilium >/dev/null 2>&1; then
        check "cilium status (cli 진단)" retry_until 120 bash -c "cilium status --wait --wait-duration 90s"
    fi

    # 실제 데이터플레인 검증: 파드 하나를 띄워 Ready 까지 가는지 본다.
    # CNI 가 동작하지 않으면 여기서 반드시 실패한다(sandbox 생성 단계에서 막힌다).
    #
    # 판정 이름을 "DNS 해석"이라고 쓰지 않는다. pause 이미지에는 셸도
    # nslookup 도 없어 실제 이름 해석을 하지 않는다. 하는 일과 이름을
    # 맞춘다 — DNS 는 아래에서 별도로 본다.
    #
    # tolerations 를 넣는 이유: 다중 CP 클러스터에서는 CP 의
    # control-plane:NoSchedule taint 가 유지된다. worker 가 아직 없으면
    # 톨러레이션 없는 파드는 어디에도 못 뜬다(실측: 3-CP + worker 0 에서
    # 이 판정만 실패). 진단용 임시 파드이므로 모든 taint 를 견디게 한다.
    check "파드 기동(CNI 데이터플레인)" retry_until 180 bash -c '
        kubectl delete pod cni-smoke --ignore-not-found --wait=false >/dev/null 2>&1
        sleep 1
        kubectl run cni-smoke --image=registry.k8s.io/pause:3.10.2 \
            --restart=Never \
            --overrides="{\"spec\":{\"tolerations\":[{\"operator\":\"Exists\"}]}}" \
            --command -- /pause >/dev/null 2>&1
        kubectl wait --for=condition=Ready pod/cni-smoke --timeout=120s >/dev/null 2>&1'

    # CoreDNS Running 은 위에서 이미 본다. 여기서는 Service 에 엔드포인트가
    # 붙었는지를 본다 — 파드가 Running 이어도 readiness 를 통과하지 못하면
    # 엔드포인트가 비고 이름 해석이 되지 않는다.
    check "kube-dns Service 에 엔드포인트 존재" retry_until 120 bash -c "
        [[ -n \$(kubectl -n kube-system get endpointslices \
             -l kubernetes.io/service-name=kube-dns \
             -o jsonpath='{.items[*].endpoints[*].addresses[0]}' 2>/dev/null) ]]"
    if kubectl get pod cni-smoke >/dev/null 2>&1; then
        POD_IP="$(kubectl get pod cni-smoke -o jsonpath='{.status.podIP}' 2>/dev/null)"
        log "테스트 파드 IP: ${POD_IP:-없음} (Pod CIDR ${POD_CIDR} 범위여야 정상)"
        kubectl delete pod cni-smoke --ignore-not-found --wait=false >/dev/null 2>&1
    fi

    check_summary
}

do_uninstall() {
    step "Cilium 제거"
    helm -n kube-system uninstall cilium 2>/dev/null || warn "helm 릴리스가 없다"
    rm -f /etc/cni/net.d/*cilium* 2>/dev/null || true
    # cilium 이 만든 인터페이스/맵 정리. 남기면 재설치 시 엉킨다.
    ip link delete cilium_host 2>/dev/null || true
    ip link delete cilium_net 2>/dev/null || true
    ip link delete cilium_vxlan 2>/dev/null || true
    rm -rf /sys/fs/bpf/tc/globals/cilium_* 2>/dev/null || true
    ok "제거 완료. 노드는 다시 NotReady 가 된다(CNI 없음)."
    exit 0
}

[[ "$MODE" == "uninstall" ]] && do_uninstall
if [[ "$MODE" == "check" ]]; then
    if [[ "$ROLE" == "worker" ]]; then run_worker_checks; else run_checks; fi
    exit $?
fi

#=====================================================================
# worker: 이미지만 적재한다
#=====================================================================
if [[ "$ROLE" == "worker" ]]; then
    step "사전 확인 (worker)"
    verify_manifest "$BUNDLE_ROOT"
    is_online && warn "인터넷에 연결된 상태다. 오프라인 검증이라면 airgap-on.sh 를 먼저 실행할 것." \
              || ok "인터넷 차단 상태 (에어갭 검증 조건 충족)"
    require_cmds ctr
    [[ -f /etc/kubernetes/kubelet.conf ]] \
        || die "조인되지 않은 노드다. 10-k8s 를 --role worker 로 먼저 실행할 것."
    ok "조인 상태 확인 (kubelet.conf)"

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
    echo "  이 노드가 Ready 로 바뀌었다면 CNI 가 정상 동작한다."
    echo "  control plane 에서 확인:  kubectl get nodes -o wide"
    echo "                            kubectl -n kube-system get pods -o wide -l k8s-app=cilium"
    echo "  재판정: sudo ./install.sh --role worker --check-only"
    exit $rc
fi

#=====================================================================
# 0. 사전 확인 (control plane)
#=====================================================================
step "사전 확인"

verify_manifest "$BUNDLE_ROOT"

is_online && warn "인터넷에 연결된 상태다. 오프라인 검증이라면 airgap-on.sh 를 먼저 실행할 것." \
          || ok "인터넷 차단 상태 (에어갭 검증 조건 충족)"

require_cmds kubectl helm ctr
[[ -f /etc/kubernetes/admin.conf ]] || die "10-k8s 가 먼저 설치돼야 한다(admin.conf 없음)"
[[ -n "$CHART_TGZ" ]] || die "차트를 찾지 못했다: ${CHART_DIR}"

kubectl get nodes >/dev/null 2>&1 || die "apiserver 에 접근할 수 없다"
ok "k8s $(kubectl version -o json 2>/dev/null | grep -m1 gitVersion | grep -oE 'v[0-9.]+') 확인"

# Cilium 은 노드의 spec.podCIDR 를 쓴다(ipam.mode=kubernetes). 없으면 IP 할당이 안 된다.
NODE_POD_CIDR="$(kubectl get nodes -o jsonpath='{.items[0].spec.podCIDR}' 2>/dev/null)"
[[ -n "$NODE_POD_CIDR" ]] || die "노드에 spec.podCIDR 이 없다. kubeadm init 에 podSubnet 이 빠졌다."
ok "노드 podCIDR: ${NODE_POD_CIDR}"

#=====================================================================
# 1. 이미지 적재
#=====================================================================
step "이미지 적재 (k8s.io 네임스페이스)"

shopt -s nullglob
for tar in "${IMG_DIR}"/*.tar; do
    ctr_import "$tar"
done
shopt -u nullglob

MISSING=()
mapfile -t MISSING < <(ctr_missing_images "${CONF_DIR}/images.list")
((${#MISSING[@]} == 0)) || die "적재되지 않은 이미지: ${MISSING[*]}"
ok "이미지 $(wc -l < "${CONF_DIR}/images.list")개 적재 확인"

#=====================================================================
# 2. cilium-cli 설치
#=====================================================================
step "cilium-cli 설치"
CLI_TGZ="$(ls "${BIN_DIR}"/cilium-linux-*.tar.gz 2>/dev/null | head -1)"
if [[ -n "$CLI_TGZ" ]]; then
    tmp="$(mktemp -d)"
    tar -C "$tmp" -xzf "$CLI_TGZ"
    install -m 0755 "${tmp}/cilium" /usr/local/bin/cilium
    rm -rf "$tmp"
    ok "cilium-cli $(cilium version --client 2>/dev/null | head -1 || echo 설치됨)"
fi

#=====================================================================
# 3. helm 설치 (로컬 차트)
#=====================================================================
step "Cilium helm 설치"

if helm -n kube-system list -q 2>/dev/null | grep -qx cilium; then
    warn "cilium 릴리스가 이미 있다. upgrade 로 진행한다."
    HELM_ACTION="upgrade"
else
    HELM_ACTION="install"
fi

# --wait 를 주지 않는다. 파드가 뜨는 과정을 판정 단계에서 대기하며 보는 편이
# 실패 원인을 파악하기 쉽다(--wait 는 타임아웃 시 원인 없이 롤백된다).
helm "$HELM_ACTION" cilium "$CHART_TGZ" \
    --namespace kube-system \
    -f "${CONF_DIR}/values.yaml" \
    || die "helm ${HELM_ACTION} 실패"
ok "helm ${HELM_ACTION} 완료"

#=====================================================================
# 4. 판정
#=====================================================================
run_checks
rc=$?

step "다음 단계"
echo "  노드가 Ready 로 전환됐다면 CNI 구성이 끝났다."
echo "  다음: 50-nfs-csi (NFS 서버는 ${NFS_SERVER_HOST}:${NFS_EXPORT_PATH})"
echo
echo "  상태:  kubectl get nodes ; cilium status"
echo "  재판정: sudo ./install.sh --check-only"
echo "  제거:   sudo ./install.sh --uninstall"
exit $rc
