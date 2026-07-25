#!/usr/bin/env bash
# =============================================================================
# Phase 6 — Observability
#   1. kube-prometheus-stack — Prometheus + Grafana + Alertmanager
#   2. Loki + Promtail       — log aggregation, MinIO-backed storage
#   3. Tempo                 — distributed tracing, MinIO-backed storage
#   4. OpenTelemetry Collector — unified ingest for traces/metrics/logs
# =============================================================================
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../lib/common.sh"
load_config
export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"

# -----------------------------------------------------------------------------
# Step: kube-prometheus-stack
# -----------------------------------------------------------------------------
step_kube_prometheus_stack() {
  ensure_namespace "${NS_OBSERVABILITY}"
  local grafana_admin_pass
  grafana_admin_pass=$(get_or_create_secret_value "${NS_OBSERVABILITY}" "grafana-admin" "password" 24)

  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
  retry 3 10 -- helm repo update prometheus-community

  cat >/tmp/kube-prometheus-stack-values.yaml <<EOF
prometheus:
  prometheusSpec:
    retention: ${METRICS_RETENTION_DAYS}d
    storageSpec:
      volumeClaimTemplate:
        spec:
          storageClassName: ${DEFAULT_STORAGE_CLASS}
          resources:
            requests: {storage: 50Gi}
    podMonitorSelectorNilUsesHelmValues: false
    serviceMonitorSelectorNilUsesHelmValues: false
alertmanager:
  alertmanagerSpec:
    storage:
      volumeClaimTemplate:
        spec:
          storageClassName: ${DEFAULT_STORAGE_CLASS}
          resources:
            requests: {storage: 5Gi}
  config:
    route:
      receiver: "null"
      routes:
        - receiver: "null"
          matchers: [{name: alertname, value: Watchdog, isRegex: false}]
grafana:
  adminPassword: null
  admin:
    existingSecret: grafana-admin
    userKey: admin-user
    passwordKey: password
  ingress:
    enabled: true
    ingressClassName: traefik
    hosts: ["${GRAFANA_HOST}"]
    tls:
      - hosts: ["${GRAFANA_HOST}"]
        secretName: wildcard-microservice-in-tls
  persistence:
    enabled: true
    storageClassName: ${DEFAULT_STORAGE_CLASS}
    size: 5Gi
EOF

  kubectl -n "${NS_OBSERVABILITY}" create secret generic grafana-admin \
    --from-literal=admin-user=admin \
    --from-literal=password="${grafana_admin_pass}" \
    --dry-run=client -o yaml | kubectl apply -f -

  helm_upgrade_install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
    "${NS_OBSERVABILITY}" /tmp/kube-prometheus-stack-values.yaml \
    --version "${KUBE_PROM_STACK_CHART_VERSION}" \
    --timeout 15m

  rollout_wait deployment kube-prometheus-stack-grafana "${NS_OBSERVABILITY}" 240s
  retry 15 15 -- bash -c \
    "kubectl -n ${NS_OBSERVABILITY} get statefulset prometheus-kube-prometheus-stack-prometheus -o jsonpath='{.status.readyReplicas}' | grep -q '^1'"
  retry 10 10 -- http_check "https://${GRAFANA_HOST}" 200 15

  log "Prometheus + Grafana + Alertmanager ready. Grafana: https://${GRAFANA_HOST}"
}

# -----------------------------------------------------------------------------
# Step: Loki + Promtail (log aggregation, MinIO-backed)
# -----------------------------------------------------------------------------
step_loki() {
  local minio_pass
  minio_pass=$(kubectl -n "${NS_DATA}" get secret minio-tenant-creds -o jsonpath='{.data.password}' | base64 -d)

  helm repo add grafana https://grafana.github.io/helm-charts >/dev/null 2>&1 || true
  retry 3 10 -- helm repo update grafana

  cat >/tmp/loki-values.yaml <<EOF
loki:
  auth_enabled: false
  commonConfig:
    replication_factor: 2
  storage:
    type: s3
    s3:
      endpoint: ${MINIO_API_HOST}
      region: us-east-1
      accessKeyId: platform-admin
      secretAccessKey: "${minio_pass}"
      s3ForcePathStyle: true
      insecure: false
    bucketNames:
      chunks: loki-chunks
      ruler: loki-chunks
      admin: loki-chunks
  limits_config:
    retention_period: ${LOGS_RETENTION_DAYS}d
deploymentMode: SimpleScalable
backend:
  replicas: 2
  persistence:
    storageClass: ${DEFAULT_STORAGE_CLASS}
read:
  replicas: 2
write:
  replicas: 2
  persistence:
    storageClass: ${DEFAULT_STORAGE_CLASS}
gateway:
  enabled: true
monitoring:
  serviceMonitor:
    enabled: true
test:
  enabled: false
EOF

  helm_upgrade_install loki grafana/loki "${NS_OBSERVABILITY}" /tmp/loki-values.yaml \
    --version "${LOKI_CHART_VERSION}" \
    --timeout 15m

  cat >/tmp/promtail-values.yaml <<EOF
config:
  clients:
    - url: http://loki-gateway.${NS_OBSERVABILITY}.svc.cluster.local/loki/api/v1/push
EOF

  helm_upgrade_install promtail grafana/promtail "${NS_OBSERVABILITY}" /tmp/promtail-values.yaml

  rollout_wait daemonset promtail "${NS_OBSERVABILITY}" 180s

  # register Loki as a Grafana datasource
  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-datasource-loki
  namespace: ${NS_OBSERVABILITY}
  labels: {grafana_datasource: "1"}
data:
  loki.yaml: |
    apiVersion: 1
    datasources:
      - name: Loki
        type: loki
        url: http://loki-gateway.${NS_OBSERVABILITY}.svc.cluster.local
        access: proxy
EOF

  log "Loki (S3-backed, ${LOGS_RETENTION_DAYS}d retention) + Promtail ready."
}

