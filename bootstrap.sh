#!/usr/bin/env bash
# bootstrap.sh - FCUK-EM-ALL appliance orchestrator entry point.
#
# Public, multi-OS, multi-architecture installer. Reads config.json (copy it
# from config.example.json first), validates it, detects the host, then runs:
#   preflight -> tls -> crontab -> hosts -> modules(up) -> verify
# Every mutating step is guarded by --dry-run and is idempotent. Secrets are
# never printed. No path is hardcoded to any one machine or domain.
#
#   bash bootstrap.sh [--dry-run] [--debug] [--verify-only] [--help]

set -euo pipefail

BOOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$BOOT_DIR"
# shellcheck source=lib/common.sh
. "${PROJECT_ROOT}/lib/common.sh"
# shellcheck disable=SC2034  # LOG_TAG is consumed by the sourced lib/common.sh logger
LOG_TAG="bootstrap"

CONFIG="${PROJECT_ROOT}/config.json"
EXAMPLE="${PROJECT_ROOT}/config.example.json"
LOCKFILE="${PROJECT_ROOT}/state/bootstrap.lock"
CRON_TAG="fcuk-em-all"

# Every appliance subdomain (used for local-mode /etc/hosts + verify).
SUBDOMAINS="stream auth jellyfin navidrome kavita audiobookshelf immich requests radarr sonarr prowlarr qbittorrent"

usage() {
  cat <<'BOOT_USAGE'
Usage: bash bootstrap.sh [--dry-run] [--debug] [--verify-only] [--help]
  Installs / updates the appliance, then verifies it.
  Stages: preflight -> tls -> crontab -> hosts -> modules -> verify.
  --verify-only  Run ONLY the whole-appliance health check (read-only). 30 checks.
  --dry-run      Narrate every action; write/install/contact/start nothing.
  --debug        Verbose (DEBUG-level) logging.
  --help         Show this help and exit.
BOOT_USAGE
}

# --verify-only is bootstrap-specific; strip it before parse_common_flags
# (which rejects unknown flags), but remember it.
BOOT_VERIFY_ONLY=0
_args=""
for a in "$@"; do
  if [ "$a" = "--verify-only" ]; then BOOT_VERIFY_ONLY=1; else _args="${_args} ${a}"; fi
done
# shellcheck disable=SC2086
parse_common_flags $_args

# ---------------------------------------------------------------------------
# Host detection
# ---------------------------------------------------------------------------
detect_os() {
  local uname_s; uname_s="$(uname -s)"
  case "$uname_s" in
    Linux)
      [ -r /etc/os-release ] || { log_error "cannot read /etc/os-release; unsupported Linux"; return 1; }
      # shellcheck disable=SC1091
      . /etc/os-release
      OS_ID="${ID:-unknown}"; OS_VER="${VERSION_ID:-}"
      # Debian testing/unstable (and pre-release trixie/forky) ship no VERSION_ID;
      # derive the major version from the codename (then /etc/debian_version) so
      # detection does not fail with "unknown". Mirrors install.sh check_system.
      if [ -z "$OS_VER" ] && [ "$OS_ID" = "debian" ]; then
        case "${VERSION_CODENAME:-}" in
          forky)    OS_VER="14" ;;
          trixie)   OS_VER="13" ;;
          bookworm) OS_VER="12" ;;
          bullseye) OS_VER="11" ;;
          *)
            if [ -r /etc/debian_version ]; then
              case "$(cat /etc/debian_version)" in
                14*|forky*)    OS_VER="14" ;;
                13*|trixie*)   OS_VER="13" ;;
                12*|bookworm*) OS_VER="12" ;;
              esac
            fi ;;
        esac
      fi
      : "${OS_VER:=unknown}"
      case "${OS_ID}:${OS_VER}" in
        debian:12|debian:13|debian:14) : ;;
        ubuntu:22.04|ubuntu:24.04) : ;;
        *) log_error "unsupported OS: ${OS_ID} ${OS_VER} (supported: Debian 12/13/14, Ubuntu 22.04/24.04, macOS 13+)"; return 1 ;;
      esac
      log_info "host OS: ${OS_ID} ${OS_VER} (supported)"
      ;;
    Darwin)
      local pv major; pv="$(sw_vers -productVersion 2>/dev/null || echo 0)"; major="${pv%%.*}"
      if [ "${major:-0}" -lt 13 ]; then
        log_error "unsupported macOS ${pv} (need 13+)"; return 1
      fi
      OS_ID="macos"; OS_VER="$pv"
      log_info "host OS: macOS ${pv} (supported)"
      ;;
    *)
      log_error "unsupported platform: ${uname_s} (supported: Debian/Ubuntu Linux, macOS 13+)"; return 1 ;;
  esac
}

