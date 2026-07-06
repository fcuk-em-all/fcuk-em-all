#!/usr/bin/env bash
# lib/common.sh - sourceable primitives for the FCUK-EM-ALL orchestrator.
# Extracted from the proven VM bootstrap scripts (1.sh/2.sh): four-level
# logging, dry-run/debug flags, run() narrate-or-execute, backup_file, a
# PROJECT_ROOT resolver, and jq-or-python JSON helpers. Source this; never run.

# Minimal-netinst lineage: sbin tools (ss, sysctl) are not on a plain PATH.
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

# --- Identity / state (the sourcing script may pre-set any of these) ---------
: "${LOG_TAG:=fcuk-em-all}"
: "${DRY_RUN:=0}"
: "${DEBUG:=0}"

# PROJECT_ROOT = parent of the dir holding this library, unless already set.
if [ -z "${PROJECT_ROOT:-}" ]; then
  _cmn_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  PROJECT_ROOT="$(dirname "$_cmn_dir")"
  unset _cmn_dir
fi
: "${LOG_FILE:=${PROJECT_ROOT}/state/orchestrator.log}"
: "${BACKUP_BASE:=${PROJECT_ROOT}/backups}"
: "${TS:=$(date +%Y%m%d_%H%M%S)}"

# --- Logging (four levels; DEBUG gated behind DEBUG=1) -----------------------
_log() {
  local lvl="$1"; shift
  local line
  line="[$(date '+%F %T')] [${LOG_TAG}] [$lvl] $*"
  echo "$line"
  mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
  echo "$line" >> "$LOG_FILE" 2>/dev/null || true
}
log_info()  { _log INFO  "$@"; }
log_warn()  { _log WARN  "$@"; }
log_error() { _log ERROR "$@"; }
log_debug() { [ "${DEBUG:-0}" -eq 1 ] && _log DEBUG "$@" || true; }

# --- Shared flag parsing -----------------------------------------------------
# The caller must define usage() first, then call: parse_common_flags "$@"
# Sets DRY_RUN/DEBUG. --help -> usage, exit 0. Unknown -> usage on stderr, exit 2.
parse_common_flags() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --dry-run) DRY_RUN=1 ;;
      --debug)   DEBUG=1 ;;
      -h|--help) usage; exit 0 ;;
      *) echo "Unknown argument: $arg" >&2; usage; exit 2 ;;
    esac
  done
}

# --- run(): narrate under dry-run, otherwise execute -------------------------
run() {
  if [ "${DRY_RUN:-0}" -eq 1 ]; then
    log_info "DRY-RUN would run: $*"
    return 0
  fi
  log_debug "exec: $*"
  "$@"
}

# --- backup_file <path>: timestamped copy before any edit --------------------
backup_file() {
  local f="$1"
  [ -f "$f" ] || { log_debug "no file to back up: $f"; return 0; }
  local dest="${BACKUP_BASE}/${TS}${f}"
  if [ "${DRY_RUN:-0}" -eq 1 ]; then
    log_info "DRY-RUN would back up $f -> $dest"
    return 0
  fi
  mkdir -p "$(dirname "$dest")"
  cp -p "$f" "$dest"
  log_info "backed up $f -> $dest"
}

# --- JSON helpers: jq if present, else python3 (jq is NOT installed here) -----
json_get() {
  # json_get <file> <dotted.key> -> prints scalar; nonzero exit if missing/null.
  local file="$1" key="$2"
  if command -v jq >/dev/null 2>&1; then
    jq -er ".${key}" "$file"
  else
    python3 - "$file" "$key" <<'JGET_PY'
import json, sys
f, key = sys.argv[1], sys.argv[2]
with open(f) as fh:
    d = json.load(fh)
for p in key.split("."):
    d = d[p]
if d is None:
    sys.exit(1)
sys.stdout.write(str(d))
JGET_PY
  fi
}

json_array_has() {
  # json_array_has <file> <dotted.key> <value> -> exit 0 if value in the array.
  local file="$1" key="$2" val="$3"
  if command -v jq >/dev/null 2>&1; then
    jq -e --arg v "$val" ".${key} | index(\$v) != null" "$file" >/dev/null 2>&1
  else
    python3 - "$file" "$key" "$val" <<'JHAS_PY'
import json, sys
f, key, val = sys.argv[1], sys.argv[2], sys.argv[3]
with open(f) as fh:
    d = json.load(fh)
for p in key.split("."):
    d = d[p]
sys.exit(0 if isinstance(d, list) and val in d else 1)
JHAS_PY
  fi
}
