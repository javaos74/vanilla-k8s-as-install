#!/usr/bin/env bash
#---------------------------------------------------------------------
# 10-k8s : 오프라인 설치 (에어갭 타깃에서 root 로 실행)
#
# 역할을 구분한다. 같은 번들로 control plane 과 worker 를 모두 설치한다.
# 공통 단계(커널·swap·sysctl / deb / containerd / 이미지 / 도구)는 동일하고
# 마지막 단계만 kubeadm init 이냐 kubeadm join 이냐로 갈린다.
#
#   # control plane (기본값)
#   sudo ./install.sh
#   sudo ./install.sh --role control-plane
#
#   # 다중 control plane(HA) 의 첫 CP : 안정적인 엔드포인트를 반드시 준다.
#   #   <LB> 는 모든 CP 의 6443 을 앞단에서 받는 로드밸런서 주소다.
#   #   이 값 없이 init 하면 나중에 CP 를 추가할 수 없다(README 4.1절).
#   sudo ./install.sh --role control-plane --control-plane-endpoint k8s-api.example:6443
#
#   # 추가 control plane : 첫 CP 에서 조인 정보를 발급한 뒤
#   #   sudo ./install.sh --print-join-command
#   sudo ./install.sh --role control-plane \
#         --join-command "kubeadm join k8s-api.example:6443 --token ... \
#                         --discovery-token-ca-cert-hash sha256:..." \
#         --certificate-key <KEY>
#
#   # worker : 조인 정보가 반드시 필요하다.
#   #   control plane 에서 먼저:
#   #     sudo kubeadm token create --print-join-command
#   sudo ./install.sh --role worker --join-command "kubeadm join 10.0.0.11:6443 \
#         --token abcdef.0123456789abcdef \
#         --discovery-token-ca-cert-hash sha256:1234..."
#
#   # 또는 항목별로 지정
#   sudo ./install.sh --role worker --api-server 10.0.0.11:6443 \
#         --token abcdef.0123456789abcdef --ca-cert-hash sha256:1234...
#
#   sudo ./install.sh --check-only          # 설치 없이 현재 상태만 판정(역할 자동 판별)
#   sudo ./install.sh --print-join-command  # CP 에서 worker/CP 조인 명령 발급
#   sudo ./install.sh --reset               # kubeadm reset + 설정 정리
#
# taint 정책 (다중 노드에서 중요):
#   기본은 자동이다. --control-plane-endpoint 를 줬거나(HA 의도) 추가 CP 로
#   조인하는 경우 control-plane taint 를 유지하고, 단일 CP 면 제거한다.
#   --untaint / --keep-taint 로 명시할 수 있다.
#
# 결과:
#   control plane : CNI 가 없으므로 노드는 NotReady 다. 이것이 정상이며
#                   60-cilium 을 적용하면 Ready 로 전환된다.
#   worker        : 클러스터에 조인된 노드. 역시 CNI 가 그 노드에 올라와야
#                   Ready 가 된다(60-cilium 의 --role worker 참고).
#---------------------------------------------------------------------
BUNDLE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${BUNDLE_ROOT}/00-common/common.sh"

MODE="install"
ROLE=""
JOIN_COMMAND=""
API_ENDPOINT=""
JOIN_TOKEN=""
CA_CERT_HASH=""
CP_ENDPOINT=""          # --control-plane-endpoint (첫 CP 에서 HA 를 켠다)
CERT_KEY=""             # --certificate-key (추가 CP 조인)
EXTRA_SANS=""           # --cert-san (쉼표 구분, 반복 가능)
TAINT_POLICY="auto"     # auto | keep | remove
TAINT_EXPLICIT=0        # --untaint/--keep-taint 를 사용자가 직접 줬는가

usage() {
    sed -n '3,30p' "${BASH_SOURCE[0]}" | sed 's/^#//'
}

while (($#)); do
    case "$1" in
        --check-only)     MODE="check" ;;
        --reset)          MODE="reset" ;;
        --print-join-command) MODE="print-join" ;;
        --control-plane-endpoint) CP_ENDPOINT="${2:?--control-plane-endpoint 에 값이 없다 (HOST:PORT)}"; shift ;;
        --certificate-key) CERT_KEY="${2:?--certificate-key 에 값이 없다}"; shift ;;
        --cert-san)       EXTRA_SANS="${EXTRA_SANS:+${EXTRA_SANS},}${2:?--cert-san 에 값이 없다}"; shift ;;
        --untaint)        TAINT_POLICY="remove"; TAINT_EXPLICIT=1 ;;
        --keep-taint)     TAINT_POLICY="keep";   TAINT_EXPLICIT=1 ;;
        --role)           ROLE="${2:?--role 에 값이 없다 (control-plane | worker)}"; shift ;;
        --join-command)   JOIN_COMMAND="${2:?--join-command 에 값이 없다}"; shift ;;
        --api-server)     API_ENDPOINT="${2:?--api-server 에 값이 없다 (HOST:PORT)}"; shift ;;
        --token)          JOIN_TOKEN="${2:?--token 에 값이 없다}"; shift ;;
        --ca-cert-hash)   CA_CERT_HASH="${2:?--ca-cert-hash 에 값이 없다}"; shift ;;
        -h|--help)        usage; exit 0 ;;
        *)                usage >&2; die "알 수 없는 인자: $1" ;;
    esac
    shift
done

require_root
CODENAME="$(detect_codename)"
detect_arch >/dev/null

#---------------------------------------------------------------------
# 역할 판별
#
# 이미 설치된 노드는 파일로 역할을 알 수 있다.
#   admin.conf   -> control plane (kubeadm init 이 만든다)
#   kubelet.conf -> worker        (kubeadm join 도 만든다)
# --check-only / --reset 에서는 이 자동 판별을 쓴다. 설치 시에는 --role 이
# 없으면 control-plane 으로 본다(기존 동작 유지). worker 는 명시해야 한다.
# 이렇게 하지 않으면 worker 에서 인자를 빼먹었을 때 새 클러스터를 init 해버린다.
#---------------------------------------------------------------------
detect_installed_role() {
    if [[ -f /etc/kubernetes/admin.conf ]];   then echo "control-plane"
    elif [[ -f /etc/kubernetes/kubelet.conf ]]; then echo "worker"
    fi
}

if [[ -z "$ROLE" ]]; then
    ROLE="$(detect_installed_role)"
    if [[ -n "$ROLE" ]]; then
        log "역할 자동 판별: ${ROLE}"
    else
        ROLE="control-plane"
    fi
fi
[[ "$ROLE" == "control-plane" || "$ROLE" == "worker" ]] \
    || die "--role 값이 잘못됐다: ${ROLE} (control-plane | worker)"

#---------------------------------------------------------------------
# control plane 의 세부 모드 — init(첫 CP) 인가 join(추가 CP) 인가
#
# kubeadm 자체가 이 둘을 다른 명령으로 나눈다. 조인 정보가 주어졌으면
# 추가 CP 로 본다. 이렇게 하면 사용자가 모드를 따로 지정할 필요가 없고,
# worker 조인과 인자 형태가 같아 외울 것이 줄어든다.
#---------------------------------------------------------------------
CP_MODE="init"
if [[ "$ROLE" == "control-plane" ]] \
   && [[ -n "$JOIN_COMMAND" || -n "$JOIN_TOKEN" || -n "$CERT_KEY" ]]; then
    CP_MODE="join"
