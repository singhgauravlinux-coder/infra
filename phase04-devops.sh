#!/usr/bin/env bash
# =============================================================================
# Phase 4 — DevOps
#   1. Harbor        — container registry (vuln scanning, replication, robot accounts)
#   2. GitLab         — source control + CI/CD, using the shared Postgres/Redis/MinIO
#   3. GitLab Runner  — Kubernetes executor, isolated per-job pods
#   4. CI/CD smoke test — push a trivial pipeline and confirm it runs green
# =============================================================================
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../lib/common.sh"
load_config
export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"

# -----------------------------------------------------------------------------
# Step: Harbor
# -----------------------------------------------------------------------------
step_harbor() {
  ensure_namespace "${NS_DEVOPS}"
  local admin_pass db_pass
  admin_pass=$(get_or_create_secret_value "${NS_DEVOPS}" "harbor-admin" "password" 24)
  db_pass=$(kubectl -n "${NS_DATA}" get secret platform-postgres-superuser-cnpg -o jsonpath='{.data.password}' | base64 -d)

  helm repo add harbor https://helm.goharbor.io >/dev/null 2>&1 || true
  retry 3 10 -- helm repo update harbor

  cat >/tmp/harbor-values.yaml <<EOF
expose:
  type: ingress
  tls:
    certSource: secret
    secret:
      secretName: wildcard-microservice-in-tls
  ingress:
    hosts:
      core: ${HARBOR_HOST}
    className: traefik
externalURL: https://${HARBOR_HOST}
harborAdminPassword: "${admin_pass}"
database:
  type: external
  external:
    host: platform-postgres-rw.${NS_DATA}.svc.cluster.local
    port: "5432"
    username: postgres
    password: "${db_pass}"
    coreDatabase: harbor_core
    notaryServerDatabase: harbor_notary_server
    notarySignerDatabase: harbor_notary_signer
redis:
  type: external
  external:
    addr: "platform-redis-master.${NS_DATA}.svc.cluster.local:6379"
persistence:
  imageChartStorage:
    type: s3
    s3:
      region: us-east-1
      bucket: harbor-registry
      regionendpoint: https://${MINIO_API_HOST}
      secure: true
      v4auth: true
trivy:
  enabled: true
notary:
  enabled: true
EOF

  helm_upgrade_install harbor harbor/harbor "${NS_DEVOPS}" /tmp/harbor-values.yaml \
    --version "${HARBOR_CHART_VERSION}"

  rollout_wait deployment harbor-core "${NS_DEVOPS}" 300s
  rollout_wait deployment harbor-portal "${NS_DEVOPS}" 180s
  retry 10 10 -- http_check "https://${HARBOR_HOST}/api/v2.0/health" 200 15

  log "Harbor ready at https://${HARBOR_HOST}"
}

# -----------------------------------------------------------------------------
# Step: GitLab
# -----------------------------------------------------------------------------
step_gitlab() {
  local root_pass db_pass redis_pass minio_pass
  root_pass=$(get_or_create_secret_value "${NS_DEVOPS}" "gitlab-root" "password" 24)
  db_pass=$(kubectl -n "${NS_DATA}" get secret platform-postgres-superuser-cnpg -o jsonpath='{.data.password}' | base64 -d)
  redis_pass=$(kubectl -n "${NS_DATA}" get secret platform-redis -o jsonpath='{.data.password}' | base64 -d)
  minio_pass=$(kubectl -n "${NS_DATA}" get secret minio-tenant-creds -o jsonpath='{.data.password}' | base64 -d)

  kubectl -n "${NS_DEVOPS}" create secret generic gitlab-gitlab-initial-root-password \
    --from-literal=password="${root_pass}" --dry-run=client -o yaml | kubectl apply -f -

  kubectl -n "${NS_DEVOPS}" create secret generic gitlab-postgresql-password \
    --from-literal=postgresql-password="${db_pass}" --dry-run=client -o yaml | kubectl apply -f -

  kubectl -n "${NS_DEVOPS}" create secret generic gitlab-redis-password \
    --from-literal=redis-password="${redis_pass}" --dry-run=client -o yaml | kubectl apply -f -

  kubectl -n "${NS_DEVOPS}" create secret generic gitlab-object-storage \
    --from-literal=connection="$(cat <<CONN
provider: AWS
region: us-east-1
aws_access_key_id: platform-admin
aws_secret_access_key: ${minio_pass}
endpoint: https://${MINIO_API_HOST}
path_style: true
CONN
)" --dry-run=client -o yaml | kubectl apply -f -

  helm repo add gitlab https://charts.gitlab.io >/dev/null 2>&1 || true
  retry 3 10 -- helm repo update gitlab

  cat >/tmp/gitlab-values.yaml <<EOF