detect_arch() {
  local raw; raw="$(uname -m)"
  case "$raw" in
    arm64|aarch64) ARCH="arm64" ;;
    x86_64|amd64)  ARCH="x86_64" ;;
    *) log_error "unsupported CPU architecture: ${raw} (supported: arm64, x86_64)"; return 1 ;;
  esac
  PIN_FILE="${PROJECT_ROOT}/pins/${ARCH}.json"
  if [ -f "$PIN_FILE" ]; then
    log_info "architecture: ${ARCH} -> pin manifest pins/${ARCH}.json"
  else
    log_warn "architecture: ${ARCH} -> pins/${ARCH}.json ABSENT. Images would resolve unpinned;"
    log_warn "  re-run with the pin manifest present, or confirm dynamic pulls before production."
  fi
}

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
_require_field() {
  local key="$1" val
  val="$(json_get "$CONFIG" "$key" 2>/dev/null || true)"
  if [ -z "$val" ] || printf '%s' "$val" | grep -q '^YOUR_'; then
    log_error "config.json: required field '${key}' is missing or still a placeholder"; return 1
  fi
  log_debug "config ${key}=${val}"
  return 0
}

load_config() {
  if [ ! -f "$CONFIG" ]; then
    log_error "no config.json found."
    log_error "  Copy the template and fill it in:  cp ${EXAMPLE#"${PROJECT_ROOT}"/} config.json"
    log_error "  Then edit config.json (replace every YOUR_* placeholder) and re-run."
    return 1
  fi
  local fail=0
  _require_field domain        || fail=1
  _require_field tls_mode      || fail=1
  _require_field storage_path  || fail=1
  _require_field timezone      || fail=1
  _require_field admin_email   || fail=1

  TLS_MODE="$(json_get "$CONFIG" tls_mode 2>/dev/null || echo local)"
  case "$TLS_MODE" in
    local|domain) : ;;
    *) log_error "config.json: tls_mode must be 'local' or 'domain' (got '${TLS_MODE}')"; fail=1 ;;
  esac

  DOMAIN="$(json_get "$CONFIG" domain 2>/dev/null || echo "")"

  if ! json_array_has "$CONFIG" modules core; then
    log_error "config.json: modules[] must include \"core\" (the appliance itself)"; fail=1
  fi
  MOD_ARR=0; MOD_VPN=0
  json_array_has "$CONFIG" modules arr && MOD_ARR=1
  json_array_has "$CONFIG" modules vpn && MOD_VPN=1
  if [ "$MOD_VPN" -eq 1 ] && [ "$MOD_ARR" -eq 0 ]; then
    log_error "config.json: modules[] has 'vpn' but not 'arr'; vpn protects the arr download stack"; fail=1
  fi

  if [ "$TLS_MODE" = "domain" ]; then
    local dp dk
    dp="$(json_get "$CONFIG" dns_provider 2>/dev/null || true)"
    dk="$(json_get "$CONFIG" dns_api_key 2>/dev/null || true)"
    if [ -z "$dp" ] || printf '%s' "$dp" | grep -q '^YOUR_' \
       || [ -z "$dk" ] || printf '%s' "$dk" | grep -q '^YOUR_'; then
      log_warn "tls_mode 'domain' but dns_provider/dns_api_key not fully set in config.json;"
      log_warn "  ACME DNS-01 issuance needs them (or place the key in secrets/ per lib/cert-renew.sh)."
    fi
  fi

  [ "$fail" -eq 0 ] || { log_error "config validation FAILED"; return 1; }
  # Export for docker compose variable substitution (compose/*.yml reference
  # ${SF_BASE_DOMAIN}); also settable via a root .env for manual compose runs.
  export SF_BASE_DOMAIN="$DOMAIN"
  log_info "config valid: domain=${DOMAIN} tls_mode=${TLS_MODE} modules=[core$([ "$MOD_ARR" -eq 1 ] && printf ',arr')$([ "$MOD_VPN" -eq 1 ] && printf ',vpn')]"
}