fi

# HOST:PORT 형태를 강제한다. 포트를 빼먹으면 kubeadm 이 그대로 받아들인 뒤
# 6443 이 아닌 곳을 보게 되어 원인 찾기 어려운 실패가 된다.
normalize_endpoint() {
    local ep="$1"
    [[ "$ep" == *:* ]] || ep="${ep}:6443"
    grep -qE '^[A-Za-z0-9._-]+:[0-9]+$' <<<"$ep" \
        || die "엔드포인트 형태가 잘못됐다: ${1} (HOST:PORT 또는 HOST)"
    echo "$ep"
}
[[ -n "$CP_ENDPOINT" ]] && CP_ENDPOINT="$(normalize_endpoint "$CP_ENDPOINT")"

# taint 정책 결정.
#   - 추가 CP 조인: 항상 유지. 여기서 taint 를 풀면 CP 에 일반 워크로드가 섞인다.
#   - 첫 CP 에 --control-plane-endpoint 를 줬다: HA 의도이므로 유지.
#   - 그 밖(단일 CP): 제거. 그래야 워크로드가 스케줄된다.
if [[ "$TAINT_POLICY" == "auto" ]]; then
    if [[ "$CP_MODE" == "join" || -n "$CP_ENDPOINT" ]]; then
        TAINT_POLICY="keep"
    else
        TAINT_POLICY="remove"
    fi
fi

DEB_DIR="${BUNDLE_ROOT}/debs"
IMG_DIR="${BUNDLE_ROOT}/images"
BIN_DIR="${BUNDLE_ROOT}/bin"
CONF_DIR="${BUNDLE_ROOT}/conf"

# kubeconfig 를 넘겨줄 대상 사용자(sudo 호출자).
TARGET_USER="${SUDO_USER:-root}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"

#---------------------------------------------------------------------
# 노드 식별 정보
#
# --check-only 에서도 필요하므로(판정이 노드명을 쓴다) 앞에서 구한다.
# 기본 경로의 출발지 IP 를 노드 IP 로 쓴다. 인터페이스가 여러 개인 환경에서
# hostname -I 의 첫 값이 원하는 주소가 아닐 수 있어 route 조회를 먼저 한다.
#---------------------------------------------------------------------
NODE_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')"
[[ -n "$NODE_IP" ]] || NODE_IP="$(hostname -I | awk '{print $1}')"
NODE_NAME="$(hostname | tr '[:upper:]' '[:lower:]')"

#---------------------------------------------------------------------
# --join-command 파싱
#
# control plane 의 `kubeadm token create --print-join-command` 출력을 그대로
# 붙여넣을 수 있게 한다. 사람이 세 값을 옮겨 적다 틀리는 것을 막는다.
#---------------------------------------------------------------------
parse_join_command() {
    local jc="$1"
    [[ -z "$API_ENDPOINT" ]] && \
        API_ENDPOINT="$(grep -oE '[A-Za-z0-9._-]+:[0-9]+' <<<"$jc" | head -1)"
    [[ -z "$JOIN_TOKEN" ]] && \
        JOIN_TOKEN="$(sed -nE 's/.*--token[= ]+([^ ]+).*/\1/p' <<<"$jc" | head -1)"
    [[ -z "$CA_CERT_HASH" ]] && \
        CA_CERT_HASH="$(sed -nE 's/.*--discovery-token-ca-cert-hash[= ]+([^ ]+).*/\1/p' <<<"$jc" | head -1)"
}
[[ -n "$JOIN_COMMAND" ]] && parse_join_command "$JOIN_COMMAND"


#---------------------------------------------------------------------
# HA 관련 조회 헬퍼
#---------------------------------------------------------------------
KADM_KC=/etc/kubernetes/admin.conf

# 클러스터에 설정된 controlPlaneEndpoint. 없으면 빈 문자열.
# kubeadm 이 kube-system/kubeadm-config ConfigMap 에 보관한다.
cluster_cp_endpoint() {
    kubectl --kubeconfig "$KADM_KC" -n kube-system get cm kubeadm-config \
        -o jsonpath='{.data.ClusterConfiguration}' 2>/dev/null \
        | sed -nE 's/^controlPlaneEndpoint:[[:space:]]*(.+)$/\1/p' | head -1
}

# control plane 노드 수
cp_node_count() {
    kubectl --kubeconfig "$KADM_KC" get nodes \
        -l node-role.kubernetes.io/control-plane -o name 2>/dev/null | grep -c . || true
}

# etcd 멤버 목록을 etcdctl 로 조회한다.
# etcdctl 은 etcd 이미지 안에 있으므로 호스트에 설치할 필요가 없다.
# 에어갭에서도 추가로 받아올 것이 없다는 뜻이다.
etcdctl_in_pod() {
    local pod="etcd-${NODE_NAME}"
    kubectl --kubeconfig "$KADM_KC" -n kube-system exec "$pod" -- etcdctl \
        --endpoints=https://127.0.0.1:2379 \
        --cacert=/etc/kubernetes/pki/etcd/ca.crt \
        --cert=/etc/kubernetes/pki/etcd/server.crt \
        --key=/etc/kubernetes/pki/etcd/server.key \
        "$@" 2>/dev/null
}

# etcd 멤버 수. 조회 실패 시 0 을 돌려 판정이 조용히 통과하지 않게 한다.
etcd_member_count() {
    local n
    n="$(etcdctl_in_pod member list | grep -c . || true)"
    echo "${n:-0}"
}

# endpoint health 가 healthy 라고 답한 멤버 수.
etcd_healthy_count() {
    local n
    n="$(etcdctl_in_pod endpoint health --cluster | grep -c 'is healthy' || true)"
    echo "${n:-0}"
}

# 아래 둘은 retry_until 에 그대로 넘기기 위한 술어(predicate)다.
#
# 재시도가 필요한 이유: CP 조인 직후에는 etcd static 파드가 아직 API 에
# 등록되지 않아 kubectl exec 이 실패한다. 그 순간 판정하면 멤버 수를 0 으로
# 읽어 거짓 실패가 된다(실측: 조인 직후 0, 4분 뒤 2).
etcd_members_match() {
    [[ "$(etcd_member_count)" -eq "$1" ]]
}
etcd_all_healthy() {
    local n; n="$(etcd_member_count)"
    (( n > 0 )) && [[ "$(etcd_healthy_count)" -eq "$n" ]]
}

