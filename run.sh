#!/usr/bin/env bash
# =============================================================================
# run.sh — orchestrator for the microsvc.store platform bootstrap
#
# Usage:
#   sudo ./run.sh                     # run all phases sequentially, resuming
#                                      # automatically from the last incomplete step
#   sudo ./run.sh --from-phase 3      # start at phase 3 (skips 1-2 even if unmarked)
#   sudo ./run.sh --only-phase 2      # run exactly one phase
#   sudo ./run.sh --reset-phase 2     # clear completion state for phase 2, then exit
#   sudo ./run.sh --status            # show which steps are completed
# =============================================================================
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

PHASES=(
  "1:phase01-foundation.sh:Foundation"
  "2:phase02-cluster-core.sh:Cluster Core"
  "3:phase03-platform-services.sh:Platform Services"
  "4:phase04-devops.sh:DevOps (Harbor/GitLab)"
  "5:phase05-gitops.sh:GitOps (Argo CD)"
  "6:phase06-observability.sh:Observability"
  "7:phase07-quality-security.sh:Quality & Security"
  "8:phase08-backup-dr.sh:Backup & DR (Velero)"
  "9:phase09-validation.sh:Final Validation"
)

usage() { grep '^#' "$0" | sed -n '2,12p'; exit 1; }

FROM_PHASE=1
ONLY_PHASE=""
STATUS_ONLY=false
RESET_PHASE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --from-phase) FROM_PHASE="$2"; shift 2 ;;
    --only-phase) ONLY_PHASE="$2"; shift 2 ;;
    --reset-phase) RESET_PHASE="$2"; shift 2 ;;
    --status) STATUS_ONLY=true; shift ;;
    -h|--help) usage ;;
    *) error "Unknown argument: $1"; usage ;;
  esac
done

show_status() {
  log "Completed steps in ${STATE_FILE}:"
  if [[ -s "${STATE_FILE}" ]]; then
    sort "${STATE_FILE}" | tee -a "${LOG_FILE}"
  else
    log "  (none yet — fresh environment)"
  fi
}

if ${STATUS_ONLY}; then
  show_status
  exit 0
fi

if [[ -n "${RESET_PHASE}" ]]; then
  for entry in "${PHASES[@]}"; do
    IFS=':' read -r num script name <<<<"${entry}"
    if [[ "${num}" == "${RESET_PHASE}" ]]; then
      grep -oP "^STEP_p${num}_\K.*(?==done)" "${STATE_FILE}" 2>/dev/null | while read -r _; do :; done
      grep -v "^STEP_p${num}_" "${STATE_FILE}" > "${STATE_FILE}.tmp" 2>/dev/null || true
      mv "${STATE_FILE}.tmp" "${STATE_FILE}"
      log "Phase ${num} (${name}) state cleared. It will fully re-run next invocation."
      exit 0
    fi
  done
  fatal "No such phase: ${RESET_PHASE}"
fi

require_root

log "############################################################"
log "  microsvc.store platform bootstrap"
log "  Start time: $(_ts)"
log "############################################################"

for entry in "${PHASES[@]}"; do
  IFS=':' read -r num script name <<<<"${entry}"

  if [[ -n "${ONLY_PHASE}" && "${num}" != "${ONLY_PHASE}" ]]; then
    continue
  fi
  if [[ -z "${ONLY_PHASE}" && "${num}" -lt "${FROM_PHASE}" ]]; then
    log "Skipping Phase ${num} (${name}) — before --from-phase ${FROM_PHASE}."
    continue
  fi

  script_path="${SCRIPT_DIR}/phases/${script}"
  if [[ ! -f "${script_path}" ]]; then
    warn "Phase ${num} (${name}) script not yet present at ${script_path} — skipping."
    warn "Generate it from the established phase template before running --from-phase ${num}."
    continue
  fi

  log ">>> Entering Phase ${num}: ${name}"
  bash "${script_path}"
  log "<<< Phase ${num}: ${name} finished."
done

log "############################################################"
log "  Bootstrap run complete: $(_ts)"
log "  Run './run.sh --status' any time to review completed steps."
log "############################################################"
