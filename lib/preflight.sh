#!/usr/bin/env bash
# lib/preflight.sh - read-only system preflight for the FCUK-EM-ALL orchestrator.
#
# DETECTS and CLASSIFIES only. It changes nothing, disables nothing, aborts
# nothing - every verdict is RECORDED for later stages to act on (detect, not
# enforce). Network egress is deliberately OUT of scope here; it is a
# deploy-stage precondition, not a preflight one.
#
# Sourceable (bootstrap calls run_preflight) or runnable directly:
#     bash lib/preflight.sh [--dry-run] [--debug]
#
# Env overrides (config/output redirection + a portability seam for testing):
#   CONFIG_FILE    explicit config path (else config.json, else config.example.json)
#   PREFLIGHT_OUT  explicit artifact path (else state/preflight.json)
#   PF_VIRT_CMD    virt-detector command name (default systemd-detect-virt)

_pf_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "${_pf_dir}/common.sh"

: "${PF_VIRT_CMD:=systemd-detect-virt}"

# Config resolution: prefer a live config.json, else the committed example.
pf_config_file() {
  if [ -n "${CONFIG_FILE:-}" ]; then printf '%s' "$CONFIG_FILE"; return 0; fi
  if [ -f "${PROJECT_ROOT}/config.json" ]; then
    printf '%s' "${PROJECT_ROOT}/config.json"
  else
    printf '%s' "${PROJECT_ROOT}/config.example.json"
  fi
}

