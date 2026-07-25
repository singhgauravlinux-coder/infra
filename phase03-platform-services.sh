#!/usr/bin/env bash
# =============================================================================
# Phase 3 — Platform Services
#   1. PostgreSQL   — CloudNativePG operator + a 3-instance HA Cluster
#   2. Redis        — Bitnami chart, replication topology (1 master + 2 replicas)
#   3. MinIO        — operator + tenant (erasure-coded, S3-compatible, used as
#                      the backing object store for Loki/Tempo/Velero later)
#   4. Infisical    — self-hosted secrets manager (backed by the Postgres above)
#   5. External Secrets Operator — syncs Infisical secrets into k8s Secrets
#   6. Keycloak     — SSO/OIDC provider for Rancher, Argo CD, Grafana, GitLab
# =============================================================================
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../lib/common.sh"
load_config
export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"

# -----------------------------------------------------------------------------
# Step: CloudNativePG operator
# -----------------------------------------------------------------------------
step_cnpg_operator() {
  helm repo add cnpg https://cloudnative-pg.github.io/charts >/dev/null 2>&1 || true
  retry 3 10 -- helm repo update cnpg

  helm_upgrade_install cnpg-operator cnpg/cloudnative-pg cnpg-system - \
    --version "${CNPG_OPERATOR_VERSION}"

  rollout_wait deployment cnpg-controller-manager cnpg-system 180s
  log "CloudNativePG operator ready."
}

# -----------------------------------------------------------------------------
# Step: PostgreSQL HA cluster (primary platform database)
# -----------------------------------------------------------------------------
step_postgres_cluster() {
  ensure_namespace "${NS_DATA}"

  # superuser password managed idempotently — CNPG reads this secret on
  # cluster creation and never again, so it must exist before the Cluster CR.
  local su_password
  su_password=$(get_or_create_secret_value "${NS_DATA}" "platform-postgres-superuser" "password" 32)

  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: platform-postgres-superuser-cnpg
  namespace: ${NS_DATA}
type: kubernetes.io/basic-auth
stringData:
  username: postgres
  password: "${su_password}"
EOF

  cat <<EOF | kubectl apply -f -
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: platform-postgres
  namespace: ${NS_DATA}
spec:
  instances: ${POSTGRES_INSTANCES}
  imageName: ghcr.io/cloudnative-pg/postgresql:${POSTGRES_IMAGE_TAG}
  superuserSecret:
    name: platform-postgres-superuser-cnpg
  storage:
    storageClass: ${DEFAULT_STORAGE_CLASS}
    size: 20Gi
  monitoring:
    enablePodMonitor: true
  postgresql:
    parameters:
      max_connections: "200"
      shared_buffers: "512MB"
  backup:
    barmanObjectStore:
      destinationPath: "s3://platform-postgres-backups/"
      endpointURL: "https://${MINIO_API_HOST}"
      s3Credentials:
        accessKeyId:
          name: postgres-backup-s3-creds
          key: ACCESS_KEY_ID
        secretAccessKey:
          name: postgres-backup-s3-creds
          key: ACCESS_SECRET_KEY
    retentionPolicy: "30d"
EOF

  retry 60 15 -- bash -c \
    "kubectl -n ${NS_DATA} get cluster platform-postgres -o jsonpath='{.status.phase}' | grep -q 'Cluster in healthy state'"

  log "PostgreSQL HA cluster (${POSTGRES_INSTANCES} instances) is healthy."
}

# -----------------------------------------------------------------------------
# Step: Redis (replicated cache/queue backend)
# -----------------------------------------------------------------------------
step_redis() {
  local redis_password
  redis_password=$(get_or_create_secret_value "${NS_DATA}" "platform-redis" "password" 24)

  helm repo add bitnami https://charts.bitnami.com/bitnami >/dev/null 2>&1 || true
  retry 3 10 -- helm repo update bitnami

  cat >/tmp/redis-values.yaml <<EOF
architecture: replication
auth:
  enabled: true
  existingSecret: platform-redis
  existingSecretPasswordKey: password
master:
  persistence:
    storageClass: ${DEFAULT_STORAGE_CLASS}
    size: 8Gi
  resources:
    requests: {cpu: 100m, memory: 256Mi}
    limits: {cpu: 500m, memory: 1Gi}
replica:
  replicaCount: 2
  persistence:
    storageClass: ${DEFAULT_STORAGE_CLASS}
    size: 8Gi
metrics:
  enabled: true
EOF

  helm_upgrade_install platform-redis bitnami/redis "${NS_DATA}" /tmp/redis-values.yaml \
    --version "${REDIS_CHART_VERSION}"

  rollout_wait statefulset platform-redis-master "${NS_DATA}" 180s
  log "Redis replicated cluster ready."
}

