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
#   sudo ./install.sh --check-only    # 설치 없이 현재 상태만 판정(역할 자동 판별)
#   sudo ./install.sh --reset         # kubeadm reset + 설정 정리
#
# 결과:
#   control plane : 단일 노드 control plane. CNI 가 없으므로 노드는 NotReady 다.
#                   이것이 정상이며 60-cilium 을 적용하면 Ready 로 전환된다.
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

usage() {
    sed -n '3,30p' "${BASH_SOURCE[0]}" | sed 's/^#//'
}

while (($#)); do
    case "$1" in
        --check-only)     MODE="check" ;;
        --reset)          MODE="reset" ;;
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
    check "apiserver 응답(6443)"   bash -c "timeout 10 kubectl --kubeconfig /etc/kubernetes/admin.conf get --raw /healthz >/dev/null"

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
        check "control-plane taint 제거됨(단일 노드 스케줄 가능)" bash -c "
            ! kubectl get nodes -o jsonpath='{.items[*].spec.taints[*].key}' 2>/dev/null \
              | grep -q node-role.kubernetes.io/control-plane"

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
    if [[ "$ROLE" == "worker" ]]; then
        warn "이 노드를 클러스터에서 떼어낸다. 5초 후 진행. 중단하려면 Ctrl-C."
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
    if [[ "$ROLE" == "worker" ]]; then
        echo
        log "control plane 에서 노드 객체도 지울 것:  kubectl delete node ${NODE_NAME}"
    fi
    exit 0
}

[[ "$MODE" == "reset" ]] && do_reset
if [[ "$MODE" == "check" ]]; then run_checks; exit $?; fi

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

step "kubeadm init (control plane)"

if [[ -f /etc/kubernetes/admin.conf ]]; then
    warn "이미 초기화된 클러스터가 있다. init 을 건너뛴다."
    warn "재설치가 필요하면: sudo ./install.sh --reset"
else
    sed -e "s@__NODE_IP__@${NODE_IP}@g" \
        -e "s@__NODE_NAME__@${NODE_NAME}@g" \
        "${CONF_DIR}/kubeadm-init.yaml" > /tmp/kubeadm-init.yaml

    systemctl enable kubelet >/dev/null

    log "kubeadm init 실행 (로그: /var/log/kubeadm-init.log)"
    # --upload-certs 불필요(단일 CP). 이미지 pull 은 이미 적재됐으므로 발생하지 않는다.
    kubeadm init --config /tmp/kubeadm-init.yaml \
                 --skip-token-print \
                 2>&1 | tee /var/log/kubeadm-init.log \
        || die "kubeadm init 실패. /var/log/kubeadm-init.log 확인."
    ok "kubeadm init 완료"
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

# 단일 노드이므로 control-plane taint 를 제거해야 워크로드가 스케줄된다.
if kubectl get nodes -o jsonpath='{.items[*].spec.taints[*].key}' | grep -q node-role.kubernetes.io/control-plane; then
    kubectl taint nodes --all node-role.kubernetes.io/control-plane- >/dev/null
    ok "control-plane taint 제거"
else
    ok "control-plane taint 없음"
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
echo "  worker 를 추가하려면 이 노드에서 조인 명령을 발급한다:"
echo "    sudo kubeadm token create --print-join-command"
echo "  그 출력을 worker 에서 그대로 넘긴다:"
echo "    sudo ./install.sh --role worker --join-command \"<위 출력>\""
echo
echo "  상태 확인:  kubectl get nodes -o wide ; kubectl -n kube-system get pods"
echo "  재판정:     sudo ./install.sh --check-only"
echo "  정리:       sudo ./install.sh --reset"
exit $rc
