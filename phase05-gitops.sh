#!/usr/bin/env bash
# =============================================================================
# Phase 5 — GitOps
#   1. Argo CD             — installed via Helm, exposed at argocd.microsvc.store
#   2. Repository structure — app-of-apps layout pushed to GitLab (platform/gitops-config)
#   3. Application bootstrap — root Application pointing at that repo
#   4. Argo Rollouts        — canary/blue-green primitives for progressive delivery
# =============================================================================
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../lib/common.sh"
load_config
export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"

# -----------------------------------------------------------------------------
# Step: Argo CD
# -----------------------------------------------------------------------------
step_argocd() {
  ensure_namespace "${NS_ARGOCD}"
  local admin_pass
  admin_pass=$(get_or_create_secret_value "${NS_ARGOCD}" "argocd-initial-admin" "password" 24)
  # Argo CD reads bcrypt hash from argocd-secret; helm chart handles bootstrap
  # hashing when admin.password is provided directly, so pass it through here.

  helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
  retry 3 10 -- helm repo update argo

  cat >/tmp/argocd-values.yaml <<EOF
global:
  domain: ${ARGOCD_HOST}
server:
  ingress:
    enabled: true
    ingressClassName: traefik
    tls: true
    extraTls:
      - hosts: ["${ARGOCD_HOST}"]
        secretName: wildcard-microservice-in-tls
  replicas: 2
controller:
  replicas: 1
repoServer:
  replicas: 2
applicationSet:
  enabled: true
redis-ha:
  enabled: false
configs:
  params:
    server.insecure: false
EOF

  helm_upgrade_install argocd argo/argo-cd "${NS_ARGOCD}" /tmp/argocd-values.yaml \
    --version "${ARGOCD_CHART_VERSION}" \
    --set-string "configs.secret.argocdServerAdminPassword=$(python3 - <<PYEOF
import bcrypt, sys
print(bcrypt.hashpw("${admin_pass}".encode(), bcrypt.gensalt(rounds=10)).decode())
PYEOF
)"

  rollout_wait deployment argocd-server "${NS_ARGOCD}" 300s
  rollout_wait deployment argocd-repo-server "${NS_ARGOCD}" 180s
  retry 10 10 -- http_check "https://${ARGOCD_HOST}" 200 15

  log "Argo CD ready at https://${ARGOCD_HOST} (admin password in secret argocd-initial-admin)."
}