#=====================================================================
# 판정 (--check-only 및 설치 후 공통)
#=====================================================================
run_checks() {
    step "설치 상태 판정 (역할: ${ROLE})"

    check "containerd ${CONTAINERD_VERSION} 설치됨" \
        bash -c "containerd --version | grep -q 'v${CONTAINERD_VERSION}'"
    # PATH 의 runc 가 아니라 containerd 가 실제로 쓰는 /usr/bin/runc 를 본다.
    # podman-static 이 /usr/local/bin/runc(1.4.3)를 깔아 PATH 를 가리기 때문이다.
    check "runc ${RUNC_VERSION} (/usr/bin/runc)" \
        bash -c "/usr/bin/runc --version | head -1 | grep -q '${RUNC_VERSION}'"
    check "containerd runc 경로 고정(BinaryName)" \
        grep -q "BinaryName = '/usr/bin/runc'" /etc/containerd/config.toml
    check "containerd SystemdCgroup=true" \
        grep -q 'SystemdCgroup = true' /etc/containerd/config.toml
    check "containerd 서비스 active"        systemctl is-active --quiet containerd
    check "containerd 부팅 시 자동기동"      systemctl is-enabled --quiet containerd

    check "kubeadm ${K8S_VERSION}" bash -c "kubeadm version -o short | grep -q 'v${K8S_VERSION}'"
    check "kubelet ${K8S_VERSION}" bash -c "kubelet --version | grep -q 'v${K8S_VERSION}'"
    check "kubectl ${K8S_VERSION}" bash -c "kubectl version --client -o json 2>/dev/null | grep -q '\"gitVersion\": \"v${K8S_VERSION}\"'"
    check "kube 패키지 apt-mark hold" \
        bash -c "apt-mark showhold | grep -qx kubelet"
    check "/opt/cni/bin 존재(kubernetes-cni)" test -x /opt/cni/bin/loopback

    check "swap 비활성"        bash -c "[[ -z \$(swapon --show --noheadings) ]]"
    check "br_netfilter 로드"  bash -c "lsmod | grep -q br_netfilter"
    check "ip_forward=1"       bash -c "[[ \$(sysctl -n net.ipv4.ip_forward) == 1 ]]"

    # 요구사항: helm 3.8+ / docker 28+ / podman 4.9+
    check "helm ${HELM_VERSION}"   bash -c "helm version --short | grep -q '${HELM_VERSION}'"
    check "docker ${DOCKER_VERSION}" bash -c "docker --version | grep -q '${DOCKER_VERSION}'"
    check "podman ${PODMAN_STATIC_VERSION#v} (4.9+ 요구사항)" \
        bash -c "podman --version | grep -q '${PODMAN_STATIC_VERSION#v}'"

    # 이미지가 k8s.io 네임스페이스에 있어야 kubelet 이 본다.
    local -a _miss=()
    local img
    mapfile -t _miss < <(ctr_missing_images "${CONF_DIR}/images.list")
    for img in "${_miss[@]}"; do warn "이미지 없음: $img"; done
    check "k8s 이미지 전체 적재(k8s.io 네임스페이스)" test "${#_miss[@]}" -eq 0

    check "kubelet 서비스 active"  systemctl is-active --quiet kubelet

    #-----------------------------------------------------------------
    # 여기부터는 역할별 판정이다.
    #-----------------------------------------------------------------
    if [[ "$ROLE" == "worker" ]]; then
        # worker 에는 admin.conf 가 없다. 대신 kubelet.conf 를 kubeconfig 로 쓴다.
        # kubelet 의 사용자(system:node:<이름>)는 자기 노드 객체를 읽을 수 있고,
        # /healthz 는 system:public-info-viewer 로 인증된 사용자 전체에 열려 있다.
        local KC=/etc/kubernetes/kubelet.conf

        check "조인 완료(kubelet.conf 존재)" test -f "$KC"
        check "클러스터 CA 존재(pki/ca.crt)"  test -f /etc/kubernetes/pki/ca.crt
        check "control plane 산출물 없음(worker 로 올바르게 설치됨)" \
            bash -c "[[ ! -f /etc/kubernetes/admin.conf && ! -f /etc/kubernetes/manifests/etcd.yaml ]]"

        if [[ -f "$KC" ]]; then
            local API_SRV
            API_SRV="$(kubectl --kubeconfig "$KC" config view -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null)"
            log "apiserver 엔드포인트: ${API_SRV:-확인불가}"

            check "apiserver 응답(/healthz)" bash -c "
                timeout 10 kubectl --kubeconfig ${KC} get --raw /healthz >/dev/null"
            check "자기 노드가 API 에 등록됨" retry_until 120 bash -c "
                kubectl --kubeconfig ${KC} get node ${NODE_NAME} >/dev/null 2>&1"
            # CNI 가 그 노드에 올라오기 전에는 NotReady 다. 판정이 아니라 정보로 낸다.
            local w_ready
            w_ready="$(kubectl --kubeconfig "$KC" get node "$NODE_NAME" \
                -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)"
            echo
            log "참고: 노드 ${NODE_NAME} Ready=${w_ready:-unknown}"
            if [[ "$w_ready" != "True" ]]; then
                log "  이 노드에 CNI 파드가 올라오기 전에는 NotReady 가 정상이다."
                log "  60-cilium 번들을 이 노드에서 --role worker 로 실행할 것."
            fi
        fi

        check_summary
        return $?
    fi

    #--- control plane ------------------------------------------------
    # admin.conf 는 controlPlaneEndpoint 가 있으면 **LB 주소**를 가리킨다.
    # 그래서 즉시 판정하면 실패할 수 있다 — LB 가 백엔드를 UP 으로 올리는 데
    # 헬스체크 두 번(rise 2)이 걸리기 때문이다. 실측에서 init 직후 1회 실패 후
    # 2초 뒤 통과하는 것을 확인했다. 재시도로 감싼다.
    check "apiserver 응답(admin.conf 의 엔드포인트)" retry_until 60 bash -c "
        timeout 10 kubectl --kubeconfig /etc/kubernetes/admin.conf get --raw /healthz >/dev/null"

    if [[ -f /etc/kubernetes/admin.conf ]]; then
        export KUBECONFIG=/etc/kubernetes/admin.conf
        # kubeadm init 직후에는 static 파드가 아직 API 에 등록되지 않는다.
        # 즉시 판정하면 실패하므로 최대 120초 대기한다(실측으로 확인된 문제).
        check "control plane 파드 4종 Running" retry_until 120 bash -c "
            for c in kube-apiserver kube-controller-manager kube-scheduler etcd; do
                kubectl -n kube-system get pods -l component=\$c \
                    -o jsonpath='{.items[*].status.phase}' 2>/dev/null | grep -q Running || exit 1
            done"
        check "노드 등록됨" bash -c "kubectl get nodes -o name 2>/dev/null | grep -q node/"

        #--- 다중 control plane 상태 조회 ------------------------------
        # taint 기대값을 정하는 데도 쓰이므로 먼저 구한다.
        local cpe cp_n etcd_members etcd_healthy
        cpe="$(cluster_cp_endpoint)"
        cp_n="$(cp_node_count)"
        : "${cp_n:=0}"

        # taint 판정의 기대값은 **클러스터 실제 상태**에서 끌어온다.
        # --check-only 에는 --control-plane-endpoint 가 넘어오지 않으므로
        # 설치 시 인자로 판단하면 HA 클러스터를 단일 노드로 오판한다(실측).
        # 사용자가 --untaint/--keep-taint 를 명시했으면 그것을 존중한다.
        local taint_expect="$TAINT_POLICY"
        if (( ! TAINT_EXPLICIT )); then
            if [[ -n "$cpe" ]] || (( cp_n > 1 )); then
                taint_expect="keep"
            else
                taint_expect="remove"
            fi
        fi

        # 단일 노드에서는 제거돼 있어야 워크로드가 뜨고, 다중 노드에서는
        # 남아 있어야 CP 가 워크로드로 오염되지 않는다.
        if [[ "$taint_expect" == "remove" ]]; then
            check "control-plane taint 제거됨(단일 노드 스케줄 가능)" bash -c "
                ! kubectl get nodes -o jsonpath='{.items[*].spec.taints[*].key}' 2>/dev/null \
                  | grep -q node-role.kubernetes.io/control-plane"
        else
            check "control-plane taint 유지됨(다중 노드: CP 에 워크로드 금지)" bash -c "
                kubectl get node ${NODE_NAME} -o jsonpath='{.spec.taints[*].key}' 2>/dev/null \
                  | grep -q node-role.kubernetes.io/control-plane"
        fi

        #--- 다중 control plane 판정 ----------------------------------
        if [[ -n "$cpe" ]]; then
            ok "controlPlaneEndpoint = ${cpe}  (CP 추가 가능)"
            # 인증서에 그 주소가 들어가 있어야 클라이언트 검증이 통과한다.
            local cpe_host="${cpe%:*}"
            check "apiserver 인증서 SAN 에 ${cpe_host} 포함" bash -c "
                openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -text \
                  | grep -A1 'Subject Alternative Name' | grep -q '${cpe_host}'"
            # 그 엔드포인트로 실제 응답이 오는지. LB 설정 누락을 여기서 잡는다.
            check "controlPlaneEndpoint 로 apiserver 응답" bash -c "
                timeout 10 curl -sk https://${cpe}/healthz | grep -q ok"
        else
            warn "controlPlaneEndpoint 가 없다 — 이 클러스터에는 CP 를 추가할 수 없다."
            log  "  CP 를 늘릴 계획이면 지금 reset 후 --control-plane-endpoint 로 다시 init 할 것."
            log  "  근거와 우회 방법은 README 4.1절."
        fi

        log "control plane 노드 수: ${cp_n}"

        if (( cp_n > 1 )); then
            # etcd 멤버 수가 CP 수와 같아야 한다. 어긋나면 조인이 중간에
            # 실패했거나 제거된 CP 의 멤버가 남아 있다는 뜻이다.
            # 조인 직후 etcd 파드가 API 에 없을 수 있어 재시도로 감싼다.
            check "etcd 멤버 수 == CP 노드 수(${cp_n})" \
                retry_until 120 etcd_members_match "$cp_n"

            # 멤버가 보이는 것만으로는 부족하다. 각 엔드포인트의 건강을 본다.
            check "etcd 전 멤버 healthy" retry_until 120 etcd_all_healthy

            etcd_members="$(etcd_member_count)"
            etcd_healthy="$(etcd_healthy_count)"
            log "etcd 멤버 ${etcd_members}개 / healthy ${etcd_healthy}개"

            # 정족수는 과반이다. 짝수는 장애 허용 수가 늘지 않으면서
            # 동시 장애 시 정족수를 잃을 확률만 높인다.
            if (( cp_n % 2 == 0 )); then
                warn "CP 수가 짝수(${cp_n})다. etcd 정족수는 과반이라 이득이 없다."
                log  "  ${cp_n}대는 $((cp_n/2 - 1))대 장애까지 견딘다 — $((cp_n-1))대와 같다. 홀수(3·5)를 권장한다."
            else
                ok "CP 수가 홀수(${cp_n}) — 장애 허용 $((cp_n/2))대"
            fi

            # 모든 CP 가 준비됐는지. 하나가 빠져 있으면 정족수 여유가 없다.
            check "전 CP 노드가 API 에 등록됨" bash -c "
                [[ \$(kubectl get nodes -l node-role.kubernetes.io/control-plane \
                     -o name 2>/dev/null | grep -c .) -eq ${cp_n} ]]"
        fi

        # CNI 가 없으면 노드는 NotReady, CoreDNS 는 Pending 이다. 이것이 이 단계의 정상 상태다.
        local node_status coredns_phase
        node_status="$(kubectl get nodes -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)"
        coredns_phase="$(kubectl -n kube-system get pods -l k8s-app=kube-dns -o jsonpath='{.items[*].status.phase}' 2>/dev/null)"
        echo
        log "참고: 노드 Ready=${node_status:-unknown}, CoreDNS=${coredns_phase:-none}"
        if [[ "$node_status" != "True" ]]; then
            log "  CNI 미설치 상태이므로 NotReady 가 정상이다. 60-cilium 적용 후 Ready 로 바뀐다."
        fi
    fi

    check_summary
}