# -----------------------------------------------------------------------------
# Step: Tempo (distributed tracing, MinIO-backed)
# -----------------------------------------------------------------------------
step_tempo() {
  local minio_pass
  minio_pass=$(kubectl -n "${NS_DATA}" get secret minio-tenant-creds -o jsonpath='{.data.password}' | base64 -d)

  helm repo add grafana https://grafana.github.io/helm-charts >/dev/null 2>&1 || true
  retry 3 10 -- helm repo update grafana

  cat >/tmp/tempo-values.yaml <<EOF
tempo:
  storage:
    trace:
      backend: s3
      s3:
        endpoint: ${MINIO_API_HOST}
        bucket: tempo-traces
        access_key: platform-admin
        secret_key: "${minio_pass}"
        insecure: false
        forcepathstyle: true
  resources:
    requests: {cpu: 200m, memory: 512Mi}
persistence:
  enabled: true
  storageClassName: ${DEFAULT_STORAGE_CLASS}
EOF

  helm_upgrade_install tempo grafana/tempo-distributed "${NS_OBSERVABILITY}" /tmp/tempo-values.yaml \
    --version "${TEMPO_CHART_VERSION}"

  rollout_wait deployment tempo-query-frontend "${NS_OBSERVABILITY}" 180s

  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-datasource-tempo
  namespace: ${NS_OBSERVABILITY}
  labels: {grafana_datasource: "1"}
data:
  tempo.yaml: |
    apiVersion: 1
    datasources:
      - name: Tempo
        type: tempo
        url: http://tempo-query-frontend.${NS_OBSERVABILITY}.svc.cluster.local:3100
        access: proxy
EOF

  log "Tempo (S3-backed traces) ready and registered as a Grafana datasource."
}

# -----------------------------------------------------------------------------
# Step: OpenTelemetry Collector (unified ingest -> Tempo/Loki/Prometheus)
# -----------------------------------------------------------------------------
step_otel_collector() {
  helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts >/dev/null 2>&1 || true
  retry 3 10 -- helm repo update open-telemetry

  cat >/tmp/otel-collector-values.yaml <<EOF
mode: deployment
replicaCount: 2
config:
  receivers:
    otlp:
      protocols:
        grpc: {endpoint: 0.0.0.0:4317}
        http: {endpoint: 0.0.0.0:4318}
  processors:
    batch: {}
    memory_limiter:
      check_interval: 5s
      limit_percentage: 80
  exporters:
    otlp/tempo:
      endpoint: tempo-distributor.${NS_OBSERVABILITY}.svc.cluster.local:4317
      tls: {insecure: true}
    loki:
      endpoint: http://loki-gateway.${NS_OBSERVABILITY}.svc.cluster.local/loki/api/v1/push
    prometheusremotewrite:
      endpoint: http://kube-prometheus-stack-prometheus.${NS_OBSERVABILITY}.svc.cluster.local:9090/api/v1/write
  service:
    pipelines:
      traces:
        receivers: [otlp]
        processors: [memory_limiter, batch]
        exporters: [otlp/tempo]
      logs:
        receivers: [otlp]
        processors: [memory_limiter, batch]
        exporters: [loki]
      metrics:
        receivers: [otlp]
        processors: [memory_limiter, batch]
        exporters: [prometheusremotewrite]
EOF

  helm_upgrade_install otel-collector open-telemetry/opentelemetry-collector "${NS_OBSERVABILITY}" \
    /tmp/otel-collector-values.yaml \
    --version "${OTEL_COLLECTOR_CHART_VERSION}"

  rollout_wait deployment otel-collector-opentelemetry-collector "${NS_OBSERVABILITY}" 180s
  log "OpenTelemetry Collector ready — unified OTLP ingest at :4317/:4318 -> Tempo/Loki/Prometheus."
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
  acquire_lock
  log "=== Phase 6: Observability — starting ==="

  run_step "p6_kube_prometheus_stack" step_kube_prometheus_stack
  run_step "p6_loki"                  step_loki
  run_step "p6_tempo"                 step_tempo
  run_step "p6_otel_collector"        step_otel_collector

  clear_rollback_stack
  log "=== Phase 6: Observability — COMPLETE ==="
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
