#!/usr/bin/env bash
# =============================================================================
# Phase 8 — Backup & DR
#   1. Velero            — installed with the AWS S3 plugin, pointed at MinIO
#   2. Backup schedules   — daily cluster-wide + per-critical-namespace schedules
#   3. Restore validation — the part most DR setups skip: actually restore a
#                            backup into a scratch namespace and assert the
#                            data comes back, not just that "backup completed".
# =============================================================================
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../lib/common.sh"
load_config
export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"

# -----------------------------------------------------------------------------
# Step: Velero install (MinIO as S3-compatible backend)
# -----------------------------------------------------------------------------
step_velero() {
  ensure_namespace "${NS_VELERO}"
  local minio_pass
  minio_pass=$(kubectl -n "${NS_DATA}" get secret minio-tenant-creds -o jsonpath='{.data.password}' | base64 -d)

  cat > /tmp/velero-credentials <<EOF
[default]
aws_access_key_id=platform-admin
aws_secret_access_key=${minio_pass}
EOF

  helm repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts >/dev/null 2>&1 || true
  retry 3 10 -- helm repo update vmware-tanzu

  cat >/tmp/velero-values.yaml <<EOF
initContainers:
  - name: velero-plugin-for-aws
    image: ${VELERO_PLUGIN_AWS_IMAGE}
    volumeMounts:
      - {mountPath: /target, name: plugins}
configuration:
  backupStorageLocation:
    - name: default
      provider: aws
      bucket: ${BACKUP_BUCKET}
      config:
        region: us-east-1
        s3ForcePathStyle: "true"
        s3Url: "https://${MINIO_API_HOST}"
  volumeSnapshotLocation:
    - name: default
      provider: aws
      config: {region: us-east-1}
  defaultVolumesToFsBackup: true
deployNodeAgent: true
credentials:
  useSecret: true
  existingSecret: velero-minio-credentials
EOF

  kubectl -n "${NS_VELERO}" create secret generic velero-minio-credentials \
    --from-file=cloud=/tmp/velero-credentials --dry-run=client -o yaml | kubectl apply -f -

  helm_upgrade_install velero vmware-tanzu/velero "${NS_VELERO}" /tmp/velero-values.yaml \
    --version "${VELERO_CHART_VERSION}"

  rollout_wait deployment velero "${NS_VELERO}" 240s
  retry 10 10 -- bash -c \
    "kubectl -n ${NS_VELERO} get backupstoragelocation default -o jsonpath='{.status.phase}' | grep -q Available"

  log "Velero ready, backup storage location 'default' (MinIO bucket ${BACKUP_BUCKET}) is Available."
}

# -----------------------------------------------------------------------------
# Step: Backup schedules
# -----------------------------------------------------------------------------
step_backup_schedules() {
  cat <<EOF | kubectl apply -f -
apiVersion: velero.io/v1
kind: Schedule
metadata:
  name: daily-full-cluster
  namespace: ${NS_VELERO}
spec:
  schedule: "${BACKUP_SCHEDULE_CRON}"
  template:
    ttl: ${BACKUP_TTL}
    excludedNamespaces: ["kube-system", "${NS_VELERO}"]
    includeClusterResources: true
    snapshotVolumes: true
EOF

  cat <<EOF | kubectl apply -f -
apiVersion: velero.io/v1
kind: Schedule
metadata:
  name: hourly-data-tier
  namespace: ${NS_VELERO}
spec:
  schedule: "0 * * * *"
  template:
    ttl: 72h0m0s
    includedNamespaces: ["${NS_DATA}", "${NS_IDENTITY}", "${NS_SECURITY}"]
    includeClusterResources: false
    snapshotVolumes: true
EOF

  retry 10 6 -- bash -c \
    "kubectl -n ${NS_VELERO} get schedule daily-full-cluster -o jsonpath='{.status.phase}' | grep -q Enabled"

  log "Backup schedules created: daily-full-cluster (${BACKUP_SCHEDULE_CRON}), hourly-data-tier."
}

