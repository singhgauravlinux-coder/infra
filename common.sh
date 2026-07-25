#!/usr/bin/env bash
# =============================================================================
# lib/common.sh — shared runtime for microsvc.store platform bootstrap
#
# Sourced by every phase script. Provides:
#   - structured logging
#   - exponential-backoff retry wrapper
#   - idempotent step tracking (resume-from-failure)
#   - rollback hook registry (LIFO, invoked on fatal error)
#   - generic validation helpers (kubectl wait, helm wait, http/tls checks)
# =============================================================================
set -Eeuo pipefail
IFS=$'\n\t'

# ---------------------------------------------------------------------------
# Paths / globals
# ---------------------------------------------------------------------------
PLATFORM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="${STATE_DIR:-/var/lib/microservice-platform}"
STATE_FILE="${STATE_DIR}/state.env"          # completed steps: STEP_<name>=done
LOG_DIR="${STATE_DIR}/logs"
LOG_FILE="${LOG_DIR}/$(date +%Y%m%d)-bootstrap.log"
LOCK_FILE="${STATE_DIR}/bootstrap.lock"
ROLLBACK_STACK_FILE="${STATE_DIR}/rollback.stack"

mkdir -p "${STATE_DIR}" "${LOG_DIR}"
touch "${STATE_FILE}" "${ROLLBACK_STACK_FILE}"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
_ts() { date '+%Y-%m-%d %H:%M:%S%z'; }

log()   { printf '[%s] [INFO ] %s\n'  "$(_ts)" "$*" | tee -a "${LOG_FILE}"; }
warn()  { printf '[%s] [WARN ] %s\n'  "$(_ts)" "$*" | tee -a "${LOG_FILE}" >&2; }
error() { printf '[%s] [ERROR] %s\n'  "$(_ts)" "$*" | tee -a "${LOG_FILE}" >&2; }
debug() { [[ "${DEBUG:-0}" == "1" ]] && printf '[%s] [DEBUG] %s\n' "$(_ts)" "$*" | tee -a "${LOG_FILE}" || true; }

fatal() {
  error "$*"
  error "Fatal error — invoking rollback stack before exit."
  run_rollback_stack
  exit 1
}

trap 'error "Unhandled error at line ${LINENO} (exit code $?). Command: ${BASH_COMMAND}"; run_rollback_stack; exit 1' ERR

# ---------------------------------------------------------------------------
# Single-instance lock (prevents two concurrent bootstrap runs)
# ---------------------------------------------------------------------------
acquire_lock() {
  exec 200>"${LOCK_FILE}"
  if ! flock -n 200; then
    fatal "Another bootstrap run holds the lock (${LOCK_FILE}). Aborting."
  fi
  echo "$$" >&200
}

# ---------------------------------------------------------------------------
# Idempotent step tracking
#   step_done <name>            -> 0 if already completed
#   mark_step_done <name>
#   run_step <name> <fn> [args] -> skips if already done, marks done on success
# ---------------------------------------------------------------------------
step_done() {
  local name="$1"
  grep -qxF "STEP_${name}=done" "${STATE_FILE}" 2>/dev/null
}

mark_step_done() {
  local name="$1"
  # remove any stale entry then append — keeps file idempotent on re-run
  grep -vxF "STEP_${name}=done" "${STATE_FILE}" > "${STATE_FILE}.tmp" 2>/dev/null || true
  mv "${STATE_FILE}.tmp" "${STATE_FILE}"
  echo "STEP_${name}=done" >> "${STATE_FILE}"
}

reset_step() {
  local name="$1"
  grep -vxF "STEP_${name}=done" "${STATE_FILE}" > "${STATE_FILE}.tmp" 2>/dev/null || true
  mv "${STATE_FILE}.tmp" "${STATE_FILE}"
  log "State reset for step '${name}' — it will re-run."
}

