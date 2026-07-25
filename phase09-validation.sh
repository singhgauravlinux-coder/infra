#!/usr/bin/env bash
# =============================================================================
# Phase 9 — Final Validation
#   Aggregates a pass/fail health matrix across everything built in Phases 1-8.
#   Exit code 0 only if every check passes — safe to wire into CI/monitoring.
#   Does NOT re-run Phase 8's destructive restore test by default (that's a
#   real delete-then-restore in dr-restore-validation); pass --with-dr-test
#   to include it here too as a full go-live gate.
# =============================================================================
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../lib/common.sh"
load_config
export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"

declare -a RESULTS=()   # "PASS|check name" or "FAIL|check name|detail"
FAIL_COUNT=0

record() {
  local status="$1" name="$2" detail="${3:-}"
  RESULTS+=("${status}|${name}|${detail}")
  if [[ "${status}" == "FAIL" ]]; then
    (( FAIL_COUNT++ ))
    error "FAIL  ${name} ${detail:+— ${detail}}"
  else
    log   "PASS  ${name}"
  fi
}

check() {
  # check "name" -- cmd args...
  local name="$1"; shift; [[ "$1" == "--" ]] && shift
  if "$@" >/tmp/check_out.$$ 2>&1; then
    record PASS "${name}"
  else
    record FAIL "${name}" "$(tail -3 /tmp/check_out.$$ | tr '\n' ' ')"
  fi
  rm -f /tmp/check_out.$$
}

# -----------------------------------------------------------------------------
# Health checks — node + core namespace rollout status
# -----------------------------------------------------------------------------
section_health_checks() {
  log "--- Health checks ---"
  check "all nodes Ready" -- bash -c "kubectl get nodes --no-headers | awk '{print \$2}' | grep -qv Ready && exit 1 || exit 0"

  local deployments=(
    "${NS_INGRESS}:traefik"
    "${NS_CERT_MANAGER}:cert-manager"
    "${NS_CATTLE_SYSTEM}:rancher"
    "${NS_SECURITY}:infisical"
    "${NS_SECURITY}:external-secrets"
    "${NS_IDENTITY}:keycloak"
    "${NS_DEVOPS}:harbor-core"
    "${NS_ARGOCD}:argocd-server"
    "${NS_OBSERVABILITY}:kube-prometheus-stack-grafana"
    "${NS_VELERO}:velero"
  )
  for entry in "${deployments[@]}"; do
    IFS=':' read -r ns dep <<<"${entry}"
    check "rollout: ${ns}/${dep}" -- kubectl -n "${ns}" rollout status "deploy/${dep}" --timeout=30s
  done

  check "postgres cluster healthy" -- bash -c \
    "kubectl -n ${NS_DATA} get cluster platform-postgres -o jsonpath='{.status.phase}' | grep -q 'healthy'"
  check "redis master ready" -- kubectl -n "${NS_DATA}" rollout status statefulset/platform-redis-master --timeout=30s
}