# -----------------------------------------------------------------------------
# Step: GitOps repository structure — pushed to GitLab as the source of truth
# -----------------------------------------------------------------------------
step_gitops_repo_structure() {
  local workdir="/tmp/gitops-config-bootstrap"
  rm -rf "${workdir}"
  mkdir -p "${workdir}"/{apps,infrastructure,environments/{dev,staging,production}}

  cat > "${workdir}/README.md" <<'EOF'
# gitops-config

App-of-apps GitOps source of truth for the microsvc.store platform.

- `infrastructure/` — cluster-scoped platform components (ingress, cert-manager
  policies, monitoring stack config) managed as Argo CD Applications.
- `apps/`           — one directory per microservice, each with its own
  `application.yaml` pointing at that service's Helm chart/kustomize overlay.
- `environments/`   — per-environment value overlays (dev/staging/production),
  referenced by the Applications above via Helm value files or Kustomize patches.
EOF

  cat > "${workdir}/root-app-of-apps.yaml" <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root-app-of-apps
  namespace: ${NS_ARGOCD}
  finalizers: ["resources-finalizer.argocd.argoproj.io"]
spec:
  project: default
  source:
    repoURL: ${GITOPS_REPO_URL}
    targetRevision: main
    path: apps
    directory:
      recurse: true
  destination:
    server: https://kubernetes.default.svc
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
EOF

  mkdir -p "${workdir}/apps/example-microservice"
  cat > "${workdir}/apps/example-microservice/application.yaml" <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: example-microservice
  namespace: ${NS_ARGOCD}
spec:
  project: default
  source:
    repoURL: https://${GITLAB_HOST}/platform/example-microservice.git
    targetRevision: main
    path: deploy/helm
    helm:
      valueFiles: ["../../environments/production/values.yaml"]
  destination:
    server: https://kubernetes.default.svc
    namespace: apps
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
EOF

  for env in dev staging production; do
    cat > "${workdir}/environments/${env}/values.yaml" <<EOF
# ${env} overlay — replicas/resources/feature-flags specific to ${env}
replicaCount: $( [[ "${env}" == "production" ]] && echo 3 || echo 1 )
EOF
  done

  cd "${workdir}"
  git init -q -b main
  git add -A
  git -c user.email="platform-bot@microsvc.store" -c user.name="platform-bot" \
    commit -q -m "chore: bootstrap gitops-config app-of-apps layout"

  local root_pass token
  root_pass=$(kubectl -n "${NS_DEVOPS}" get secret gitlab-gitlab-initial-root-password -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)
  if [[ -z "${root_pass}" ]]; then
    warn "GitLab root secret not found — is Phase 4 complete? Skipping repo push;"
    warn "the layout is staged locally at ${workdir} for manual push."
    return 0
  fi

  token=$(curl -sk -X POST "https://${GITLAB_HOST}/oauth/token" \
    -d "grant_type=password&username=root&password=${root_pass}" | jq -r '.access_token')

  curl -sk -X POST "https://${GITLAB_HOST}/api/v4/groups" \
    -H "Authorization: Bearer ${token}" -d "name=platform&path=platform" >/dev/null 2>&1 || true

  curl -sk -X POST "https://${GITLAB_HOST}/api/v4/projects" \
    -H "Authorization: Bearer ${token}" \
    -d "name=gitops-config&namespace_id=$(curl -sk -H "Authorization: Bearer ${token}" \
        "https://${GITLAB_HOST}/api/v4/groups/platform" | jq -r '.id')" >/dev/null 2>&1 || true

  git remote add origin "https://root:${root_pass}@${GITLAB_HOST}/platform/gitops-config.git" 2>/dev/null || true
  retry 5 10 -- git push -u origin main --force

  log "gitops-config repository structure pushed to ${GITOPS_REPO_URL}"
}

# -----------------------------------------------------------------------------
# Step: Application bootstrap (root app-of-apps)
# -----------------------------------------------------------------------------
step_application_bootstrap() {
  kubectl apply -f /tmp/gitops-config-bootstrap/root-app-of-apps.yaml

  retry 20 15 -- bash -c \
    "kubectl -n ${NS_ARGOCD} get application root-app-of-apps -o jsonpath='{.status.sync.status}' | grep -q Synced"

  log "Root app-of-apps Application synced — Argo CD now manages apps/ from GitOps repo."
}

# -----------------------------------------------------------------------------
# Step: Argo Rollouts (progressive delivery primitives)
# -----------------------------------------------------------------------------
step_argo_rollouts() {
  helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
  retry 3 10 -- helm repo update argo

  helm_upgrade_install argo-rollouts argo/argo-rollouts "${NS_ARGOCD}" - \
    --version "${ARGO_ROLLOUTS_CHART_VERSION}" \
    --set dashboard.enabled=true

  rollout_wait deployment argo-rollouts "${NS_ARGOCD}" 180s

  # Example canary Rollout + Traefik-backed traffic split, used as a template
  # by apps/ that want progressive delivery instead of a plain Deployment.
  cat > /tmp/example-canary-rollout.yaml <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: example-microservice
  namespace: apps
spec:
  replicas: 3
  strategy:
    canary:
      steps:
        - setWeight: 20
        - pause: {duration: 5m}
        - setWeight: 50
        - pause: {duration: 5m}
        - setWeight: 100
  selector:
    matchLabels: {app: example-microservice}
  template:
    metadata:
      labels: {app: example-microservice}
    spec:
      containers:
        - name: app
          image: harbor.microsvc.store/platform/example-microservice:latest
          ports: [{containerPort: 8080}]
EOF

  log "Argo Rollouts installed; example canary template staged at /tmp/example-canary-rollout.yaml"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
  acquire_lock
  log "=== Phase 5: GitOps — starting ==="

  run_step "p5_argocd"                  step_argocd
  run_step "p5_gitops_repo_structure"   step_gitops_repo_structure
  run_step "p5_application_bootstrap"   step_application_bootstrap
  run_step "p5_argo_rollouts"           step_argo_rollouts

  clear_rollback_stack
  log "=== Phase 5: GitOps — COMPLETE ==="
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
