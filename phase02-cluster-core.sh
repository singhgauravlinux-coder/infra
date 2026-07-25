#!/usr/bin/env bash
# =============================================================================
# Phase 2 — Cluster Core
#   1. Traefik (ingress controller, replaces disabled k3s built-in)
#   2. cert-manager
#   3. Wildcard TLS for *.microsvc.store via DNS-01 (ClusterIssuer)
#   4. Rancher (multi-cluster management UI)
#   5. ExternalDNS (auto-manage DNS records for Ingress/Service objects)
# =============================================================================
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../lib/common.sh"
load_config
export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"

# -----------------------------------------------------------------------------
# Step: Traefik ingress controller
# -----------------------------------------------------------------------------
step_traefik() {
  helm repo add traefik https://traefik.github.io/charts >/dev/null 2>&1 || true
  retry 3 10 -- helm repo update traefik

  cat >/tmp/traefik-values.yaml <<EOF
deployment:
  replicas: 2
service:
  type: LoadBalancer
ports:
  web:
    redirectTo:
      port: websecure
  websecure:
    tls:
      enabled: true
podDisruptionBudget:
  enabled: true
  minAvailable: 1
resources:
  requests: {cpu: 100m, memory: 128Mi}
  limits: {cpu: 500m, memory: 512Mi}
metrics:
  prometheus:
    addEntryPointsLabels: true
    addRoutersLabels: true
    addServicesLabels: true
providers:
  kubernetesIngress:
    publishedService:
      enabled: true
EOF

  helm_upgrade_install traefik traefik/traefik "${NS_INGRESS}" /tmp/traefik-values.yaml \
    --version "${TRAEFIK_CHART_VERSION}"

  rollout_wait deployment traefik "${NS_INGRESS}" 300s
  log "Traefik ingress controller is ready."
}

# -----------------------------------------------------------------------------
# Step: cert-manager
# -----------------------------------------------------------------------------
step_cert_manager() {
  helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
  retry 3 10 -- helm repo update jetstack

  helm_upgrade_install cert-manager jetstack/cert-manager "${NS_CERT_MANAGER}" - \
    --version "${CERT_MANAGER_VERSION}" \
    --set crds.enabled=true \
    --set prometheus.enabled=true

  rollout_wait deployment cert-manager "${NS_CERT_MANAGER}" 180s
  rollout_wait deployment cert-manager-webhook "${NS_CERT_MANAGER}" 180s
  rollout_wait deployment cert-manager-cainjector "${NS_CERT_MANAGER}" 180s
  log "cert-manager is ready."
}

# -----------------------------------------------------------------------------
# Step: wildcard TLS via DNS-01 ClusterIssuer
#   NOTE: requires the DNS API token secret to already exist:
#     kubectl -n cert-manager create secret generic cloudflare-api-token \
#       --from-literal=api-token=<token>
# -----------------------------------------------------------------------------
step_wildcard_tls() {
  kubectl -n "${NS_CERT_MANAGER}" get secret "${CLOUDFLARE_API_TOKEN_SECRET_NAME}" >/dev/null 2>&1 \
    || fatal "Missing secret '${CLOUDFLARE_API_TOKEN_SECRET_NAME}' in ${NS_CERT_MANAGER}. \
Create it first: kubectl -n ${NS_CERT_MANAGER} create secret generic ${CLOUDFLARE_API_TOKEN_SECRET_NAME} --from-literal=api-token=<TOKEN>"

  cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-dns
spec:
  acme:
    email: ${ACME_EMAIL}
    server: https://acme-v02.api.letsencrypt.org/directory
    privateKeySecretRef:
      name: letsencrypt-dns-account-key
    solvers:
      - dns01:
          cloudflare:
            apiTokenSecretRef:
              name: ${CLOUDFLARE_API_TOKEN_SECRET_NAME}
              key: api-token
EOF

  cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: wildcard-microsvc-store
  namespace: ${NS_INGRESS}
spec:
  secretName: wildcard-microsvc-store-tls
  issuerRef:
    name: letsencrypt-dns
    kind: ClusterIssuer
  dnsNames:
    - "${BASE_DOMAIN}"
    - "*.${BASE_DOMAIN}"
EOF

  retry 30 15 -- bash -c \
    "kubectl -n ${NS_INGRESS} get certificate wildcard-microsvc-store -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' | grep -q True"

  log "Wildcard certificate for *.${BASE_DOMAIN} issued and Ready."
}

# -----------------------------------------------------------------------------
# Step: ExternalDNS
# -----------------------------------------------------------------------------
step_externaldns() {
  kubectl -n "${NS_EXTERNAL_DNS}" get secret "${CLOUDFLARE_API_TOKEN_SECRET_NAME}" >/dev/null 2>&1 || \
    kubectl create namespace "${NS_EXTERNAL_DNS}" --dry-run=client -o yaml | kubectl apply -f -

  helm repo add external-dns https://kubernetes-sigs.github.io/external-dns/ >/dev/null 2>&1 || true
  retry 3 10 -- helm repo update external-dns

  cat >/tmp/externaldns-values.yaml <<EOF
provider: ${DNS_PROVIDER}
env:
  - name: CF_API_TOKEN
    valueFrom:
      secretKeyRef:
        name: ${CLOUDFLARE_API_TOKEN_SECRET_NAME}
        key: api-token
domainFilters: ["${BASE_DOMAIN}"]
policy: sync
sources: ["ingress", "service"]
txtOwnerId: "microsvc-store-k3s"
interval: 1m
EOF

  helm_upgrade_install external-dns external-dns/external-dns "${NS_EXTERNAL_DNS}" /tmp/externaldns-values.yaml \
    --version "${EXTERNALDNS_CHART_VERSION}"

  rollout_wait deployment external-dns "${NS_EXTERNAL_DNS}" 180s
  log "ExternalDNS deployed and syncing records for ${BASE_DOMAIN}."
}

# -----------------------------------------------------------------------------
# Step: Rancher
# -----------------------------------------------------------------------------
step_rancher() {
  helm repo add rancher-stable https://releases.rancher.com/server-charts/stable >/dev/null 2>&1 || true
  retry 3 10 -- helm repo update rancher-stable

  helm_upgrade_install rancher rancher-stable/rancher "${NS_CATTLE_SYSTEM}" - \
    --version "${RANCHER_CHART_VERSION}" \
    --set hostname="${RANCHER_HOST}" \
    --set replicas=2 \
    --set ingress.tls.source=secret \
    --set ingress.tls.secretName=wildcard-microsvc-store-tls \
    --set letsEncrypt.ingress.class=traefik

  rollout_wait deployment rancher "${NS_CATTLE_SYSTEM}" 300s

  retry 10 10 -- http_check "https://${RANCHER_HOST}" 200 15

  log "Rancher is ready at https://${RANCHER_HOST}"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
  acquire_lock
  log "=== Phase 2: Cluster Core — starting ==="

  run_step "p2_traefik"       step_traefik
  run_step "p2_cert_manager"  step_cert_manager
  run_step "p2_wildcard_tls"  step_wildcard_tls
  run_step "p2_externaldns"   step_externaldns
  run_step "p2_rancher"       step_rancher

  clear_rollback_stack
  log "=== Phase 2: Cluster Core — COMPLETE ==="
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
