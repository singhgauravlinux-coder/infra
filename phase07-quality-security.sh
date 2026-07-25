#!/usr/bin/env bash
# =============================================================================
# Phase 7 — Quality & Security
#   1. SonarQube       — static analysis / code quality gate, backed by shared Postgres
#   2. Kyverno         — policy engine, deployed in Audit mode first (never
#                        flips straight to Enforce — see step_kyverno_enforce)
#   3. Cosign          — keyless image signing; Kyverno verifyImages policy
#   4. SBOM            — Syft, wired as a reusable CI template
#   5. Secret scanning — Gitleaks, wired as a reusable CI template
#   6. Dependency/container scanning — Grype + GitLab dependency scanning template
# =============================================================================
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../lib/common.sh"
load_config
export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"

NS_QUALITY="quality"

# -----------------------------------------------------------------------------
# Step: SonarQube
# -----------------------------------------------------------------------------
step_sonarqube() {
  ensure_namespace "${NS_QUALITY}"
  local admin_pass db_pass
  admin_pass=$(get_or_create_secret_value "${NS_QUALITY}" "sonarqube-admin" "password" 24)
  db_pass=$(get_or_create_secret_value "${NS_QUALITY}" "sonarqube-db" "password" 24)

  cat <<EOF | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: sonarqube-db-bootstrap
  namespace: ${NS_DATA}
spec:
  backoffLimit: 3
  template:
    spec:
      restartPolicy: OnFailure
      containers:
        - name: psql
          image: postgres:${POSTGRES_IMAGE_TAG}
          env:
            - {name: PGHOST, value: "platform-postgres-rw"}
            - {name: PGUSER, value: "postgres"}
            - name: PGPASSWORD
              valueFrom:
                secretKeyRef: {name: platform-postgres-superuser-cnpg, key: password}
          command: ["/bin/sh", "-c"]
          args:
            - |
              psql -tc "SELECT 1 FROM pg_roles WHERE rolname='sonarqube'" | grep -q 1 || \
                psql -c "CREATE ROLE sonarqube LOGIN PASSWORD '${db_pass}';"
              psql -tc "SELECT 1 FROM pg_database WHERE datname='sonarqube'" | grep -q 1 || \
                psql -c "CREATE DATABASE sonarqube OWNER sonarqube;"
EOF
  retry 10 10 -- bash -c "kubectl -n ${NS_DATA} wait --for=condition=complete job/sonarqube-db-bootstrap --timeout=120s"

  helm repo add sonarqube https://SonarSource.github.io/helm-chart-sonarqube >/dev/null 2>&1 || true
  retry 3 10 -- helm repo update sonarqube

  cat >/tmp/sonarqube-values.yaml <<EOF
account:
  adminPassword: "${admin_pass}"
jdbcOverwrite:
  enabled: true
  jdbcUrl: "jdbc:postgresql://platform-postgres-rw.${NS_DATA}.svc.cluster.local:5432/sonarqube"
  jdbcUsername: sonarqube
  jdbcSecretName: sonarqube-db
  jdbcSecretPasswordKey: password
ingress:
  enabled: true
  ingressClassName: traefik
  hosts:
    - name: ${SONARQUBE_HOST}
  tls:
    - hosts: ["${SONARQUBE_HOST}"]
      secretName: wildcard-microservice-in-tls
persistence:
  enabled: true
  storageClass: ${DEFAULT_STORAGE_CLASS}
EOF

  helm_upgrade_install sonarqube sonarqube/sonarqube "${NS_QUALITY}" /tmp/sonarqube-values.yaml \
    --version "${SONARQUBE_CHART_VERSION}" \
    --timeout 15m

  rollout_wait statefulset sonarqube-sonarqube "${NS_QUALITY}" 300s
  retry 15 15 -- http_check "https://${SONARQUBE_HOST}/api/system/status" 200 15

  log "SonarQube ready at https://${SONARQUBE_HOST}"
}

# -----------------------------------------------------------------------------
# Step: Kyverno — install + baseline policies in Audit mode
#   Enforce is a deliberate separate step (never auto-flipped) so cluster
#   operators can review violation reports before anything starts blocking.
# -----------------------------------------------------------------------------
step_kyverno() {
  helm repo add kyverno https://kyverno.github.io/kyverno >/dev/null 2>&1 || true
  retry 3 10 -- helm repo update kyverno

  helm_upgrade_install kyverno kyverno/kyverno kyverno - \
    --version "${KYVERNO_CHART_VERSION}"
  rollout_wait deployment kyverno-admission-controller kyverno 180s

  helm_upgrade_install kyverno-policies kyverno/kyverno-policies kyverno - \
    --set validationFailureAction=audit \
    --set background=true

  cat <<'EOF' | kubectl apply -f -
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: verify-image-signatures
spec:
  validationFailureAction: audit
  background: false
  rules:
    - name: check-cosign-signature
      match:
        any:
          - resources: {kinds: ["Pod"]}
      verifyImages:
        - imageReferences: ["harbor.microsvc.store/*"]
          attestors:
            - entries:
                - keyless:
                    subject: "https://gitlab.microsvc.store/*"
                    issuer: "https://gitlab.microsvc.store"
                    rekor:
                      url: https://rekor.sigstore.dev
EOF

  log "Kyverno installed in AUDIT mode with baseline pod-security policies and"
  log "an image-signature verification policy (audit). Review violations with:"
  log "  kubectl get policyreport,clusterpolicyreport -A"
  log "before switching to enforce (see step_kyverno_enforce, run manually)."
}