run_preflight() {
  local out="${PREFLIGHT_OUT:-${PROJECT_ROOT}/state/preflight.json}"
  local cfg; cfg="$(pf_config_file)"
  log_info "preflight: read-only detection; config=${cfg}; out=${out}"

  # --- system ---------------------------------------------------------------
  local os_id os_version arch kernel virt cpu_cores ram_mb root_free_mb root_free_gb root_fs_type
  os_id="$( . /etc/os-release 2>/dev/null; printf '%s' "${ID:-unknown}" )"
  os_version="$( . /etc/os-release 2>/dev/null; printf '%s' "${VERSION_ID:-unknown}" )"
  arch="$(uname -m 2>/dev/null || echo unknown)"
  kernel="$(uname -r 2>/dev/null || echo unknown)"
  if command -v "$PF_VIRT_CMD" >/dev/null 2>&1; then
    virt="$("$PF_VIRT_CMD" 2>/dev/null || true)"
    [ -z "$virt" ] && virt="none"
  else
    virt="unknown"
  fi
  cpu_cores="$(nproc 2>/dev/null || echo 0)"
  ram_mb="$(free -m 2>/dev/null | awk '/^Mem:/{print $2}')"; [ -z "$ram_mb" ] && ram_mb=0
  # Disk: detect precisely in MB (KB->MB); derive a ROUNDED GB convenience
  # value. The hard_stop comparison is done in MB (below) so a sub-1-GB box can
  # never truncate to 0 GB and be misclassified.
  root_free_mb="$(df -P -k / 2>/dev/null | awk 'NR==2{printf "%d", $4/1024}')"
  [ -z "$root_free_mb" ] && root_free_mb=0
  root_free_gb="$(awk -v mb="$root_free_mb" 'BEGIN{printf "%d", (mb/1024)+0.5}')"
  root_fs_type="$(df -PT / 2>/dev/null | awk 'NR==2{print $2}')"
  [ -z "$root_fs_type" ] && root_fs_type=unknown

  # --- gpu: gate on PCI vendor ID; /dev/dri alone is NOT enough (vmwgfx etc.) -
  # verified=false on every branch here: a read-only preflight never exercises a
  # transcode, so the QSV/NVENC/VAAPI path is real code but stays DEFERRED to
  # real amd64 Intel/NVIDIA hardware (see PROJECT.md).
  local gpu_vendor="none" gpu_detail="" gpu_verified="false"
  if command -v nvidia-smi >/dev/null 2>&1 || ls /dev/nvidia* >/dev/null 2>&1; then
    gpu_vendor="nvidia"
    gpu_detail="NVIDIA device present; NVENC path real but unverified here (deferred to NVIDIA hardware)"
  elif [ -d /sys/class/drm ]; then
    local v vid found=""
    for v in /sys/class/drm/card*/device/vendor; do
      [ -r "$v" ] || continue
      vid="$(cat "$v" 2>/dev/null || true)"
      case "$vid" in
        0x8086) found="intel";  break ;;
        0x10de) found="nvidia"; break ;;
        0x1002) found="amd";    break ;;
      esac
    done
    case "$found" in
      intel)
        gpu_vendor="intel"
        gpu_detail="Intel iGPU (PCI 0x8086); QSV/VAAPI path real but unverified here (deferred to amd64 Intel hardware)" ;;
      nvidia)
        gpu_vendor="nvidia"
        gpu_detail="NVIDIA GPU (PCI 0x10de); NVENC path real but unverified here (deferred)" ;;
      amd)
        gpu_vendor="amd"
        gpu_detail="AMD GPU (PCI 0x1002); VAAPI best-effort, unverified here (deferred)" ;;
      *)
        gpu_vendor="none"
        local seen; seen="$(ls /dev/dri 2>/dev/null | tr '\n' ' ' | sed 's/ *$//')"
        if [ -n "$seen" ]; then
          gpu_detail="DRI nodes present (${seen}) but no Intel/NVIDIA/AMD PCI vendor - virtual/unsupported GPU; CPU-only software transcode"
        else
          gpu_detail="no /dev/dri and no NVIDIA device; CPU-only software transcode"
        fi ;;
    esac
  else
    gpu_vendor="none"
    gpu_detail="no /sys/class/drm; CPU-only software transcode"
  fi

  # --- runtime --------------------------------------------------------------
  local docker_present="false" compose_present="false"
  if command -v docker >/dev/null 2>&1; then
    docker_present="true"
    if docker compose version >/dev/null 2>&1; then
      compose_present="true"
    fi
  fi
  if [ "$compose_present" = "false" ] && command -v docker-compose >/dev/null 2>&1; then
    compose_present="true"
  fi

  # --- thresholds (from config via json_get; never hardcoded) ---------------
  local min_ram min_disk immich_ram
  min_ram="$(json_get "$cfg" preflight.min_ram_mb)"
  min_disk="$(json_get "$cfg" preflight.min_free_disk_gb)"
  immich_ram="$(json_get "$cfg" preflight.immich_min_ram_mb)"

  # --- classification: RECORD verdicts; act on NONE -------------------------
  # VERDICT STATUS CONTRACT (per tier - keep the classifier conformant; drift
  # against this vocabulary is caught at runtime by add_verdict below):
  #   hard_stop    -> pass | fail   (a hard requirement is met, or it is not)
  #   capability   -> pass | warn   (capability present, or degraded fallback)
  #   per_app_gate -> ok   | gated  (app enabled-safe, or gated with a reason)
  local verdicts=""
  # add_verdict <id> <tier> <status> <detail> - enforces the contract above;
  # an out-of-vocabulary (tier,status) pair is a hard error, never silent.
  add_verdict() {
    local _id="$1" _tier="$2" _status="$3" _detail="$4" _ok=0
    case "$_tier" in
      hard_stop)    case "$_status" in pass|fail) _ok=1 ;; esac ;;
      capability)   case "$_status" in pass|warn) _ok=1 ;; esac ;;
      per_app_gate) case "$_status" in ok|gated)  _ok=1 ;; esac ;;
    esac
    if [ "$_ok" -ne 1 ]; then
      log_error "preflight: verdict '${_id}' status '${_status}' is out-of-contract for tier '${_tier}'"
      return 1
    fi
    verdicts+="$(printf '%s\t%s\t%s\t%s' "$_id" "$_tier" "$_status" "$_detail")"$'\n'
  }

  # hard_stop tier
  case "$arch" in
    x86_64|amd64|aarch64|arm64)
      add_verdict arch_64bit hard_stop pass "arch ${arch} is 64-bit" ;;
    *)
      add_verdict arch_64bit hard_stop fail "arch ${arch} is not 64-bit" ;;
  esac
  if [ "$ram_mb" -ge "$min_ram" ]; then
    add_verdict min_ram hard_stop pass "RAM ${ram_mb}MB >= ${min_ram}MB"
  else
    add_verdict min_ram hard_stop fail "RAM ${ram_mb}MB < ${min_ram}MB"
  fi
  local min_disk_mb=$(( min_disk * 1024 ))
  if [ "$root_free_mb" -ge "$min_disk_mb" ]; then
    add_verdict min_free_disk hard_stop pass "root free ${root_free_mb}MB (~${root_free_gb}GB) >= ${min_disk}GB"
  else
    add_verdict min_free_disk hard_stop fail "root free ${root_free_mb}MB (~${root_free_gb}GB) < ${min_disk}GB"
  fi

  # capability tier
  if [ "$gpu_vendor" = "none" ]; then
    add_verdict gpu_transcode capability warn "no usable GPU; CPU-only software transcode"
  else
    add_verdict gpu_transcode capability pass "GPU ${gpu_vendor} detected; hardware-transcode verification deferred"
  fi

  # per_app_gate tier: immich
  local immich_fs_ok="no"
  if json_array_has "$cfg" preflight.immich_db_filesystems "$root_fs_type"; then
    immich_fs_ok="yes"
  fi
  if [ "$ram_mb" -ge "$immich_ram" ] && [ "$immich_fs_ok" = "yes" ]; then
    add_verdict immich per_app_gate ok "RAM ${ram_mb}MB >= ${immich_ram}MB and fs ${root_fs_type} supported"
  else
    local why=""
    [ "$ram_mb" -ge "$immich_ram" ] || why="RAM ${ram_mb}MB < ${immich_ram}MB"
    if [ "$immich_fs_ok" != "yes" ]; then
      [ -n "$why" ] && why="${why}; "
      why="${why}fs ${root_fs_type} not in supported set"
    fi
    add_verdict immich per_app_gate gated "$why"
  fi

  # --- emit artifact (or narrate under dry-run) -----------------------------
  if [ "${DRY_RUN:-0}" -eq 1 ]; then
    log_info "DRY-RUN would write preflight artifact -> ${out}"
    log_info "DRY-RUN detected: os=${os_id}/${os_version} arch=${arch} virt=${virt} cores=${cpu_cores} ram=${ram_mb}MB free=${root_free_gb}GB fs=${root_fs_type} gpu=${gpu_vendor} docker=${docker_present} compose=${compose_present}"
    return 0
  fi

  mkdir -p "$(dirname "$out")"
  local gen_at; gen_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  PF_OUT="$out" PF_GEN_AT="$gen_at" \
  PF_OS_ID="$os_id" PF_OS_VERSION="$os_version" PF_ARCH="$arch" PF_KERNEL="$kernel" \
  PF_VIRT="$virt" PF_CORES="$cpu_cores" PF_RAM="$ram_mb" PF_FREE_MB="$root_free_mb" PF_FREE="$root_free_gb" PF_FS="$root_fs_type" \
  PF_GPU_VENDOR="$gpu_vendor" PF_GPU_DETAIL="$gpu_detail" PF_GPU_VERIFIED="$gpu_verified" \
  PF_DOCKER="$docker_present" PF_COMPOSE="$compose_present" PF_VERDICTS="$verdicts" \
  python3 - <<'PFWRITE_PY'