global:
  hosts:
    domain: ${BASE_DOMAIN}
    gitlab:
      name: ${GITLAB_HOST}
  ingress:
    class: traefik
    tls:
      secretName: wildcard-microservice-in-tls
  psql:
    host: platform-postgres-rw.${NS_DATA}.svc.cluster.local
    password:
      secret: gitlab-postgresql-password
      key: postgresql-password
  redis:
    host: platform-redis-master.${NS_DATA}.svc.cluster.local
    password:
      secret: gitlab-redis-password
      key: redis-password
  minio:
    enabled: false
  appConfig:
    object_store:
      enabled: true
      connection:
        secret: gitlab-object-storage
        key: connection
certmanager:
  install: false
nginx-ingress:
  enabled: false
gitlab-runner:
  install: false
postgresql:
  install: false
redis:
  install: false
registry:
  enabled: false   # Harbor is the platform registry of record
EOF

  helm_upgrade_install gitlab gitlab/gitlab "${NS_DEVOPS}" /tmp/gitlab-values.yaml \
    --version "${GITLAB_CHART_VERSION}" \
    --timeout 20m

  rollout_wait deployment gitlab-webservice-default "${NS_DEVOPS}" 600s
  retry 15 15 -- http_check "https://${GITLAB_HOST}/-/health" 200 15

  log "GitLab ready at https://${GITLAB_HOST} (root password in secret gitlab-root)"
}

# -----------------------------------------------------------------------------
# Step: GitLab Runner (Kubernetes executor)
# -----------------------------------------------------------------------------
step_gitlab_runner() {
  local reg_token
  # GitLab 16+ uses runner authentication tokens created via API/UI; this
  # step expects a token to have been placed in secret 'gitlab-runner-token'
  # (Settings > CI/CD > Runners > New instance runner, in the GitLab UI).
  if ! kubectl -n "${NS_DEVOPS}" get secret gitlab-runner-token >/dev/null 2>&1; then
    warn "Secret 'gitlab-runner-token' not found in ${NS_DEVOPS}."
    warn "Create an instance runner in GitLab UI (CI/CD > Runners), then:"
    warn "  kubectl -n ${NS_DEVOPS} create secret generic gitlab-runner-token --from-literal=runner-registration-token=<TOKEN>"
    warn "Skipping runner install until token is present."
    return 0
  fi

  helm repo add gitlab https://charts.gitlab.io >/dev/null 2>&1 || true
  retry 3 10 -- helm repo update gitlab

  cat >/tmp/gitlab-runner-values.yaml <<EOF
gitlabUrl: https://${GITLAB_HOST}
runnerToken: ""
runnerRegistrationToken: ""
secrets:
  - name: gitlab-runner-token
concurrent: 10
rbac:
  create: true
runners:
  config: |
    [[runners]]
      [runners.kubernetes]
        namespace = "${NS_DEVOPS}"
        image = "ubuntu:24.04"
        privileged = false
        pull_policy = "if-not-present"
        [runners.kubernetes.pod_security_context]
          run_as_non_root = true
      [runners.cache]
        Type = "s3"
        Shared = true
        [runners.cache.s3]
          ServerAddress = "${MINIO_API_HOST}"
          BucketName = "gitlab-runner-cache"
          Insecure = false
EOF

  helm_upgrade_install gitlab-runner gitlab/gitlab-runner "${NS_DEVOPS}" /tmp/gitlab-runner-values.yaml \
    --version "${GITLAB_RUNNER_CHART_VERSION}"

  rollout_wait deployment gitlab-runner-gitlab-runner "${NS_DEVOPS}" 180s
  log "GitLab Runner (Kubernetes executor) deployed."
}