#=====================================================================
# reset
#=====================================================================
do_reset() {
    step "kubeadm reset (역할: ${ROLE})"

    # 다중 CP 에서는 파괴 범위가 다르다. CP 가 여러 대면 이 노드만 빠지고
    # 클러스터는 남는다. 대신 etcd 멤버를 제대로 빼지 않으면 정족수가 깨진다.
    RESET_CP_N=0
    if [[ -f "$KADM_KC" ]]; then
        RESET_CP_N="$(cp_node_count)"
        : "${RESET_CP_N:=0}"
    fi

    if [[ "$ROLE" == "worker" ]]; then
        warn "이 노드를 클러스터에서 떼어낸다. 5초 후 진행. 중단하려면 Ctrl-C."
    elif (( RESET_CP_N > 1 )); then
        warn "CP ${RESET_CP_N}대 중 이 노드를 떼어낸다. 클러스터는 남는다. 5초 후 진행."
        # kubeadm reset 은 API 에 닿을 수 있으면 etcd 멤버를 스스로 제거한다.
        # 닿지 않으면 유령 멤버가 남아 남은 CP 의 정족수 계산을 망친다.
        if timeout 10 kubectl --kubeconfig "$KADM_KC" get --raw /healthz >/dev/null 2>&1; then
            log "API 도달 가능 — kubeadm 이 etcd 멤버를 스스로 제거한다."
        else
            warn "API 에 닿지 않는다. etcd 멤버가 남을 수 있다."
            log  "  reset 후 살아 있는 CP 에서 직접 제거할 것:"
            log  "    kubectl -n kube-system exec etcd-<살아있는CP> -- etcdctl \\"
            log  "      --endpoints=https://127.0.0.1:2379 \\"
            log  "      --cacert=/etc/kubernetes/pki/etcd/ca.crt \\"
            log  "      --cert=/etc/kubernetes/pki/etcd/server.crt \\"
            log  "      --key=/etc/kubernetes/pki/etcd/server.key member list"
            log  "    ... member remove <이 노드의 ID>"
        fi
        # 남는 CP 수가 짝수가 되면 정족수 여유가 줄어든다는 점을 알려 준다.
        if (( (RESET_CP_N - 1) % 2 == 0 && RESET_CP_N - 1 > 0 )); then
            warn "제거 후 CP 가 $((RESET_CP_N-1))대(짝수)가 된다. 홀수 유지를 권장한다."
        fi
    else
        warn "클러스터를 파괴한다. 5초 후 진행. 중단하려면 Ctrl-C."
    fi
    sleep 5
    kubeadm reset -f --cri-socket unix:///run/containerd/containerd.sock || true
    rm -rf /etc/cni/net.d /var/lib/cni /etc/kubernetes
    rm -f "${TARGET_HOME}/.kube/config"
    # iptables/nft 잔여 규칙 정리. 남겨두면 다음 init/join 이 엉킨다.
    iptables-save 2>/dev/null | grep -viE "KUBE|CILIUM" | iptables-restore 2>/dev/null || true
    ipvsadm -C 2>/dev/null || true
    ok "reset 완료. containerd/kubelet 패키지는 남아 있다."
    if [[ "$ROLE" == "worker" ]] || (( RESET_CP_N > 1 )); then
        echo
        log "남아 있는 control plane 에서 노드 객체도 지울 것:  kubectl delete node ${NODE_NAME}"
    fi
    exit 0
}

