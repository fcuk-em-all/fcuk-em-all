#!/usr/bin/env bash
# lib/deploy.sh - FCUK-EM-ALL runtime deploy helpers (sourceable).
# Shared external network + digest-pinned stacks. Distinct project names so
# --remove-orphans never sweeps a sibling stack.
: "${PROJECT_ROOT:?lib/deploy.sh requires PROJECT_ROOT}"
SF_NETWORK="${SF_NETWORK:-fcuk-em-all}"
_dc(){ docker compose -p fcuk-em-all-edge -f "${PROJECT_ROOT}/compose/caddy.yml" --project-directory "$PROJECT_ROOT" "$@"; }
_dj(){ docker compose -p fcuk-em-all-jellyfin -f "${PROJECT_ROOT}/compose/jellyfin.yml" --project-directory "$PROJECT_ROOT" "$@"; }
_dw(){ docker compose -p fcuk-em-all-wizard -f "${PROJECT_ROOT}/compose/wizard.yml" --project-directory "$PROJECT_ROOT" "$@"; }
SF_DEPLOY_APPS="${SF_DEPLOY_APPS:-navidrome kavita audiobookshelf}"
_dapp(){ local _a="$1"; shift; docker compose -p "fcuk-em-all-${_a}" -f "${PROJECT_ROOT}/compose/${_a}.yml" --project-directory "$PROJECT_ROOT" "$@"; }

ensure_network(){
  if docker network inspect "$SF_NETWORK" >/dev/null 2>&1; then log_info "network ${SF_NETWORK} exists"
  elif [ "${DRY_RUN:-0}" -eq 1 ]; then log_info "DRY-RUN would create external network ${SF_NETWORK}"
  else docker network create "$SF_NETWORK" >/dev/null && log_info "created external network ${SF_NETWORK}"; fi
}
deploy_caddy(){ if [ "${DRY_RUN:-0}" -eq 1 ]; then log_info "DRY-RUN would up caddy"; return 0; fi; log_info "deploy: Caddy (edge)"; _dc up -d --remove-orphans; }
teardown_caddy(){ if [ "${DRY_RUN:-0}" -eq 1 ]; then log_info "DRY-RUN would down caddy"; return 0; fi; _dc down --remove-orphans; }
deploy_jellyfin(){ if [ "${DRY_RUN:-0}" -eq 1 ]; then log_info "DRY-RUN would up jellyfin"; return 0; fi; log_info "deploy: Jellyfin (digest-pinned, CPU-only)"; _dj up -d --remove-orphans; }
teardown_jellyfin(){ if [ "${DRY_RUN:-0}" -eq 1 ]; then log_info "DRY-RUN would down jellyfin"; return 0; fi; _dj down --remove-orphans; }
deploy_wizard(){ if [ "${DRY_RUN:-0}" -eq 1 ]; then log_info "DRY-RUN would build+up wizard"; return 0; fi; log_info "deploy: Wizard (containerized, built locally)"; DOCKER_BUILDKIT=1 docker build -t fcuk-em-all/wizard:local "${PROJECT_ROOT}/wizard"; _dw up -d --remove-orphans; }
teardown_wizard(){ if [ "${DRY_RUN:-0}" -eq 1 ]; then log_info "DRY-RUN would down wizard"; return 0; fi; _dw down --remove-orphans; }
deploy_media_apps(){ if [ "${DRY_RUN:-0}" -eq 1 ]; then log_info "DRY-RUN would up media apps: ${SF_DEPLOY_APPS}"; return 0; fi; local a; for a in ${SF_DEPLOY_APPS}; do log_info "deploy: ${a} (digest-pinned)"; _dapp "$a" up -d --remove-orphans; done; }
teardown_media_apps(){ local a; for a in ${SF_DEPLOY_APPS}; do _dapp "$a" down --remove-orphans; done; }

# --- Immich: the heavy, conditional, multi-container app ---------------------
_di(){ docker compose -p fcuk-em-all-immich -f "${PROJECT_ROOT}/compose/immich.yml" --project-directory "$PROJECT_ROOT" "$@"; }
# The RAM gate, for real: deploy Immich ONLY if config enables it AND the
# preflight 'immich' verdict is ok. Both sources are env-overridable for testing.
immich_should_deploy(){
  local cfg="${FCUK_EM_ALL_CONFIG:-${PROJECT_ROOT}/config.json}"
  local pf="${FCUK_EM_ALL_PREFLIGHT:-${PROJECT_ROOT}/state/preflight.json}"
  local enabled verdict
  enabled="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["stack"].get("immich",False))' "$cfg" 2>/dev/null || echo False)"
  if [ "$enabled" != "True" ] && [ "$enabled" != "true" ]; then
    log_info "immich: disabled in config (stack.immich=${enabled}) - NOT deploying"; return 1
  fi
  verdict="$(python3 -c 'import json,sys
d=json.load(open(sys.argv[1])); print(next((v["status"] for v in d["verdicts"] if v["id"]=="immich"),"missing"))' "$pf" 2>/dev/null || echo missing)"
  if [ "$verdict" != "ok" ]; then
    log_info "immich: preflight RAM gate verdict='${verdict}' (gated/not ok) - SKIP deploy"; return 1
  fi
  log_info "immich: enabled in config + preflight verdict ok - deploying"; return 0
}
deploy_immich(){
  if [ "${DRY_RUN:-0}" -eq 1 ]; then log_info "DRY-RUN would gate-check then up immich (4 services)"; return 0; fi
  if immich_should_deploy; then _di up -d --remove-orphans; fi
}
# Immich teardown preserves data (down, NOT -v). Pass -v explicitly to wipe.
teardown_immich(){ if [ "${DRY_RUN:-0}" -eq 1 ]; then log_info "DRY-RUN would down immich (keep data)"; return 0; fi; _di down --remove-orphans; }