# -----------------------------------------------------------------------------
# Step: MinIO operator + tenant
# -----------------------------------------------------------------------------
step_minio() {
  helm repo add minio-operator https://operator.min.io >/dev/null 2>&1 || true
  retry 3 10 -- helm repo update minio-operator

  helm_upgrade_install minio-operator minio-operator/operator minio-operator - \
    --version "${MINIO_OPERATOR_CHART_VERSION}"
  rollout_wait deployment minio-operator minio-operator 180s

  ensure_namespace "${NS_DATA}"
  local minio_user minio_pass
  minio_user="platform-admin"
  minio_pass=$(get_or_create_secret_value "${NS_DATA}" "minio-tenant-creds" "password" 32)

  kubectl -n "${NS_DATA}" get secret minio-tenant-creds >/dev/null 2>&1 || true
  # ensure the CONSOLE_ACCESS_KEY/SECRET_KEY-shaped secret MinIO expects exists
  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: minio-tenant-env-config
  namespace: ${NS_DATA}
type: Opaque
stringData:
  config.env: |
    export MINIO_ROOT_USER="${minio_user}"
    export MINIO_ROOT_PASSWORD="${minio_pass}"
EOF

  helm_upgrade_install minio-tenant minio-operator/tenant "${NS_DATA}" - \
    --version "${MINIO_TENANT_CHART_VERSION}" \
    --set tenant.name=platform-minio \
    --set tenant.configuration.name=minio-tenant-env-config \
    --set "tenant.pools[0].servers=${MINIO_TENANT_SERVERS}" \
    --set "tenant.pools[0].volumesPerServer=${MINIO_TENANT_VOLUMES_PER_SERVER}" \
    --set "tenant.pools[0].size=${MINIO_TENANT_VOLUME_SIZE}" \
    --set "tenant.pools[0].storageClassName=${DEFAULT_STORAGE_CLASS}"

  retry 30 15 -- bash -c \
    "kubectl -n ${NS_DATA} get pods -l v1.min.io/tenant=platform-minio -o jsonpath='{.items[*].status.phase}' | tr ' ' '\\n' | grep -qv Running && exit 1 || exit 0"

  # buckets used by later phases (idempotent create via mc job)
  cat <<EOF | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: minio-bucket-bootstrap
  namespace: ${NS_DATA}
spec:
  backoffLimit: 3
  template:
    spec:
      restartPolicy: OnFailure
      containers:
        - name: mc
          image: minio/mc:latest
          command:
            - /bin/sh
            - -c
            - |
              mc alias set tenant https://minio.${NS_DATA}.svc.cluster.local:443 \
                "${minio_user}" "${minio_pass}" --insecure
              for b in platform-postgres-backups velero-backups loki-chunks tempo-traces platform-app-data; do
                mc mb --insecure -p "tenant/\${b}" || true
              done
EOF
  retry 10 10 -- bash -c "kubectl -n ${NS_DATA} wait --for=condition=complete job/minio-bucket-bootstrap --timeout=120s"

  log "MinIO operator + tenant ready; baseline buckets provisioned."
}

# -----------------------------------------------------------------------------
# Step: Infisical (secrets manager, backed by the shared Postgres)
# -----------------------------------------------------------------------------
step_infisical() {
  ensure_namespace "${NS_SECURITY}"
  local encryption_key auth_secret
  encryption_key=$(get_or_create_secret_value "${NS_SECURITY}" "infisical-app" "encryption-key" 16)
  auth_secret=$(get_or_create_secret_value "${NS_SECURITY}" "infisical-app" "auth-secret" 32)
  local pg_pass
  pg_pass=$(kubectl -n "${NS_DATA}" get secret platform-postgres-superuser-cnpg -o jsonpath='{.data.password}' | base64 -d)

  helm repo add infisical-helm-charts https://dl.infisical.com/helm-charts >/dev/null 2>&1 || true
  retry 3 10 -- helm repo update infisical-helm-charts

  cat >/tmp/infisical-values.yaml <<EOF
infisical:
  autoDatabaseSchemaMigration: true
  replicaCount: 2
ingress:
  enabled: true
  hostName: ${INFISICAL_HOST}
  ingressClassName: traefik
  tls:
    - hosts: ["${INFISICAL_HOST}"]
      secretName: wildcard-microsvc-store-tls
EOF

  helm_upgrade_install infisical infisical-helm-charts/infisical-standalone "${NS_SECURITY}" /tmp/infisical-values.yaml \
    --version "${INFISICAL_CHART_VERSION}" \
    --set-string "infisical.env.ENCRYPTION_KEY=${encryption_key}" \
    --set-string "infisical.env.AUTH_SECRET=${auth_secret}" \
    --set-string "infisical.env.DB_CONNECTION_URI=postgresql://postgres:${pg_pass}@platform-postgres-rw.${NS_DATA}.svc.cluster.local:5432/infisical?sslmode=require"

  rollout_wait deployment infisical "${NS_SECURITY}" 240s
  retry 10 10 -- http_check "https://${INFISICAL_HOST}" 200 15
  log "Infisical ready at https://${INFISICAL_HOST}"
}