[[ "$MODE" == "reset" ]] && do_reset
if [[ "$MODE" == "check" ]]; then run_checks; exit $?; fi

#=====================================================================
# --print-join-command : CP 에서 조인 정보를 발급한다
#
# 왜 별도 모드로 두는가:
#   worker 조인은 token + CA 해시만으로 되지만, CP 조인은 certificate-key 가
#   더 필요하다. 그리고 그 키로 여는 kubeadm-certs Secret 은 **2시간 뒤
#   자동 삭제된다**. 그래서 CP 를 추가할 때마다 인증서를 다시 업로드해
#   새 키를 받아야 한다. 이 과정을 사람이 외우기 어려워 한 명령으로 묶었다.
#=====================================================================
if [[ "$MODE" == "print-join" ]]; then
    [[ -f "$KADM_KC" ]] || die "이 노드는 control plane 이 아니다(admin.conf 없음). 첫 CP 에서 실행할 것."

    step "조인 명령 발급"

    WORKER_JOIN="$(kubeadm token create --print-join-command 2>/dev/null)" \
        || die "kubeadm token create 실패"

    CPE="$(cluster_cp_endpoint)"

    echo
    echo "  --- worker 추가 ---"
    echo "  sudo ./install.sh --role worker --join-command \"${WORKER_JOIN}\""
    echo

    if [[ -z "$CPE" ]]; then
        warn "controlPlaneEndpoint 가 설정돼 있지 않아 CP 를 추가할 수 없다."
        log  "  CP 조인은 안정적인 엔드포인트를 전제로 한다. README 4.1절을 볼 것."
    else
        # 인증서를 다시 올려 새 키를 받는다. 기존 Secret 이 있으면 교체된다.
        #
        # 출력 형식에 주의. kubeadm 은 라벨과 키를 **다른 줄**에 쓴다(실측).
        #   [upload-certs] Using certificate key:
        #   <64자 hex>
        # 그래서 같은 줄에서 찾는 정규식으로는 잡히지 않는다. 라벨 문구에
        # 의존하지 않고 단독으로 놓인 64자 hex 행을 집는다.
        #
        # 에어갭에서는 kubeadm 이 dl.k8s.io 버전 조회를 시도해 10초쯤 지연된
        # 뒤 로컬 버전으로 넘어간다. 경고가 보이는 것은 정상이다.
        NEW_CERT_KEY="$(kubeadm init phase upload-certs --upload-certs 2>/dev/null \
            | grep -oE '^[0-9a-f]{64}$' | tail -1)"
        [[ -n "$NEW_CERT_KEY" ]] \
            || die "certificate-key 를 얻지 못했다. 'kubeadm init phase upload-certs --upload-certs' 를 직접 실행해 확인할 것."

        echo "  --- control plane 추가 ---"
        echo "  sudo ./install.sh --role control-plane \\"
        echo "        --join-command \"${WORKER_JOIN}\" \\"
        echo "        --certificate-key ${NEW_CERT_KEY}"
        echo
        warn "certificate-key 는 2시간 뒤 무효가 된다(kubeadm-certs Secret 자동 삭제)."
        log  "  만료됐으면 이 명령을 다시 실행해 새 키를 받을 것."
        log  "  이 키로 클러스터 CA 개인키를 복호화할 수 있다. 채널을 가려서 전달할 것."
    fi
    exit 0
fi

#=====================================================================
# 0. 사전 확인
#=====================================================================
step "사전 확인"

verify_manifest "$BUNDLE_ROOT"

# 에어갭이 아니어도 설치는 되지만, 오프라인 검증이라면 경고를 남긴다.
if is_online; then
    warn "인터넷에 연결된 상태다. 오프라인 설치를 '검증'하려면 90-verify/airgap-on.sh 를 먼저 실행할 것."
else
    ok "인터넷 차단 상태 (에어갭 검증 조건 충족)"
fi

NODE_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')"
[[ -n "$NODE_IP" ]] || NODE_IP="$(hostname -I | awk '{print $1}')"
NODE_NAME="$(hostname | tr '[:upper:]' '[:lower:]')"
log "노드 IP=${NODE_IP} / 노드명=${NODE_NAME} / 역할=${ROLE}"

#=====================================================================
# 1. 커널 / swap / sysctl
#=====================================================================
step "커널 모듈 · swap · sysctl"

install_file "${CONF_DIR}/k8s-modules.conf" /etc/modules-load.d/k8s.conf
modprobe overlay && modprobe br_netfilter
ok "overlay / br_netfilter 로드"

install_file "${CONF_DIR}/k8s-sysctl.conf" /etc/sysctl.d/99-k8s.conf
sysctl --system >/dev/null
ok "sysctl 적용"

if [[ -n "$(swapon --show --noheadings)" ]]; then
    log "swap 비활성화"
    swapoff -a
    # fstab 의 swap 항목을 주석 처리해야 재부팅 후에도 유지된다.
    sed -i.bak-$(date +%Y%m%d-%H%M%S) -E 's@^([^#].*\sswap\s)@#\1@' /etc/fstab
    ok "swap 비활성 + fstab 주석 처리"
else
    ok "swap 없음"
fi

#=====================================================================
# 2. deb 설치
#=====================================================================
step "deb 설치 ($(find "$DEB_DIR" -name '*.deb' | wc -l)개)"

