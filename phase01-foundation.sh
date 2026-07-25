#!/usr/bin/env bash
# =============================================================================
# Phase 1 — Foundation
#   1. Ubuntu preparation (packages, users, firewall baseline, unattended-upgrades)
#   2. System updates
#   3. Kernel / sysctl tuning for Kubernetes + workloads
#   4. K3s installation (single control-plane; HA-ready flags noted inline)
#   5. Storage class validation (Longhorn as default StorageClass)
# =============================================================================
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../lib/common.sh"
load_config

# -----------------------------------------------------------------------------
# Step: preflight
# -----------------------------------------------------------------------------
step_preflight() {
  require_root
  . /etc/os-release
  [[ "${ID}" == "ubuntu" ]] || fatal "This platform targets Ubuntu Server only (found: ${ID})."
  local major="${VERSION_ID%%.*}"
  (( major >= 22 )) || fatal "Ubuntu 22.04+ required (found ${VERSION_ID})."
  check_min_resources "${MIN_CPU_CORES}" "${MIN_MEM_GB}" "${MIN_DISK_GB}"
  require_cmd curl awk grep sed systemctl
  log "Preflight checks passed on Ubuntu ${VERSION_ID}."
}

# -----------------------------------------------------------------------------
# Step: system update + baseline packages
# -----------------------------------------------------------------------------
step_system_update() {
  export DEBIAN_FRONTEND=noninteractive
  retry 3 10 -- apt-get update -y
  retry 3 10 -- apt-get -o Dpkg::Options::="--force-confold" upgrade -y
  retry 3 10 -- apt-get install -y \
    curl wget git jq unzip tar gnupg ca-certificates apt-transport-https \
    software-properties-common open-iscsi nfs-common conntrack socat \
    chrony unattended-upgrades fail2ban ufw auditd openssl dnsutils htop

  # unattended security upgrades
  cat >/etc/apt/apt.conf.d/51platform-unattended <<'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
};
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF
  systemctl enable --now unattended-upgrades
  systemctl enable --now chrony
  log "System packages updated and baseline hardening packages installed."
}

# -----------------------------------------------------------------------------
# Step: firewall baseline (ufw) — K3s + platform ports only
# -----------------------------------------------------------------------------
step_firewall() {
  push_rollback "ufw --force reset"

  ufw --force reset
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow OpenSSH
  ufw allow 80/tcp    comment 'HTTP (Traefik)'
  ufw allow 443/tcp   comment 'HTTPS (Traefik)'
  ufw allow 6443/tcp  comment 'K3s API server'
  ufw allow 8472/udp  comment 'K3s Flannel VXLAN'
  ufw allow 10250/tcp comment 'Kubelet metrics'
  ufw allow from 10.42.0.0/16 comment 'K3s pod CIDR'
  ufw allow from 10.43.0.0/16 comment 'K3s service CIDR'
  ufw --force enable
  ufw status verbose | tee -a "${LOG_FILE}"
  log "UFW firewall baseline applied."
}

# -----------------------------------------------------------------------------
# Step: kernel / sysctl tuning for Kubernetes
# -----------------------------------------------------------------------------
step_kernel_tuning() {
  push_rollback "rm -f /etc/sysctl.d/99-platform-k8s.conf && sysctl --system"

  modprobe overlay || true
  modprobe br_netfilter || true
  cat >/etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF

  cat >/etc/sysctl.d/99-platform-k8s.conf <<'EOF'
# --- Kubernetes networking prerequisites ---
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1

# --- Connection tracking / scale ---
net.netfilter.nf_conntrack_max      = 1048576
net.ipv4.tcp_keepalive_time         = 300
net.ipv4.tcp_keepalive_intvl        = 30
net.ipv4.tcp_keepalive_probes       = 5

# --- File descriptors / inotify (etcd, many watchers) ---
fs.file-max                    = 2097152
fs.inotify.max_user_instances  = 8192
fs.inotify.max_user_watches    = 1048576

# --- Virtual memory (databases, etcd fsync latency) ---
vm.swappiness       = 0
vm.max_map_count    = 262144
vm.overcommit_memory = 1

# --- Ephemeral ports for high connection churn ---
net.ipv4.ip_local_port_range = 1024 65535
EOF
  retry 3 3 -- sysctl --system

  # disable swap permanently (kubelet requirement)
  swapoff -a
  sed -i.bak '/\sswap\s/s/^/#/' /etc/fstab

  log "Kernel modules and sysctl tuning applied; swap disabled."
}