step_kyverno_enforce() {
  # Deliberately NOT wired into main() — an operator runs this explicitly
  # after reviewing audit reports, e.g.:
  #   bash phases/phase07-quality-security.sh --enforce-kyverno
  helm upgrade kyverno-policies kyverno/kyverno-policies -n kyverno \
    --reuse-values --set validationFailureAction=enforce --wait
  kubectl patch clusterpolicy verify-image-signatures \
    --type=merge -p '{"spec":{"validationFailureAction":"enforce"}}'
  log "Kyverno policies switched to ENFORCE."
}

# -----------------------------------------------------------------------------
# Step: Cosign (keyless signing tooling on the runner image path)
# -----------------------------------------------------------------------------
step_cosign_install() {
  if command -v cosign >/dev/null 2>&1; then
    log "cosign already installed: $(cosign version --short 2>/dev/null || true)"
    return 0
  fi
  retry 3 10 -- curl -fsSL -o /usr/local/bin/cosign \
    "https://github.com/sigstore/cosign/releases/download/${COSIGN_VERSION}/cosign-linux-amd64"
  chmod +x /usr/local/bin/cosign
  log "cosign ${COSIGN_VERSION} installed."
}

# -----------------------------------------------------------------------------
# Step: reusable CI templates — SBOM (Syft), secret scanning (Gitleaks),
#        dependency/container scanning (Grype) — pushed to gitops-config repo
#        as includable .gitlab-ci.yml fragments.
# -----------------------------------------------------------------------------
step_ci_security_templates() {
  local workdir="/tmp/security-ci-templates"
  rm -rf "${workdir}"; mkdir -p "${workdir}"

  cat > "${workdir}/sbom.gitlab-ci.yml" <<EOF
sbom:generate:
  stage: security
  image: anchore/syft:${SYFT_VERSION}
  script:
    - syft packages dir:. -o cyclonedx-json=sbom.cdx.json
  artifacts:
    paths: [sbom.cdx.json]
    expire_in: 90 days
EOF

  cat > "${workdir}/secret-scan.gitlab-ci.yml" <<EOF
secret-scan:
  stage: security
  image: zricethezav/gitleaks:${GITLEAKS_VERSION}
  script:
    - gitleaks detect --source . --report-format json --report-path gitleaks-report.json --exit-code 1
  artifacts:
    when: always
    paths: [gitleaks-report.json]
    expire_in: 90 days
EOF

  cat > "${workdir}/container-scan.gitlab-ci.yml" <<EOF
container-scan:
  stage: security
  image: anchore/grype:${GRYPE_VERSION}
  script:
    - grype "\${CI_REGISTRY_IMAGE}:\${CI_COMMIT_SHORT_SHA}" -o json --file grype-report.json --fail-on high
  artifacts:
    when: always
    paths: [grype-report.json]
    expire_in: 90 days
EOF

  cat > "${workdir}/sign-image.gitlab-ci.yml" <<'EOF'
sign-image:
  stage: publish
  image: gcr.io/projectsigstore/cosign:v2.4.1
  script:
    - cosign sign --yes "${CI_REGISTRY_IMAGE}:${CI_COMMIT_SHORT_SHA}"
  id_tokens:
    SIGSTORE_ID_TOKEN:
      aud: sigstore
EOF

  cat > "${workdir}/dependency-scanning.gitlab-ci.yml" <<'EOF'
include:
  - template: Security/Dependency-Scanning.gitlab-ci.yml
EOF

  local root_pass token
  root_pass=$(kubectl -n "${NS_DEVOPS}" get secret gitlab-gitlab-initial-root-password -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)
  if [[ -z "${root_pass}" ]]; then
    warn "GitLab not available — CI security templates staged locally at ${workdir}."
    warn "Push to a 'platform/ci-templates' project once GitLab is reachable."
    return 0
  fi

  token=$(curl -sk -X POST "https://${GITLAB_HOST}/oauth/token" \
    -d "grant_type=password&username=root&password=${root_pass}" | jq -r '.access_token')

  cd "${workdir}"
  git init -q -b main
  git add -A
  git -c user.email="platform-bot@microsvc.store" -c user.name="platform-bot" \
    commit -q -m "chore: add SBOM/secret/container/dependency scanning CI templates"
  git remote add origin "https://root:${root_pass}@${GITLAB_HOST}/platform/ci-templates.git" 2>/dev/null || true

  curl -sk -X POST "https://${GITLAB_HOST}/api/v4/projects" \
    -H "Authorization: Bearer ${token}" \
    -d "name=ci-templates&namespace_id=$(curl -sk -H "Authorization: Bearer ${token}" \
        "https://${GITLAB_HOST}/api/v4/groups/platform" | jq -r '.id')" >/dev/null 2>&1 || true

  retry 5 10 -- git push -u origin main --force

  log "Security CI templates (SBOM, secret scan, container scan, dep scan, cosign sign) pushed."
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
  if [[ "${1:-}" == "--enforce-kyverno" ]]; then
    acquire_lock
    load_config
    step_kyverno_enforce
    exit 0
  fi

  acquire_lock
  log "=== Phase 7: Quality & Security — starting ==="

  run_step "p7_sonarqube"              step_sonarqube
  run_step "p7_kyverno"                step_kyverno
  run_step "p7_cosign_install"         step_cosign_install
  run_step "p7_ci_security_templates"  step_ci_security_templates

  clear_rollback_stack
  log "=== Phase 7: Quality & Security — COMPLETE ==="
  log "NOTE: Kyverno is in AUDIT mode by design. Review 'kubectl get policyreport -A'"
  log "then run: bash \$0 --enforce-kyverno   to switch to blocking enforcement."
}

main "$@"