run_step() {
  local name="$1"; shift
  local fn="$1"; shift || true

  if step_done "${name}"; then
    log "SKIP  [${name}] already completed (resume mode)."
    return 0
  fi

  log "START [${name}]"
  local start_ts elapsed
  start_ts=$(date +%s)

  if "${fn}" "$@"; then
    elapsed=$(( $(date +%s) - start_ts ))
    mark_step_done "${name}"
    log "DONE  [${name}] (${elapsed}s)"
  else
    error "FAILED [${name}] — re-run this script to resume from this step."
    fatal "Step '${name}' did not complete successfully."
  fi
}

# ---------------------------------------------------------------------------
# Rollback registry (LIFO). Each phase pushes an undo command as it makes
# state changes; on fatal error the whole stack unwinds automatically.
# Only used for *this run's* new changes — completed steps from prior runs
# are never rolled back automatically (call --rollback-phase explicitly).
# ---------------------------------------------------------------------------
push_rollback() {
  # store as a single-line base64 blob so arbitrary commands/quotes survive
  local cmd="$*"
  printf '%s\n' "$(echo -n "${cmd}" | base64 -w0)" >> "${ROLLBACK_STACK_FILE}"
}

run_rollback_stack() {
  [[ -s "${ROLLBACK_STACK_FILE}" ]] || return 0
  warn "Executing rollback stack (LIFO)..."
  tac "${ROLLBACK_STACK_FILE}" | while read -r encoded; do
    local cmd
    cmd="$(echo -n "${encoded}" | base64 -d)"
    warn "  rollback> ${cmd}"
    bash -c "${cmd}" || warn "  rollback step failed, continuing unwind."
  done
  : > "${ROLLBACK_STACK_FILE}"
}

clear_rollback_stack() {
  : > "${ROLLBACK_STACK_FILE}"
}

# ---------------------------------------------------------------------------
# Retry wrapper with exponential backoff + jitter
#   retry <max_attempts> <base_delay_seconds> -- cmd args...
# ---------------------------------------------------------------------------
retry() {
  local max_attempts="$1"; shift
  local base_delay="$1"; shift
  [[ "$1" == "--" ]] && shift

  local attempt=1
  local delay="${base_delay}"
  until "$@"; do
    if (( attempt >= max_attempts )); then
      error "Command failed after ${attempt} attempts: $*"
      return 1
    fi
    local jitter=$(( RANDOM % 3 ))
    warn "Attempt ${attempt}/${max_attempts} failed: $*  — retrying in $((delay+jitter))s"
    sleep $((delay + jitter))
    delay=$(( delay * 2 ))
    (( attempt++ ))
  done
  return 0
}

# ---------------------------------------------------------------------------
# Validation helpers
# ---------------------------------------------------------------------------
require_root() {
  [[ "${EUID}" -eq 0 ]] || fatal "This script must be run as root (use sudo)."
}

require_cmd() {
  local c
  for c in "$@"; do
    command -v "${c}" >/dev/null 2>&1 || fatal "Required command not found: ${c}"
  done
}

check_min_resources() {
  local min_cpu="$1" min_mem_gb="$2" min_disk_gb="$3"
  local cpu mem_kb mem_gb disk_gb
  cpu=$(nproc)
  mem_kb=$(awk '/MemTotal/{print $2}' /proc/meminfo)
  mem_gb=$(( mem_kb / 1024 / 1024 ))
  disk_gb=$(df --output=avail -BG / | tail -1 | tr -dc '0-9')

  (( cpu >= min_cpu ))       || fatal "Insufficient CPU: have ${cpu}, need >= ${min_cpu}"
  (( mem_gb >= min_mem_gb )) || fatal "Insufficient RAM: have ${mem_gb}GB, need >= ${min_mem_gb}GB"
  (( disk_gb >= min_disk_gb )) || fatal "Insufficient free disk on /: have ${disk_gb}GB, need >= ${min_disk_gb}GB"
  log "Resource check OK: ${cpu} vCPU, ${mem_gb}GB RAM, ${disk_gb}GB free disk."
}