# ---------------------------------------------------------------------------
# Compose / health helpers used by modules/*.sh
# ---------------------------------------------------------------------------
sf_compose_up() {
  local name="$1" f="${PROJECT_ROOT}/compose/${1}.yml"
  [ -f "$f" ] || { log_warn "compose file missing: compose/${name}.yml (skipping)"; return 0; }
  # --project-directory pins the anchor for every relative path in the compose
  # file to PROJECT_ROOT, so ./secrets, ./state, ./templates, compose/*.env, and
  # the build context all resolve identically regardless of where compose is run.
  run docker compose --project-directory "${PROJECT_ROOT}" -f "$f" up -d
}

sf_health() {
  local rc=0 c st
  for c in "$@"; do
    if [ "${DRY_RUN:-0}" -eq 1 ]; then log_info "  DRY-RUN would check health of ${c}"; continue; fi
    st="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$c" 2>/dev/null || echo missing)"
    case "$st" in
      healthy|running) log_info "  PASS: ${c} (${st})" ;;
      *) log_error "  FAIL: ${c} (${st})"; rc=1 ;;
    esac
  done
  return "$rc"
}

# ---------------------------------------------------------------------------
# TLS + hosts
# ---------------------------------------------------------------------------
write_hosts() {
  local hosts="/etc/hosts" sub line
  if [ "${DRY_RUN:-0}" -eq 0 ] && [ ! -w "$hosts" ]; then
    log_error "cannot write ${hosts} (need root; on macOS re-run this step with sudo)"; return 1
  fi
  [ "${DRY_RUN:-0}" -eq 0 ] && backup_file "$hosts"
  for sub in $SUBDOMAINS; do
    line="127.0.0.1 ${sub}.${DOMAIN}"
    if grep -qE "[[:space:]]${sub}\.${DOMAIN}([[:space:]]|\$)" "$hosts" 2>/dev/null; then
      log_debug "hosts entry present: ${sub}.${DOMAIN}"
    else
      run sh -c "printf '%s\n' '${line}' >> '${hosts}'"
      log_info "hosts: + ${sub}.${DOMAIN} -> 127.0.0.1"
    fi
  done
}

configure_tls() {
  case "$TLS_MODE" in
    local)
      log_info "stage tls: local mode (self-signed 'tls internal'; hosts -> 127.0.0.1)"
      write_hosts
      log_info "  Caddy serves each *.${DOMAIN} vhost with 'tls internal' (see templates/Caddyfile)."
      ;;
    domain)
      log_info "stage tls: domain mode (ACME certs for ${DOMAIN} + *.${DOMAIN})"
      log_info "  Cert issuance/renewal is handled by lib/cert-renew.sh (acme.sh DNS-01);"
      log_info "  bootstrap installs its cron job below. Public DNS resolves the subdomains."
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Crontab (idempotent; tagged per job)
# ---------------------------------------------------------------------------
install_crontab() {
  log_info "stage crontab: install/refresh the five appliance jobs (idempotent)"
  local current added=0 line name sched script logf
  current="$(crontab -l 2>/dev/null || true)"
  # name|schedule|lib-script
  local jobs="importer|* * * * *|importer-run.sh
db-backup|0 2 * * *|db-backup.sh
cert-renew|0 3 * * *|cert-renew.sh
prune|0 4 * * *|prune-run.sh
guide-refresh-boot|@reboot|guide-refresh-boot.sh"
  local newcron="$current"
  while IFS='|' read -r name sched script; do
    [ -n "$name" ] || continue
    if printf '%s\n' "$current" | grep -qF "# ${CRON_TAG}:${name}"; then
      log_debug "cron present: ${name}"
      continue
    fi
    logf="${PROJECT_ROOT}/state/cron-${name}.log"
    line="${sched} ${PROJECT_ROOT}/lib/${script} >> ${logf} 2>&1  # ${CRON_TAG}:${name}"
    newcron="${newcron}
${line}"
    added=$((added + 1))
    log_info "cron: + ${name} (${sched})"
  done <<EOF_CRON_JOBS
${jobs}
EOF_CRON_JOBS
  if [ "$added" -eq 0 ]; then
    log_info "  all five cron jobs already installed"
    return 0
  fi
  if [ "${DRY_RUN:-0}" -eq 1 ]; then
    log_info "  DRY-RUN would install ${added} cron job(s) via 'crontab -'"
    return 0
  fi
  printf '%s\n' "$newcron" | crontab -
  log_info "  installed ${added} cron job(s)"
}