# -----------------------------------------------------------------------------
# TLS verification — every published host serves a valid, non-expiring-soon cert
# -----------------------------------------------------------------------------
section_tls_verification() {
  log "--- TLS verification ---"
  local hosts=(
    "${RANCHER_HOST}" "${ARGOCD_HOST}" "${GITLAB_HOST}" "${HARBOR_HOST}"
    "${KEYCLOAK_HOST}" "${GRAFANA_HOST}" "${SONARQUBE_HOST}" "${INFISICAL_HOST}"
  )
  for h in "${hosts[@]}"; do
    check "TLS cert valid: ${h}" -- bash -c "
      end_date=\$(echo | openssl s_client -servername '${h}' -connect '${h}:443' 2>/dev/null \
        | openssl x509 -noout -enddate | cut -d= -f2)
      [[ -n \"\${end_date}\" ]] || exit 1
      end_epoch=\$(date -d \"\${end_date}\" +%s)
      now_epoch=\$(date +%s)
      days_left=\$(( (end_epoch - now_epoch) / 86400 ))
      (( days_left > 7 ))
    "
  done
}

# -----------------------------------------------------------------------------
# DNS verification — ExternalDNS actually created the records it should have
# -----------------------------------------------------------------------------
section_dns_verification() {
  log "--- DNS verification ---"
  local lb_ip
  lb_ip=$(kubectl -n "${NS_INGRESS}" get svc traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  if [[ -z "${lb_ip}" ]]; then
    record FAIL "traefik LoadBalancer IP assigned" "no external IP on traefik service yet"
  else
    record PASS "traefik LoadBalancer IP assigned (${lb_ip})"
    local hosts=("${RANCHER_HOST}" "${ARGOCD_HOST}" "${GITLAB_HOST}" "${HARBOR_HOST}" "${GRAFANA_HOST}")
    for h in "${hosts[@]}"; do
      check "DNS resolves: ${h} -> ${lb_ip}" -- dns_check "${h}" "${lb_ip}"
    done
  fi
}

# -----------------------------------------------------------------------------
# CI/CD validation — reuse phase 4's smoke test logic as a health gate
# -----------------------------------------------------------------------------
section_cicd_validation() {
  log "--- CI/CD validation ---"
  if kubectl -n "${NS_DEVOPS}" get secret gitlab-runner-token >/dev/null 2>&1; then
    check "GitLab Runner registered & running" -- kubectl -n "${NS_DEVOPS}" rollout status \
      deploy/gitlab-runner-gitlab-runner --timeout=30s
    check "GitLab CI/CD smoke pipeline" -- bash "${SCRIPT_DIR}/phase04-devops.sh" __smoke_only
  else
    record FAIL "GitLab Runner registered" "no gitlab-runner-token secret present"
  fi
}

# -----------------------------------------------------------------------------
# GitOps reconciliation validation
# -----------------------------------------------------------------------------
section_gitops_validation() {
  log "--- GitOps validation ---"
  check "root-app-of-apps Synced" -- bash -c \
    "kubectl -n ${NS_ARGOCD} get application root-app-of-apps -o jsonpath='{.status.sync.status}' | grep -q Synced"
  check "root-app-of-apps Healthy" -- bash -c \
    "kubectl -n ${NS_ARGOCD} get application root-app-of-apps -o jsonpath='{.status.health.status}' | grep -q Healthy"
}

# -----------------------------------------------------------------------------
# Disaster recovery test (optional, destructive — opt in explicitly)
# -----------------------------------------------------------------------------
section_dr_test() {
  log "--- Disaster recovery test (destructive restore-validation) ---"
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/phase08-backup-dr.sh"   # guarded — sourcing does not re-run main
  check "Velero backup/restore round-trip" -- step_restore_validation
}

# -----------------------------------------------------------------------------
# Report
# -----------------------------------------------------------------------------
print_report() {
  echo
  echo "============================================================"
  echo " microsvc.store platform — validation report — $(_ts)"
  echo "============================================================"
  local pass=0 fail=0
  for r in "${RESULTS[@]}"; do
    IFS='|' read -r status name detail <<<"${r}"
    if [[ "${status}" == "PASS" ]]; then
      printf "  [PASS] %s\n" "${name}"; (( pass++ ))
    else
      printf "  [FAIL] %s — %s\n" "${name}" "${detail}"; (( fail++ ))
    fi
  done
  echo "------------------------------------------------------------"
  echo " Total: $((pass+fail))   Passed: ${pass}   Failed: ${fail}"
  echo "============================================================"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
  local with_dr=false
  [[ "${1:-}" == "--with-dr-test" ]] && with_dr=true

  log "=== Phase 9: Final Validation — starting ==="

  section_health_checks
  section_tls_verification
  section_dns_verification
  section_gitops_validation
  section_cicd_validation
  ${with_dr} && section_dr_test

  print_report

  if (( FAIL_COUNT > 0 )); then
    error "=== Phase 9: Final Validation — FAILED (${FAIL_COUNT} check(s)) ==="
    exit 1
  fi

  log "=== Phase 9: Final Validation — ALL CHECKS PASSED ==="
  exit 0
}

main "$@"