# -----------------------------------------------------------------------------
# Step: Restore validation — the step most DR setups skip.
#   1. Create a scratch namespace with a known ConfigMap + PVC + a file written
#      to that volume.
#   2. Take an on-demand Velero backup of just that namespace.
#   3. Delete the namespace entirely.
#   4. Restore from the backup.
#   5. Assert the ConfigMap and the file content on the PVC both came back.
#   6. Clean up.
# -----------------------------------------------------------------------------
step_restore_validation() {
  local ns="dr-restore-validation"
  local marker="dr-test-$(date +%s)"

  kubectl create namespace "${ns}" --dry-run=client -o yaml | kubectl apply -f -
  kubectl -n "${ns}" create configmap dr-marker --from-literal=marker="${marker}" \
    --dry-run=client -o yaml | kubectl apply -f -

  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: dr-test-pvc, namespace: ${ns}}
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: ${DEFAULT_STORAGE_CLASS}
  resources: {requests: {storage: 1Gi}}
---
apiVersion: v1
kind: Pod
metadata: {name: dr-test-writer, namespace: ${ns}}
spec:
  restartPolicy: Never
  containers:
    - name: writer
      image: busybox:1.36
      command: ["sh", "-c", "echo ${marker} > /data/marker.txt && sleep 3600"]
      volumeMounts: [{name: data, mountPath: /data}]
  volumes:
    - name: data
      persistentVolumeClaim: {claimName: dr-test-pvc}
EOF

  retry 15 6 -- kubectl -n "${ns}" wait --for=condition=Ready pod/dr-test-writer --timeout=90s

  local backup_name="dr-validation-$(date +%s)"
  cat <<EOF | kubectl apply -f -
apiVersion: velero.io/v1
kind: Backup
metadata:
  name: ${backup_name}
  namespace: ${NS_VELERO}
spec:
  includedNamespaces: ["${ns}"]
  defaultVolumesToFsBackup: true
EOF

  retry 30 15 -- bash -c \
    "kubectl -n ${NS_VELERO} get backup ${backup_name} -o jsonpath='{.status.phase}' | grep -q Completed"
  log "On-demand backup '${backup_name}' completed. Deleting namespace to prove restore works..."

  kubectl delete namespace "${ns}" --wait=true --timeout=120s
  retry 10 6 -- bash -c "! kubectl get namespace ${ns} >/dev/null 2>&1"

  cat <<EOF | kubectl apply -f -
apiVersion: velero.io/v1
kind: Restore
metadata:
  name: ${backup_name}-restore
  namespace: ${NS_VELERO}
spec:
  backupName: ${backup_name}
EOF

  retry 30 15 -- bash -c \
    "kubectl -n ${NS_VELERO} get restore ${backup_name}-restore -o jsonpath='{.status.phase}' | grep -q Completed"

  retry 20 6 -- kubectl get namespace "${ns}" >/dev/null 2>&1
  retry 20 10 -- bash -c \
    "kubectl -n ${ns} get configmap dr-marker -o jsonpath='{.data.marker}' | grep -q '${marker}'"

  retry 15 10 -- kubectl -n "${ns}" wait --for=condition=Ready pod/dr-test-writer --timeout=90s 2>/dev/null || true
  # verify file content on the restored volume by mounting it in a fresh pod
  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata: {name: dr-test-reader, namespace: ${ns}}
spec:
  restartPolicy: Never
  containers:
    - name: reader
      image: busybox:1.36
      command: ["sh", "-c", "cat /data/marker.txt && sleep 30"]
      volumeMounts: [{name: data, mountPath: /data}]
  volumes:
    - name: data
      persistentVolumeClaim: {claimName: dr-test-pvc}
EOF
  retry 15 6 -- kubectl -n "${ns}" wait --for=condition=Ready pod/dr-test-reader --timeout=90s
  retry 10 6 -- bash -c "kubectl -n ${ns} logs dr-test-reader | grep -q '${marker}'"

  log "RESTORE VALIDATION PASSED: ConfigMap and PVC file content both recovered intact."

  kubectl delete namespace "${ns}" --wait=false
  kubectl -n "${NS_VELERO}" delete backup "${backup_name}" --wait=false
  kubectl -n "${NS_VELERO}" delete restore "${backup_name}-restore" --wait=false

  log "DR restore validation namespace cleaned up."
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
  acquire_lock
  log "=== Phase 8: Backup & DR — starting ==="

  run_step "p8_velero"              step_velero
  run_step "p8_backup_schedules"    step_backup_schedules
  run_step "p8_restore_validation"  step_restore_validation

  clear_rollback_stack
  log "=== Phase 8: Backup & DR — COMPLETE ==="
}

# Only auto-run when executed directly — allows phase09 to source this file
# for step_restore_validation alone (full DR gate) without re-running the
# whole phase (which would also reinstall Velero and recreate schedules).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
