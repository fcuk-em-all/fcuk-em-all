#!/usr/bin/env bash
# modules/arr.sh - ARR module (optional): the request + download stack.
#
# Sourceable, NEVER run directly. Provides arr_up() and arr_verify().
# Relies on primitives from lib/common.sh (log_*, run) and sf_compose_up /
# sf_health from bootstrap.sh.
#
# ARR = Jellyseerr (requests) -> Radarr/Sonarr (management) -> Prowlarr (indexer
# aggregation) -> qBittorrent (download) with FlareSolverr for Cloudflare-gated
# indexers. Enable only if 'arr' is in config.json modules[]. Downloading
# copyrighted material without permission is illegal in most jurisdictions; the
# operator is responsible for what they fetch.
: "${PROJECT_ROOT:?modules/arr.sh requires PROJECT_ROOT}"

ARR_COMPOSE=(prowlarr radarr sonarr jellyseerr qbittorrent flaresolverr)

ARR_CONTAINERS=(
  fcuk-em-all-prowlarr fcuk-em-all-radarr fcuk-em-all-sonarr
  fcuk-em-all-jellyseerr fcuk-em-all-qbittorrent fcuk-em-all-flaresolverr
)

arr_up() {
  log_info "module arr: bringing up request/download stack (${#ARR_COMPOSE[@]} compose files)"
  local c
  for c in "${ARR_COMPOSE[@]}"; do sf_compose_up "$c"; done
}

arr_verify() {
  log_info "module arr: verifying ${#ARR_CONTAINERS[@]} containers"
  sf_health "${ARR_CONTAINERS[@]}"
}
