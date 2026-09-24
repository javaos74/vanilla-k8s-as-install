#!/usr/bin/env bash
# Prepare an Ubuntu 22.04 node for kubeadm (Kubernetes v1.36).
# Idempotent: safe to re-run.
# Usage: sudo ./prep-node.sh <desired-hostname>
set -euo pipefail

NEW_HOSTNAME="${1:?usage: prep-node.sh <hostname>}"
K8S_MINOR="v1.36"
K8S_PKG_VERSION="1.36.4-1.1"

export DEBIAN_FRONTEND=noninteractive

log() { echo "[prep][$(hostname)] $*"; }

# --- make apt block on the dpkg lock instead of failing --------------------
# unattended-upgrades runs on these AMIs and races with us otherwise.
echo 'DPkg::Lock::Timeout "900";' > /etc/apt/apt.conf.d/99-lock-timeout

wait_for_apt() {
  local i=0
  while fuser /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock >/dev/null 2>&1; do
    i=$((i+1)); [ "$i" -gt 120 ] && { log "apt lock still held after 10min"; break; }
    log "waiting for apt lock..."; sleep 5
  done
}

# --- 1. hostname -------------------------------------------------------------
if [ "$(hostname)" != "$NEW_HOSTNAME" ]; then
  log "setting hostname -> $NEW_HOSTNAME"
  hostnamectl set-hostname "$NEW_HOSTNAME"
fi
PRIV_IP="$(ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1 | head -1)"
grep -q "[[:space:]]$NEW_HOSTNAME\$" /etc/hosts || echo "$PRIV_IP $NEW_HOSTNAME" >> /etc/hosts

# --- 2. swap off -------------------------------------------------------------
log "disabling swap"
swapoff -a || true
sed -i.bak -E 's@^([^#].*[[:space:]]swap[[:space:]].*)$@#\1@' /etc/fstab

# --- 3. kernel modules -------------------------------------------------------
log "configuring kernel modules"
cat > /etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter

# --- 4. sysctl ---------------------------------------------------------------
log "configuring sysctl"
cat > /etc/sysctl.d/99-kubernetes-cri.conf <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system >/dev/null

# --- 5. base packages + apt repos -------------------------------------------
wait_for_apt
log "installing base packages"
apt-get update -qq
apt-get install -y -qq apt-transport-https ca-certificates curl gnupg lsb-release conntrack socat ethtool

install -m 0755 -d /etc/apt/keyrings

# Docker repo (for containerd.io)
if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
fi
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
  > /etc/apt/sources.list.d/docker.list

# Kubernetes repo
if [ ! -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg ]; then
  curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/Release.key" \
    | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
  chmod a+r /etc/apt/keyrings/kubernetes-apt-keyring.gpg
fi
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/ /" \
  > /etc/apt/sources.list.d/kubernetes.list

apt-get update -qq

# --- 6. containerd -----------------------------------------------------------
log "installing containerd"
apt-get install -y -qq containerd.io

# Regenerate a default config once, then enforce SystemdCgroup.
if [ ! -f /etc/containerd/config.toml.k8s-managed ]; then
  mkdir -p /etc/containerd
  containerd config default > /etc/containerd/config.toml
  touch /etc/containerd/config.toml.k8s-managed
fi
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
grep -q 'SystemdCgroup = true' /etc/containerd/config.toml || { echo "FATAL: SystemdCgroup not set"; exit 1; }

systemctl daemon-reload
systemctl enable --now containerd
systemctl restart containerd

# --- 7. kubeadm / kubelet / kubectl -----------------------------------------
log "installing kubelet/kubeadm/kubectl ${K8S_PKG_VERSION}"
apt-mark unhold kubelet kubeadm kubectl 2>/dev/null || true
apt-get install -y -qq --allow-change-held-packages \
  "kubelet=${K8S_PKG_VERSION}" "kubeadm=${K8S_PKG_VERSION}" "kubectl=${K8S_PKG_VERSION}"
apt-mark hold kubelet kubeadm kubectl >/dev/null
systemctl enable kubelet >/dev/null 2>&1 || true

# --- 8. align containerd sandbox image with kubeadm's expectation -----------
PAUSE_IMG="$(kubeadm config images list 2>/dev/null | grep -m1 'pause' || true)"
if [ -n "$PAUSE_IMG" ]; then
  log "setting containerd sandbox_image = $PAUSE_IMG"
  if grep -qE '^\s*sandbox_image\s*=' /etc/containerd/config.toml; then
    sed -i -E "s|^(\s*)sandbox_image\s*=.*|\1sandbox_image = '${PAUSE_IMG}'|" /etc/containerd/config.toml
  elif grep -qE '^\s*sandbox\s*=' /etc/containerd/config.toml; then
    sed -i -E "s|^(\s*)sandbox\s*=.*|\1sandbox = '${PAUSE_IMG}'|" /etc/containerd/config.toml
  fi
  systemctl restart containerd
fi

# --- 9. crictl endpoint ------------------------------------------------------
cat > /etc/crictl.yaml <<'EOF'
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
EOF

# --- 10. report --------------------------------------------------------------
log "=== RESULT ==="
log "hostname       : $(hostname)"
log "private ip     : ${PRIV_IP}"
log "swap           : $(swapon --show --noheadings | wc -l) active entries"
log "containerd     : $(containerd --version | awk '{print $3}') / $(systemctl is-active containerd)"
log "cgroup driver  : $(grep -c 'SystemdCgroup = true' /etc/containerd/config.toml) systemd entries"
log "kubeadm        : $(kubeadm version -o short)"
log "kubelet        : $(kubelet --version | awk '{print $2}')"
log "crictl runtime : $(crictl version 2>/dev/null | grep RuntimeVersion || echo 'n/a')"
log "ip_forward     : $(sysctl -n net.ipv4.ip_forward)"
log "nf-call-ipt    : $(sysctl -n net.bridge.bridge-nf-call-iptables)"
log "done"