import os, json
def b(x):
    return x == "true"
verdicts = []
for line in os.environ.get("PF_VERDICTS", "").splitlines():
    if not line.strip():
        continue
    parts = line.split("\t")
    if len(parts) < 4:
        continue
    verdicts.append({
        "id": parts[0],
        "tier": parts[1],
        "status": parts[2],
        "detail": "\t".join(parts[3:]),
    })
doc = {
    "generated_at": os.environ["PF_GEN_AT"],
    "system": {
        "os_id": os.environ["PF_OS_ID"],
        "os_version": os.environ["PF_OS_VERSION"],
        "arch": os.environ["PF_ARCH"],
        "kernel": os.environ["PF_KERNEL"],
        "virt": os.environ["PF_VIRT"],
        "cpu_cores": int(os.environ["PF_CORES"]),
        "ram_mb": int(os.environ["PF_RAM"]),
        "root_free_mb": int(os.environ["PF_FREE_MB"]),
        "root_free_gb": int(os.environ["PF_FREE"]),
        "root_fs_type": os.environ["PF_FS"],
    },
    "gpu": {
        "vendor": os.environ["PF_GPU_VENDOR"],
        "detail": os.environ["PF_GPU_DETAIL"],
        "verified": b(os.environ["PF_GPU_VERIFIED"]),
    },
    "runtime": {
        "docker_present": b(os.environ["PF_DOCKER"]),
        "compose_present": b(os.environ["PF_COMPOSE"]),
    },
    "verdicts": verdicts,
}
with open(os.environ["PF_OUT"], "w") as fh:
    json.dump(doc, fh, indent=2)
    fh.write("\n")
PFWRITE_PY
  log_info "preflight: wrote ${out} ($(printf '%s' "$verdicts" | grep -c . ) verdicts recorded)"
}

# If executed directly (not sourced), parse flags and run.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  set -euo pipefail
  usage() {
    cat <<'PF_USAGE'
Usage: bash lib/preflight.sh [--dry-run] [--debug]
  Read-only system preflight: detect, classify, write state/preflight.json.
  --dry-run  Narrate detection; write no artifact.
  --debug    Verbose logging.
PF_USAGE
  }
  # shellcheck disable=SC2034  # LOG_TAG is consumed by the sourced lib/common.sh logger
  LOG_TAG="preflight"
  parse_common_flags "$@"
  run_preflight
fi