# -----------------------------------------------------------------------------
# Step: CI/CD smoke validation
#   Uses GitLab's REST API to create a throwaway project with a minimal
#   .gitlab-ci.yml, waits for the pipeline to go green, then deletes it.
# -----------------------------------------------------------------------------
step_cicd_smoke_test() {
  if ! kubectl -n "${NS_DEVOPS}" get secret gitlab-runner-token >/dev/null 2>&1; then
    warn "Skipping CI/CD smoke test — no runner registered yet."
    return 0
  fi

  local root_pass token project_id pipeline_id status
  root_pass=$(kubectl -n "${NS_DEVOPS}" get secret gitlab-gitlab-initial-root-password -o jsonpath='{.data.password}' | base64 -d)

  token=$(curl -sk -X POST "https://${GITLAB_HOST}/oauth/token" \
    -d "grant_type=password&username=root&password=${root_pass}" | jq -r '.access_token')
  [[ -n "${token}" && "${token}" != "null" ]] || fatal "Could not authenticate to GitLab API for smoke test."

  project_id=$(curl -sk -X POST "https://${GITLAB_HOST}/api/v4/projects" \
    -H "Authorization: Bearer ${token}" \
    -d "name=platform-smoke-test&initialize_with_readme=true" | jq -r '.id')
  [[ -n "${project_id}" && "${project_id}" != "null" ]] || fatal "Could not create smoke-test project."

  curl -sk -X POST "https://${GITLAB_HOST}/api/v4/projects/${project_id}/repository/files/.gitlab-ci.yml" \
    -H "Authorization: Bearer ${token}" \
    --data-urlencode "branch=main" \
    --data-urlencode "content=smoke_test:
  stage: test
  script:
    - echo \"platform CI/CD smoke test OK\"
" \
    --data-urlencode "commit_message=add ci config" >/dev/null

  pipeline_id=$(curl -sk -X POST \
    "https://${GITLAB_HOST}/api/v4/projects/${project_id}/pipeline?ref=main" \
    -H "Authorization: Bearer ${token}" | jq -r '.id')

  retry 20 15 -- bash -c "
    status=\$(curl -sk -H 'Authorization: Bearer ${token}' \
      'https://${GITLAB_HOST}/api/v4/projects/${project_id}/pipelines/${pipeline_id}' | jq -r '.status')
    [[ \"\${status}\" == 'success' ]]
  "

  curl -sk -X DELETE "https://${GITLAB_HOST}/api/v4/projects/${project_id}" \
    -H "Authorization: Bearer ${token}" >/dev/null

  log "CI/CD smoke test pipeline completed successfully; test project cleaned up."
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
  if [[ "${1:-}" == "__smoke_only" ]]; then
    step_cicd_smoke_test
    exit $?
  fi

  acquire_lock
  log "=== Phase 4: DevOps — starting ==="

  run_step "p4_harbor"          step_harbor
  run_step "p4_gitlab"          step_gitlab
  run_step "p4_gitlab_runner"   step_gitlab_runner
  run_step "p4_cicd_smoke_test" step_cicd_smoke_test

  clear_rollback_stack
  log "=== Phase 4: DevOps — COMPLETE ==="
}

# Only auto-run when executed directly — allows phase09 to source this file
# for its individual step functions (e.g. __smoke_only) without re-running
# the whole phase.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