kubectl_wait_ready() {
  local ns="$1" selector="$2" timeout="${3:-300s}"
  retry 5 5 -- kubectl -n "${ns}" wait --for=condition=Ready pod -l "${selector}" --timeout="${timeout}"
}

rollout_wait() {
  local kind="$1" name="$2" ns="$3" timeout="${4:-300s}"
  retry 5 5 -- kubectl -n "${ns}" rollout status "${kind}/${name}" --timeout="${timeout}"
}

helm_upgrade_install() {
  # usage: helm_upgrade_install <release> <chart> <ns> <values_file_or_-> [extra helm args...]
  local release="$1" chart="$2" ns="$3" values="$4"; shift 4
  local values_args=()
  [[ "${values}" != "-" ]] && values_args=(-f "${values}")

  retry 3 10 -- helm upgrade --install "${release}" "${chart}" \
    --namespace "${ns}" --create-namespace \
    "${values_args[@]}" \
    --wait --wait-for-jobs --timeout 10m \
    "$@"
}

http_check() {
  local url="$1" expect_code="${2:-200}" timeout="${3:-10}"
  local code
  code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time "${timeout}" "${url}" || echo "000")
  [[ "${code}" == "${expect_code}" ]]
}

tls_check() {
  local host="$1" port="${2:-443}"
  echo | openssl s_client -servername "${host}" -connect "${host}:${port}" 2>/dev/null \
    | openssl x509 -noout -enddate 2>/dev/null
}

dns_check() {
  local fqdn="$1" expected_ip="$2"
  local resolved
  resolved=$(dig +short "${fqdn}" | tail -1)
  [[ "${resolved}" == "${expected_ip}" ]]
}

# ---------------------------------------------------------------------------
# Secret helpers — idempotent random-secret generation
#   get_or_create_secret_value <ns> <secret_name> <key> [length]
#     - if the key already exists in the secret, returns it unchanged
#       (so repeated runs never rotate credentials underneath a running app)
#     - otherwise generates a random value, stores it, and returns it
#   Namespace is created if missing.
# ---------------------------------------------------------------------------
ensure_namespace() {
  local ns="$1"
  kubectl get namespace "${ns}" >/dev/null 2>&1 || kubectl create namespace "${ns}"
}

get_or_create_secret_value() {
  local ns="$1" name="$2" key="$3" length="${4:-32}"
  ensure_namespace "${ns}" >/dev/null

  local existing
  existing=$(kubectl -n "${ns}" get secret "${name}" -o jsonpath="{.data.${key}}" 2>/dev/null || true)

  if [[ -n "${existing}" ]]; then
    echo "${existing}" | base64 -d
    return 0
  fi

  local value
  value=$(openssl rand -base64 "${length}" | tr -d '\n=+/' | cut -c1-"${length}")

  if kubectl -n "${ns}" get secret "${name}" >/dev/null 2>&1; then
    kubectl -n "${ns}" patch secret "${name}" \
      --type=json -p="[{\"op\":\"add\",\"path\":\"/data/${key}\",\"value\":\"$(echo -n "${value}" | base64 -w0)\"}]" >/dev/null
  else
    kubectl -n "${ns}" create secret generic "${name}" \
      --from-literal="${key}=${value}" >/dev/null
  fi
  echo "${value}"
}

secret_key_exists() {
  local ns="$1" name="$2" key="$3"
  kubectl -n "${ns}" get secret "${name}" -o jsonpath="{.data.${key}}" 2>/dev/null | grep -q .
}

# ---------------------------------------------------------------------------
# Load environment config
# ---------------------------------------------------------------------------
load_config() {
  local cfg="${PLATFORM_ROOT}/config/platform.env"
  [[ -f "${cfg}" ]] || fatal "Missing config file: ${cfg}"
  # shellcheck disable=SC1090
  source "${cfg}"
}