# -----------------------------------------------------------------------------
# Step: External Secrets Operator
#   ClusterSecretStore pointed at Infisical is provisioned here as a template;
#   the machine identity client-id/secret must be created in the Infisical UI
#   once and stored as `infisical-machine-identity` in ${NS_SECURITY}.
# -----------------------------------------------------------------------------
step_external_secrets() {
  helm repo add external-secrets https://charts.external-secrets.io >/dev/null 2>&1 || true
  retry 3 10 -- helm repo update external-secrets

  helm_upgrade_install external-secrets external-secrets/external-secrets "${NS_SECURITY}" - \
    --version "${EXTERNAL_SECRETS_CHART_VERSION}" \
    --set installCRDs=true

  rollout_wait deployment external-secrets "${NS_SECURITY}" 180s
  rollout_wait deployment external-secrets-webhook "${NS_SECURITY}" 180s

  if kubectl -n "${NS_SECURITY}" get secret infisical-machine-identity >/dev/null 2>&1; then
    cat <<EOF | kubectl apply -f -
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: infisical-store
spec:
  provider:
    infisical:
      hostAPI: https://${INFISICAL_HOST}/api
      auth:
        universalAuthCredentials:
          clientId:
            name: infisical-machine-identity
            namespace: ${NS_SECURITY}
            key: client-id
          clientSecret:
            name: infisical-machine-identity
            namespace: ${NS_SECURITY}
            key: client-secret
EOF
    retry 10 6 -- bash -c \
      "kubectl get clustersecretstore infisical-store -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' | grep -q True"
    log "External Secrets Operator connected to Infisical."
  else
    warn "Secret 'infisical-machine-identity' not found in ${NS_SECURITY} — create an Infisical"
    warn "machine identity and store its client-id/client-secret there, then re-run this step"
    warn "(operator is installed; only the ClusterSecretStore binding is deferred)."
  fi
}

# -----------------------------------------------------------------------------
# Step: Keycloak (SSO/OIDC)
# -----------------------------------------------------------------------------
step_keycloak() {
  ensure_namespace "${NS_IDENTITY}"
  local admin_pass pg_pass kc_db_pass
  admin_pass=$(get_or_create_secret_value "${NS_IDENTITY}" "keycloak-admin" "password" 24)
  pg_pass=$(kubectl -n "${NS_DATA}" get secret platform-postgres-superuser-cnpg -o jsonpath='{.data.password}' | base64 -d)
  kc_db_pass=$(get_or_create_secret_value "${NS_IDENTITY}" "keycloak-db" "password" 24)

  # dedicated DB + role via a one-shot job against the shared Postgres
  cat <<EOF | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: keycloak-db-bootstrap
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
            - {name: PGPASSWORD, value: "${pg_pass}"}
          command: ["/bin/sh", "-c"]
          args:
            - |
              psql -tc "SELECT 1 FROM pg_roles WHERE rolname='keycloak'" | grep -q 1 || \
                psql -c "CREATE ROLE keycloak LOGIN PASSWORD '${kc_db_pass}';"
              psql -tc "SELECT 1 FROM pg_database WHERE datname='keycloak'" | grep -q 1 || \
                psql -c "CREATE DATABASE keycloak OWNER keycloak;"
EOF
  retry 10 10 -- bash -c "kubectl -n ${NS_DATA} wait --for=condition=complete job/keycloak-db-bootstrap --timeout=120s"

  helm repo add bitnami https://charts.bitnami.com/bitnami >/dev/null 2>&1 || true
  retry 3 10 -- helm repo update bitnami

  cat >/tmp/keycloak-values.yaml <<EOF
auth:
  adminUser: admin
  existingSecret: keycloak-admin
  passwordSecretKey: password
replicaCount: 2
externalDatabase:
  host: platform-postgres-rw.${NS_DATA}.svc.cluster.local
  port: 5432
  database: keycloak
  user: keycloak
  existingSecret: keycloak-db
  existingSecretPasswordKey: password
postgresql:
  enabled: false
ingress:
  enabled: true
  ingressClassName: traefik
  hostname: ${KEYCLOAK_HOST}
  tls: true
  extraTls:
    - hosts: ["${KEYCLOAK_HOST}"]
      secretName: wildcard-microsvc-store-tls
metrics:
  enabled: true
EOF

  helm_upgrade_install keycloak bitnami/keycloak "${NS_IDENTITY}" /tmp/keycloak-values.yaml \
    --version "${KEYCLOAK_CHART_VERSION}"

  rollout_wait statefulset keycloak "${NS_IDENTITY}" 300s
  retry 10 10 -- http_check "https://${KEYCLOAK_HOST}" 200 15
  log "Keycloak ready at https://${KEYCLOAK_HOST}"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
  acquire_lock
  log "=== Phase 3: Platform Services — starting ==="

  run_step "p3_cnpg_operator"       step_cnpg_operator
  run_step "p3_postgres_cluster"    step_postgres_cluster
  run_step "p3_redis"               step_redis
  run_step "p3_minio"               step_minio
  run_step "p3_infisical"           step_infisical
  run_step "p3_external_secrets"    step_external_secrets
  run_step "p3_keycloak"            step_keycloak

  clear_rollback_stack
  log "=== Phase 3: Platform Services — COMPLETE ==="
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