# ---------------------------------------------------------------------------
# Module system
# ---------------------------------------------------------------------------
bring_up_modules() {
  log_info "stage modules: core$([ "$MOD_ARR" -eq 1 ] && printf ' + arr')$([ "$MOD_VPN" -eq 1 ] && printf ' + vpn')"
  # shellcheck source=modules/core.sh
  . "${PROJECT_ROOT}/modules/core.sh"
  core_up
  if [ "$MOD_VPN" -eq 1 ]; then
    # vpn provides qBittorrent's network namespace -> up BEFORE arr
    # shellcheck source=modules/vpn.sh
    . "${PROJECT_ROOT}/modules/vpn.sh"
    vpn_up
  fi
  if [ "$MOD_ARR" -eq 1 ]; then
    # shellcheck source=modules/arr.sh
    . "${PROJECT_ROOT}/modules/arr.sh"
    arr_up
  fi
}

# ---------------------------------------------------------------------------
# Stages
# ---------------------------------------------------------------------------
stage_preflight() {
  log_info "stage preflight: real read-only host detection"
  # shellcheck source=lib/preflight.sh
  . "${PROJECT_ROOT}/lib/preflight.sh"
  run_preflight
}

stage_verify() {
  log_info "stage verify: whole-appliance regression net (verify-only nets + service reachability)"
  local fails=0 checks=0 s script code sub
  local vdom
  vdom="$(json_get "$CONFIG" domain 2>/dev/null || json_get "$CONFIG" hosting.base_domain 2>/dev/null || echo fcuk-em-all.com)"

  # (a) build vehicles that expose a real --verify-only net (present on the dev
  #     box; absent in a clean public checkout, in which case they are skipped).
  for s in 16 17; do
    script="${PROJECT_ROOT}/${s}.sh"
    [ -f "$script" ] || continue
    checks=$((checks + 1))
    if [ "${DRY_RUN:-0}" -eq 1 ]; then log_info "  DRY-RUN would run: bash ${s}.sh --verify-only"; continue; fi
    if bash "$script" --verify-only >/dev/null 2>&1; then
      log_info "  PASS: ${s}.sh --verify-only"
    else
      log_error "  FAIL: ${s}.sh --verify-only"; fails=$((fails + 1))
    fi
  done

  # (b) BACKEND health: every fcuk-em-all-* container healthy/running, plus the
  #     can't-be-missing trio must be present.
  if [ "${DRY_RUN:-0}" -eq 1 ]; then
    log_info "  DRY-RUN would check docker health of every fcuk-em-all-* container + Caddy HTTPS"
  elif ! docker info >/dev/null 2>&1; then
    log_error "  FAIL: docker not accessible - cannot assess container health"; fails=$((fails + 1)); checks=$((checks + 1))
  else
    local names must c st waited pending
    names="$(docker ps -a --filter name=fcuk-em-all --format '{{.Names}}' 2>/dev/null)"
    # After a fresh `up`, slow starters (Immich runs DB migrations, Samba
    # initialises accounts, the wizard waits on deps) may still be inside their
    # health start_period. During a full bootstrap, poll until every fcuk-em-all
    # container is healthy/running (or ~5 min timeout) so verify does not fail a
    # not-yet-ready container. Skipped for --verify-only, which reports live state.
    if [ "${BOOT_VERIFY_ONLY:-0}" -ne 1 ] && [ -n "$names" ]; then
      waited=0
      while :; do
        pending=""
        for c in $names; do
          st="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$c" 2>/dev/null || echo missing)"
          case "$st" in healthy|running) : ;; *) pending="${pending} ${c}(${st})" ;; esac
        done
        [ -z "$pending" ] && break
        [ "$waited" -ge 300 ] && { log_warn "containers still not ready after ${waited}s:${pending}"; break; }
        log_info "  waiting for slow starters (${waited}s):${pending}"
        sleep 10; waited=$((waited + 10))
      done
    fi
    for must in fcuk-em-all-caddy fcuk-em-all-authelia fcuk-em-all-jellyfin; do
      checks=$((checks + 1))
      printf '%s\n' "$names" | grep -qx "$must" || { log_error "  FAIL: required container ${must} is MISSING"; fails=$((fails + 1)); }
    done
    for c in $names; do
      checks=$((checks + 1))
      st="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$c" 2>/dev/null || echo missing)"
      case "$st" in
        healthy|running) log_info "  PASS: ${c} (${st})" ;;
        *) log_error "  FAIL: ${c} (${st})"; fails=$((fails + 1)) ;;
      esac
    done
    # (c) EDGE: Caddy serves HTTPS + Authelia answers.
    checks=$((checks + 1))
    code="$(curl -4 -sk -m 10 --resolve "auth.${vdom}:443:127.0.0.1" -o /dev/null -w '%{http_code}' "https://auth.${vdom}/api/health" 2>/dev/null || echo 000)"
    case "$code" in
      200) log_info "  PASS: edge serves HTTPS + Authelia /api/health 200" ;;
      *) log_error "  FAIL: edge/Authelia health (HTTP ${code})"; fails=$((fails + 1)) ;;
    esac
    # (d) EDGE: subdomain gate checks (unauth -> Authelia redirect). Module-aware:
    #     read the module set straight from config.json - stage_verify can run via
    #     --verify-only, which does NOT call load_config, so MOD_ARR is unset here.
    #     Core subdomains are ALWAYS checked; the arr-stack subdomains (incl. Seerr
    #     'requests') are checked ONLY when the arr module is enabled.
    local arr_active=0
    json_array_has "$CONFIG" modules arr 2>/dev/null && arr_active=1
    local core_subs="stream jellyfin navidrome kavita audiobookshelf immich"
    local arr_subs="qbittorrent prowlarr radarr sonarr requests"
    local check_subs="$core_subs"
    if [ "$arr_active" -eq 1 ]; then
      check_subs="$core_subs $arr_subs"
    else
      log_info "  SKIP: arr-stack subdomain gate checks (arr module not enabled)"
    fi
    for sub in $check_subs; do
      checks=$((checks + 1))
      code="$(curl -4 -sk -m 10 --resolve "${sub}.${vdom}:443:127.0.0.1" -o /dev/null -w '%{http_code}' "https://${sub}.${vdom}/" 2>/dev/null || echo 000)"
      case "$code" in
        302|303) log_info "  PASS: ${sub}.${vdom} gated (HTTP ${code})" ;;
        *) log_error "  FAIL: ${sub}.${vdom} edge/gate (HTTP ${code})"; fails=$((fails + 1)) ;;
      esac
    done
  fi

  if [ "${DRY_RUN:-0}" -eq 1 ]; then log_info "stage verify: DRY-RUN (no checks executed)"; return 0; fi
  if [ "$fails" -eq 0 ]; then
    log_info "stage verify: PASS - all ${checks} checks green (appliance healthy)"; return 0
  fi
  log_error "stage verify: FAIL - ${fails}/${checks} check(s) failed"; return 1
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  log_info "================================================================"
  log_info "bootstrap starting (dry-run=${DRY_RUN}, debug=${DEBUG}, verify-only=${BOOT_VERIFY_ONLY})"
  log_info "PROJECT_ROOT=${PROJECT_ROOT}"
  log_info "================================================================"

  if [ "$BOOT_VERIFY_ONLY" -eq 1 ]; then
    local vrc=0
    stage_verify || vrc=$?
    [ "$vrc" -eq 0 ] && log_info "bootstrap --verify-only: appliance HEALTHY" || log_error "bootstrap --verify-only: appliance has FAILURES"
    return "$vrc"
  fi

  # Single-run guard (mutating path only; skipped under dry-run so it writes nothing).
  if [ "$DRY_RUN" -eq 0 ] && command -v flock >/dev/null 2>&1; then
    mkdir -p "$(dirname "$LOCKFILE")"
    exec 9>"$LOCKFILE"
    flock -n 9 || { log_error "another bootstrap run holds ${LOCKFILE}; aborting"; return 1; }
  fi

  detect_os
  load_config
  detect_arch
  stage_preflight
  configure_tls
  install_crontab
  bring_up_modules

  local vrc=0
  stage_verify || vrc=1
  log_info "bootstrap: stage sequence complete"
  if [ "$DRY_RUN" -eq 1 ]; then
    log_info "DRY-RUN complete; no changes made."
  fi
  return "$vrc"
}

main
