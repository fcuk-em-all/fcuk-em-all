#!/usr/bin/env bash
# modules/vpn.sh - VPN module (optional): route the download stack through NordVPN.
#
# Sourceable, NEVER run directly. Provides vpn_up() and vpn_verify().
# Relies on primitives from lib/common.sh (log_*, run) and sf_compose_up /
# sf_health from bootstrap.sh.
#
# VPN = a Gluetun container holding a WireGuard tunnel to NordVPN. qBittorrent
# joins Gluetun's network namespace (network_mode: service:gluetun in
# compose/qbittorrent.yml), so no download traffic leaves the host outside the
# tunnel. REQUIRES the 'arr' module and a NordVPN token (config.json
# nordvpn_token or secrets/nordvpn_token.txt). Gluetun must be up BEFORE
# qBittorrent, so bootstrap enables vpn ahead of arr.
: "${PROJECT_ROOT:?modules/vpn.sh requires PROJECT_ROOT}"

VPN_COMPOSE=(gluetun)
VPN_CONTAINERS=(fcuk-em-all-gluetun)

vpn_up() {
  log_info "module vpn: bringing up NordVPN tunnel (Gluetun)"
  local c
  for c in "${VPN_COMPOSE[@]}"; do sf_compose_up "$c"; done
}

vpn_verify() {
  log_info "module vpn: verifying ${#VPN_CONTAINERS[@]} container(s)"
  sf_health "${VPN_CONTAINERS[@]}"
}
