#!/usr/bin/env bash
# modules/core.sh - CORE module (always required): the media appliance itself.
#
# Sourceable, NEVER run directly. Provides core_up() and core_verify().
# Relies on primitives from lib/common.sh (log_*, run) and the sf_compose_up /
# sf_health helpers defined by bootstrap.sh before this file is sourced.
#
# CORE = the six user-facing media services (Jellyfin video, Navidrome music,
# Kavita books/comics, Audiobookshelf audiobooks, Immich photos) plus the gate
# (Authelia), the edge (Caddy), file sharing (Samba) and the setup wizard.
: "${PROJECT_ROOT:?modules/core.sh requires PROJECT_ROOT}"

# Compose files under compose/ that this module owns (order = bring-up order).
CORE_COMPOSE=(caddy authelia jellyfin navidrome kavita audiobookshelf immich samba wizard)

# Containers this module is responsible for (immich.yml alone brings four up).
CORE_CONTAINERS=(
  fcuk-em-all-caddy fcuk-em-all-authelia fcuk-em-all-jellyfin
  fcuk-em-all-navidrome fcuk-em-all-kavita fcuk-em-all-audiobookshelf
  fcuk-em-all-immich fcuk-em-all-immich-postgres fcuk-em-all-immich-redis
  fcuk-em-all-immich-ml fcuk-em-all-samba fcuk-em-all-wizard
)

core_up() {
  log_info "module core: bringing up media appliance (${#CORE_COMPOSE[@]} compose files)"
  local c
  for c in "${CORE_COMPOSE[@]}"; do sf_compose_up "$c"; done
}

core_verify() {
  log_info "module core: verifying ${#CORE_CONTAINERS[@]} containers"
  sf_health "${CORE_CONTAINERS[@]}"
}