# dpkg 로 한 번에 넣고 의존성 문제는 apt 로 정리한다(오프라인이라 다운로드 없음).
dpkg -i "$DEB_DIR"/*.deb >/dev/null 2>&1 || {
    log "dpkg 1차 실패 -> 의존성 정리 시도"
    DEBIAN_FRONTEND=noninteractive \
    apt-get -o DPkg::Lock::Timeout=900 -f install -y --no-download >/dev/null 2>&1 \
        || die "deb 의존성 해결 실패. 번들이 빌드 호스트와 다른 OS 용일 수 있다."
    dpkg -i "$DEB_DIR"/*.deb >/dev/null 2>&1 || die "deb 설치 실패"
}
ok "deb 설치 완료"

# 자동 업그레이드로 버전이 바뀌면 클러스터가 깨진다. 반드시 hold.
apt-mark hold kubelet kubeadm kubectl containerd.io >/dev/null
ok "kubelet/kubeadm/kubectl/containerd.io apt-mark hold"

#=====================================================================
# 3. containerd 설정
#=====================================================================
step "containerd 설정"

PAUSE_IMAGE="$(cat "${CONF_DIR}/pause-image")"

mkdir -p /etc/containerd
if [[ ! -f /etc/containerd/config.toml.orig ]]; then
    containerd config default > /etc/containerd/config.toml.orig
fi
containerd config default > /etc/containerd/config.toml

# cgroup 드라이버를 systemd 로. kubelet 설정과 반드시 일치해야 한다.
# 어긋나면 kubelet 은 뜨지만 파드가 무작위로 재시작된다.
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
grep -q 'SystemdCgroup = true' /etc/containerd/config.toml \
    || die "SystemdCgroup 설정 실패. containerd 기본 설정 형식이 바뀐 것으로 보인다."

# sandbox(pause) 이미지를 kubeadm 이 기대하는 값으로 맞춘다.
# containerd 2.x(config version 4)는 pinned_images.sandbox 키를 쓴다.
# 값이 다르면 파드가 sandbox 생성 단계에서 실패한다.
sed -i -E "s@^(\s*sandbox = ').*(')@\1${PAUSE_IMAGE}\2@" /etc/containerd/config.toml
grep -q "sandbox = '${PAUSE_IMAGE}'" /etc/containerd/config.toml \
    || die "sandbox 이미지 설정 실패 (기대값: ${PAUSE_IMAGE})"
ok "SystemdCgroup=true, sandbox=${PAUSE_IMAGE}"

# runc 경로를 절대경로로 고정한다.
#
# 기본값은 BinaryName = '' 이고, 이때 containerd 는 PATH 에서 runc 를 찾는다.
# 그런데 podman-static 이 /usr/local/bin/runc (1.4.3) 를 함께 설치하고
# /usr/local/bin 이 /usr/bin 보다 PATH 앞에 오므로, 고정하지 않으면
# containerd 가 containerd.io 의 /usr/bin/runc (${RUNC_VERSION}) 대신
# podman 쪽 runc 를 쓰게 된다. 검증되지 않은 조합이 되므로 반드시 박아둔다.
sed -i -E "s@^(\s*)BinaryName = ''@\1BinaryName = '/usr/bin/runc'@" /etc/containerd/config.toml
grep -q "BinaryName = '/usr/bin/runc'" /etc/containerd/config.toml \
    || die "runc BinaryName 고정 실패"
ok "runc 고정: /usr/bin/runc ($(/usr/bin/runc --version | head -1 | awk '{print $3}'))"

systemctl daemon-reload
systemctl enable --now containerd >/dev/null
systemctl restart containerd
# containerd 소켓이 열릴 때까지 기다린다. 바로 ctr 을 쓰면 실패한다.
for i in {1..30}; do
    ctr version >/dev/null 2>&1 && break
    [[ $i -eq 30 ]] && die "containerd 가 기동되지 않았다: journalctl -u containerd"
    sleep 1
done
ok "containerd 기동 ($(containerd --version | awk '{print $3}'))"

#=====================================================================
# 4. 이미지 적재
#=====================================================================
step "이미지 적재 (k8s.io 네임스페이스)"

shopt -s nullglob
for tar in "${IMG_DIR}"/*.tar; do
    ctr_import "$tar"
done
shopt -u nullglob

# 적재 결과를 목록과 대조한다. 누락되면 kubeadm init 이 이미지를 받으러
# 인터넷으로 나가려 하다 실패한다.
MISSING=()
mapfile -t MISSING < <(ctr_missing_images "${CONF_DIR}/images.list")
((${#MISSING[@]} == 0)) || die "적재되지 않은 이미지: ${MISSING[*]}"
ok "이미지 $(wc -l < "${CONF_DIR}/images.list")개 적재 확인"

#=====================================================================
# 5. 도구 설치
#=====================================================================
step "helm · podman 설치"

HELM_TGZ="$(ls "${BIN_DIR}"/helm-*.tar.gz 2>/dev/null | head -1)"
if [[ -n "$HELM_TGZ" ]]; then
    tmp="$(mktemp -d)"
    tar -C "$tmp" -xzf "$HELM_TGZ"
    install -m 0755 "${tmp}/linux-${BUNDLE_ARCH}/helm" /usr/local/bin/helm
    rm -rf "$tmp"
    ok "helm $(helm version --short 2>/dev/null)"
fi

PODMAN_TGZ="$(ls "${BIN_DIR}"/podman-linux-*.tar.gz 2>/dev/null | head -1)"
if [[ -n "$PODMAN_TGZ" ]]; then
    # tarball 구조: podman-linux-amd64/{usr/...,etc/...,README.md}
    # -C / 로 바로 풀면 /podman-linux-amd64 가 생기고, --strip-components=1 만
    # 쓰면 README.md 가 / 에 떨어진다. 임시로 푼 뒤 usr/ 와 etc/ 만 옮긴다.
    tmp="$(mktemp -d)"
    tar -C "$tmp" -xzf "$PODMAN_TGZ" --strip-components=1
    [[ -d "${tmp}/usr" ]] || die "podman tarball 구조가 예상과 다르다"
    cp -a "${tmp}/usr/." /usr/
    # /etc/containers (policy.json, registries.conf) 가 없으면 podman 이 동작하지 않는다.
    if [[ -d "${tmp}/etc" ]]; then
        cp -a --no-clobber "${tmp}/etc/." /etc/ 2>/dev/null || true
    fi
    rm -rf "$tmp"
    command -v podman >/dev/null || die "podman 설치 실패(PATH 에 없음)"
    ok "podman $(podman --version | awk '{print $3}') (static)"
fi

#=====================================================================
# 6. kubeadm init (control plane) / kubeadm join (worker)
#=====================================================================
if [[ "$ROLE" == "worker" ]]; then
    step "kubeadm join (worker)"

    if [[ -f /etc/kubernetes/kubelet.conf ]]; then
        warn "이미 조인된 노드다. join 을 건너뛴다."
        warn "다시 조인하려면: sudo ./install.sh --reset  (control plane 에서 kubectl delete node 도 필요)"
    else
        [[ -n "$API_ENDPOINT" && -n "$JOIN_TOKEN" && -n "$CA_CERT_HASH" ]] || die "$(cat <<'MSG'
조인 정보가 부족하다. control plane 에서 아래를 실행해 출력을 그대로 넘길 것.

  sudo kubeadm token create --print-join-command

  sudo ./install.sh --role worker --join-command "kubeadm join <IP>:6443 --token <TOKEN> \
        --discovery-token-ca-cert-hash sha256:<HASH>"
MSG
)"
        [[ "$CA_CERT_HASH" == sha256:* ]] \
            || die "--ca-cert-hash 는 sha256: 로 시작해야 한다: ${CA_CERT_HASH}"

        # 조인 전에 도달성을 먼저 본다. 여기서 막히면 kubeadm 이 수십 초 기다린 뒤
        # 불친절한 오류를 내므로, 원인을 즉시 알려주는 편이 낫다.
        JOIN_HOST="${API_ENDPOINT%:*}"
        JOIN_PORT="${API_ENDPOINT##*:}"
        timeout 8 bash -c ">/dev/tcp/${JOIN_HOST}/${JOIN_PORT}" 2>/dev/null \
            || die "apiserver ${API_ENDPOINT} 에 TCP 연결이 되지 않는다. 방화벽/NSG 와 IP 를 확인할 것."
        ok "apiserver ${API_ENDPOINT} 도달 확인"

        sed -e "s@__API_ENDPOINT__@${API_ENDPOINT}@g" \
            -e "s@__TOKEN__@${JOIN_TOKEN}@g" \
            -e "s@__CA_CERT_HASH__@${CA_CERT_HASH}@g" \
            -e "s@__NODE_IP__@${NODE_IP}@g" \
            -e "s@__NODE_NAME__@${NODE_NAME}@g" \
            "${CONF_DIR}/kubeadm-join.yaml" > /tmp/kubeadm-join.yaml

        systemctl enable kubelet >/dev/null

        log "kubeadm join 실행 (로그: /var/log/kubeadm-join.log)"
        # 이미지는 이미 적재돼 있으므로 pull 이 발생하지 않는다.
        # kubelet 설정은 클러스터의 kubelet-config ConfigMap 에서 받아오므로
        # join 설정에 KubeletConfiguration 을 넣지 않는다(중복·충돌 방지).
        kubeadm join --config /tmp/kubeadm-join.yaml \
            2>&1 | tee /var/log/kubeadm-join.log \
            || die "kubeadm join 실패. /var/log/kubeadm-join.log 확인."
        ok "kubeadm join 완료"
    fi

    run_checks
    rc=$?

    step "다음 단계"
    echo "  이 노드는 아직 CNI 가 없어 NotReady 다. 이 노드에서 60-cilium 을 실행할 것:"
    echo "    sudo ./install.sh --role worker        # 이미지만 적재, helm 은 건드리지 않는다"
    echo "  NFS CSI 를 쓰는 워크로드를 이 노드에 띄우려면 50-nfs-csi 도 같은 방식으로:"
    echo "    sudo ./install.sh --role worker"
    echo
    echo "  control plane 에서 확인:"
    echo "    kubectl get nodes -o wide"
    echo "    kubectl label node ${NODE_NAME} node-role.kubernetes.io/worker=   # 표시용(선택)"
    echo
    echo "  재판정: sudo ./install.sh --check-only"
    exit $rc
fi

#--- 추가 control plane 조인 -------------------------------------------
if [[ "$CP_MODE" == "join" ]]; then
    step "kubeadm join --control-plane (추가 control plane)"

    if [[ -f /etc/kubernetes/admin.conf ]]; then
        warn "이미 control plane 산출물이 있다. join 을 건너뛴다."
        warn "다시 조인하려면: sudo ./install.sh --reset"
    else
        [[ -n "$API_ENDPOINT" && -n "$JOIN_TOKEN" && -n "$CA_CERT_HASH" && -n "$CERT_KEY" ]] \
            || die "$(cat <<'MSG'
CP 조인 정보가 부족하다. 첫 CP 에서 아래를 실행해 출력을 그대로 쓸 것.

  sudo ./install.sh --print-join-command

CP 조인에는 worker 조인의 세 값(엔드포인트·token·CA 해시) 외에
--certificate-key 가 더 필요하다. 그 키로 여는 kubeadm-certs Secret 은
발급 후 2시간이면 사라지므로, 만료됐으면 위 명령을 다시 실행할 것.
MSG
)"
        [[ "$CA_CERT_HASH" == sha256:* ]] \
            || die "--ca-cert-hash 는 sha256: 로 시작해야 한다: ${CA_CERT_HASH}"
        # 32바이트 AES 키의 hex 표현이므로 64자다. 길이를 먼저 보면
        # 잘려서 붙여진 키를 kubeadm 실행 전에 잡을 수 있다.
        grep -qE '^[0-9a-f]{64}$' <<<"$CERT_KEY" \
            || die "--certificate-key 형태가 잘못됐다(64자 hex 여야 한다): ${CERT_KEY}"

        JOIN_HOST="${API_ENDPOINT%:*}"
        JOIN_PORT="${API_ENDPOINT##*:}"
        timeout 8 bash -c ">/dev/tcp/${JOIN_HOST}/${JOIN_PORT}" 2>/dev/null \
            || die "apiserver ${API_ENDPOINT} 에 TCP 연결이 되지 않는다. LB 와 방화벽/NSG 를 확인할 것."
        ok "apiserver ${API_ENDPOINT} 도달 확인"

        # 2379/2380 은 etcd 용이다. CP 끼리 열려 있지 않으면 조인이
        # etcd 멤버 추가 단계에서 멈춘다. 먼저 확인해 원인을 명확히 한다.
        if timeout 5 bash -c ">/dev/tcp/${JOIN_HOST}/2379" 2>/dev/null; then
            ok "기존 CP 의 etcd(2379) 도달 확인"
        else
            warn "기존 CP 의 2379 에 닿지 않는다. LB 를 통한 주소라면 정상일 수 있다."
            log  "  조인이 etcd 단계에서 멈추면 CP 간 2379/2380 방화벽을 확인할 것."
        fi

        sed -e "s@__API_ENDPOINT__@${API_ENDPOINT}@g" \
            -e "s@__TOKEN__@${JOIN_TOKEN}@g" \
            -e "s@__CA_CERT_HASH__@${CA_CERT_HASH}@g" \
            -e "s@__CERT_KEY__@${CERT_KEY}@g" \
            -e "s@__NODE_IP__@${NODE_IP}@g" \
            -e "s@__NODE_NAME__@${NODE_NAME}@g" \
            "${CONF_DIR}/kubeadm-cp-join.yaml" > /tmp/kubeadm-cp-join.yaml
        chmod 0600 /tmp/kubeadm-cp-join.yaml   # certificate-key 가 들어 있다

        systemctl enable kubelet >/dev/null

        log "kubeadm join --control-plane 실행 (로그: /var/log/kubeadm-join.log)"
        kubeadm join --config /tmp/kubeadm-cp-join.yaml \
            2>&1 | tee /var/log/kubeadm-join.log \
            || die "kubeadm join(control-plane) 실패. /var/log/kubeadm-join.log 확인."
        rm -f /tmp/kubeadm-cp-join.yaml
        ok "control plane 조인 완료"
    fi
else
    step "kubeadm init (control plane)"

    if [[ -f /etc/kubernetes/admin.conf ]]; then
        warn "이미 초기화된 클러스터가 있다. init 을 건너뛴다."
        warn "재설치가 필요하면: sudo ./install.sh --reset"
    else
        #--- ClusterConfiguration 렌더링 ---------------------------------
        # controlPlaneEndpoint 와 추가 certSAN 은 있을 때만 넣고, 없으면
        # 자리표시 줄을 지운다. 빈 값을 남기면 YAML 파싱이 깨진다.
        CP_EP_LINE=""
        SAN_LINES=""
        if [[ -n "$CP_ENDPOINT" ]]; then
            CP_EP_LINE="controlPlaneEndpoint: ${CP_ENDPOINT}"
            # LB 주소를 SAN 에 반드시 넣는다. 없으면 그 주소로 접속할 때
            # 인증서 검증이 실패한다.
            SAN_LINES="    - ${CP_ENDPOINT%:*}"
        fi
        if [[ -n "$EXTRA_SANS" ]]; then
            local_ifs="$IFS"; IFS=','
            for san in $EXTRA_SANS; do
                san="$(echo "$san" | tr -d '[:space:]')"
                [[ -n "$san" ]] || continue
                SAN_LINES="${SAN_LINES:+${SAN_LINES}\n}    - ${san}"
            done
            IFS="$local_ifs"
        fi

        # 자리표시 줄 치환. GNU sed 는 치환문의 \n 을 개행으로 넣는다.
        sed -e "s@__NODE_IP__@${NODE_IP}@g" \
            -e "s@__NODE_NAME__@${NODE_NAME}@g" \
            "${CONF_DIR}/kubeadm-init.yaml" > /tmp/kubeadm-init.raw
        if [[ -n "$CP_EP_LINE" ]]; then
            sed -i "s@^__CONTROL_PLANE_ENDPOINT__\$@${CP_EP_LINE}@" /tmp/kubeadm-init.raw
        else
            sed -i '/^__CONTROL_PLANE_ENDPOINT__$/d' /tmp/kubeadm-init.raw
        fi
        if [[ -n "$SAN_LINES" ]]; then
            sed -i "s@^__EXTRA_CERT_SANS__\$@${SAN_LINES}@" /tmp/kubeadm-init.raw
        else
            sed -i '/^__EXTRA_CERT_SANS__$/d' /tmp/kubeadm-init.raw
        fi
        mv /tmp/kubeadm-init.raw /tmp/kubeadm-init.yaml

        # 렌더링 결과를 kubeadm 에게 먼저 검증받는다. 여기서 걸러내면
        # init 이 절반 진행된 상태로 실패하는 일을 막을 수 있다.
        kubeadm config validate --config /tmp/kubeadm-init.yaml >/dev/null 2>&1 \
            || die "생성된 kubeadm 설정이 유효하지 않다. 내용: /tmp/kubeadm-init.yaml"
        ok "kubeadm 설정 검증 통과"

        if [[ -n "$CP_ENDPOINT" ]]; then
            log "controlPlaneEndpoint = ${CP_ENDPOINT} (다중 CP 가능)"
            # LB 가 아직 없어도 init 자체는 된다. 하지만 CP 를 추가할 때
            # 반드시 필요하므로 지금 상태를 알려 준다.
            if timeout 5 bash -c ">/dev/tcp/${CP_ENDPOINT%:*}/${CP_ENDPOINT##*:}" 2>/dev/null; then
                ok "엔드포인트 ${CP_ENDPOINT} 가 이미 열려 있다"
            else
                warn "엔드포인트 ${CP_ENDPOINT} 에 지금은 닿지 않는다."
                log  "  이 노드의 apiserver 가 뜨면 LB 가 이쪽으로 넘겨야 한다. README 4.0.1절."
            fi
        else
            log "단일 CP 모드 — controlPlaneEndpoint 없음. 나중에 CP 를 추가할 수 없다."
        fi

        systemctl enable kubelet >/dev/null

        log "kubeadm init 실행 (로그: /var/log/kubeadm-init.log)"
        # HA 인 경우 --upload-certs 로 CA 등을 Secret 에 올려둔다.
        # 이것이 있어야 추가 CP 가 certificate-key 로 인증서를 내려받는다.
        # 이미지 pull 은 이미 적재됐으므로 발생하지 않는다.
        INIT_EXTRA=()
        [[ -n "$CP_ENDPOINT" ]] && INIT_EXTRA+=(--upload-certs)
        kubeadm init --config /tmp/kubeadm-init.yaml \
                     --skip-token-print \
                     "${INIT_EXTRA[@]}" \
                     2>&1 | tee /var/log/kubeadm-init.log \
            || die "kubeadm init 실패. /var/log/kubeadm-init.log 확인."
        ok "kubeadm init 완료"
    fi
fi

#=====================================================================
# 7. kubeconfig / 단일 노드 taint 제거
#=====================================================================
step "kubeconfig 및 단일 노드 설정"

export KUBECONFIG=/etc/kubernetes/admin.conf

if [[ "$TARGET_USER" != "root" && -n "$TARGET_HOME" ]]; then
    install -d -o "$TARGET_USER" -g "$TARGET_USER" -m 0700 "${TARGET_HOME}/.kube"
    install -o "$TARGET_USER" -g "$TARGET_USER" -m 0600 \
        /etc/kubernetes/admin.conf "${TARGET_HOME}/.kube/config"
    ok "kubeconfig -> ${TARGET_HOME}/.kube/config (${TARGET_USER})"
fi

# taint 처리.
#   remove : 단일 노드. 제거해야 워크로드가 스케줄된다.
#   keep   : 다중 노드. CP 에 일반 워크로드를 올리지 않는다. 이것을 풀면
#            CP 가 워크로드 부하를 같이 받아 etcd 지연으로 이어질 수 있다.
if [[ "$TAINT_POLICY" == "remove" ]]; then
    if kubectl get nodes -o jsonpath='{.items[*].spec.taints[*].key}' | grep -q node-role.kubernetes.io/control-plane; then
        # --all 이 아니라 이 노드만 대상으로 한다. 다중 노드 클러스터에서
        # 실수로 --untaint 를 줬을 때 다른 CP 까지 풀어버리지 않도록.
        kubectl taint node "$NODE_NAME" node-role.kubernetes.io/control-plane- >/dev/null 2>&1 \
            || kubectl taint nodes --all node-role.kubernetes.io/control-plane- >/dev/null
        ok "control-plane taint 제거 (${NODE_NAME})"
    else
        ok "control-plane taint 없음"
    fi
else
    ok "control-plane taint 유지 (다중 노드 정책)"
    log "  이 CP 에 워크로드를 올리려면: kubectl taint node ${NODE_NAME} node-role.kubernetes.io/control-plane-"
fi

#=====================================================================
# 8. 판정
#=====================================================================
run_checks
rc=$?

step "다음 단계"
echo "  CNI 가 없어 노드는 NotReady, CoreDNS 는 Pending 이다. 정상이다."
echo "  60-cilium 번들을 적용하면 Ready 로 전환된다."
echo
echo "  노드를 추가하려면 이 노드에서 조인 명령을 발급한다:"
echo "    sudo ./install.sh --print-join-command"
echo "  worker 와 CP 각각의 명령을 함께 출력한다."
echo
if [[ -z "$(cluster_cp_endpoint)" ]]; then
echo "  주의: controlPlaneEndpoint 가 없어 CP 는 추가할 수 없다(worker 는 가능)."
echo "        CP 를 늘릴 계획이면 --reset 후 아래처럼 다시 init 할 것:"
echo "          sudo ./install.sh --control-plane-endpoint <LB주소>:6443"
echo
fi
echo "  상태 확인:  kubectl get nodes -o wide ; kubectl -n kube-system get pods"
echo "  재판정:     sudo ./install.sh --check-only"
echo "  정리:       sudo ./install.sh --reset"
exit $rc