# -----------------------------------------------------------------------------
# Step: install K3s (server) — single control-plane, embedded etcd disabled
#        (using default sqlite for single-node; flip to --cluster-init for HA)
# -----------------------------------------------------------------------------
step_install_k3s() {
  if command -v k3s >/dev/null 2>&1; then
    log "K3s binary already present — verifying service health instead of reinstalling."
  else
    push_rollback "/usr/local/bin/k3s-uninstall.sh || true"
    retry 3 15 -- bash -c "curl -sfL https://get.k3s.io | \
      INSTALL_K3S_CHANNEL='${K3S_CHANNEL}' \
      INSTALL_K3S_EXEC='server \
        --disable traefik \
        --disable servicelb \
        --write-kubeconfig-mode 644 \
        --node-taint CriticalAddonsOnly=true:NoExecute- \
        --kube-apiserver-arg=audit-log-path=/var/log/k3s-audit.log \
        --kube-apiserver-arg=audit-log-maxage=30 \
        --etcd-expose-metrics=true' \
      sh -"
  fi

  mkdir -p "${HOME}/.kube"
  cp /etc/rancher/k3s/k3s.yaml "${HOME}/.kube/config"
  chown "$(id -u)":"$(id -g)" "${HOME}/.kube/config"
  export KUBECONFIG="${HOME}/.kube/config"
  echo "export KUBECONFIG=${HOME}/.kube/config" > /etc/profile.d/kubeconfig.sh

  retry 10 6 -- kubectl get --raw='/readyz'
  retry 10 6 -- kubectl wait --for=condition=Ready node --all --timeout=180s

  log "K3s installed and node is Ready."
  kubectl get nodes -o wide | tee -a "${LOG_FILE}"
}

# -----------------------------------------------------------------------------
# Step: install helm
# -----------------------------------------------------------------------------
step_install_helm() {
  if command -v helm >/dev/null 2>&1; then
    log "Helm already installed: $(helm version --short)"
    return 0
  fi
  local tmp; tmp=$(mktemp -d)
  retry 3 10 -- curl -fsSL -o "${tmp}/helm.tar.gz" \
    "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz"
  tar -xzf "${tmp}/helm.tar.gz" -C "${tmp}"
  install -o root -g root -m 0755 "${tmp}/linux-amd64/helm" /usr/local/bin/helm
  rm -rf "${tmp}"
  log "Helm ${HELM_VERSION} installed: $(helm version --short)"
}

# -----------------------------------------------------------------------------
# Step: Longhorn distributed storage + default StorageClass validation
# -----------------------------------------------------------------------------
step_storage_class() {
  retry 3 10 -- apt-get install -y open-iscsi nfs-common
  systemctl enable --now iscsid

  helm repo add longhorn https://charts.longhorn.io >/dev/null 2>&1 || true
  retry 3 10 -- helm repo update longhorn

  helm_upgrade_install longhorn longhorn/longhorn longhorn-system - \
    --version "${LONGHORN_CHART_VERSION}" \
    --set defaultSettings.defaultReplicaCount="${STORAGE_REPLICA_COUNT}" \
    --set persistence.defaultClassReplicaCount="${STORAGE_REPLICA_COUNT}"

  kubectl patch storageclass longhorn \
    -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

  # remove default-class annotation from local-path if present, to avoid two defaults
  kubectl patch storageclass local-path \
    -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}' \
    2>/dev/null || true

  # validation: provision a throwaway PVC and confirm it binds
  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: storage-validation
  namespace: default
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: ${DEFAULT_STORAGE_CLASS}
  resources:
    requests:
      storage: 1Gi
EOF
  retry 10 6 -- kubectl get pvc storage-validation -o jsonpath='{.status.phase}' | grep -q Bound
  kubectl delete pvc storage-validation --ignore-not-found

  log "Longhorn installed; '${DEFAULT_STORAGE_CLASS}' validated as default StorageClass."
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
  acquire_lock
  log "=== Phase 1: Foundation — starting ==="

  run_step "p1_preflight"        step_preflight
  run_step "p1_system_update"    step_system_update
  run_step "p1_firewall"         step_firewall
  run_step "p1_kernel_tuning"    step_kernel_tuning
  run_step "p1_install_k3s"      step_install_k3s
  run_step "p1_install_helm"     step_install_helm
  run_step "p1_storage_class"    step_storage_class

  clear_rollback_stack   # phase completed cleanly — don't unwind on later phases' errors
  log "=== Phase 1: Foundation — COMPLETE ==="
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
