#!/usr/bin/env bash
# lib/configure.sh - FCUK-EM-ALL runtime configure helpers (sourceable).
# REAL wildcard TLS for *.<base_domain> (EC/LE cert, mounted read-only) - the
# 'tls internal' dev seam is RETIRED. Flat real hostnames derived from
# config.json hosting.base_domain. two_factor gate; routes by service name.
# Jellyfin web UI gated; its API exempt (own token auth).
: "${PROJECT_ROOT:?lib/configure.sh requires PROJECT_ROOT}"

CFG_CONFIG_JSON="${PROJECT_ROOT}/config.json"
CFG_SECRETS="${PROJECT_ROOT}/secrets"
CFG_CADDYFILE="${PROJECT_ROOT}/templates/Caddyfile.dev"
CFG_AUTHELIA_DIR="${PROJECT_ROOT}/templates/authelia"

_cfg_base_domain(){ python3 - "$CFG_CONFIG_JSON" <<'CFG_DOM_PY' 2>/dev/null || true
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    print(d.get("domain") or d["hosting"]["base_domain"])
except Exception:
    pass
CFG_DOM_PY
}

CFG_BASE_DOMAIN="${SF_BASE_DOMAIN:-$(_cfg_base_domain)}"
: "${CFG_BASE_DOMAIN:?lib/configure.sh: could not resolve 'domain' from config.json}"
CFG_APP_DOMAIN="${SF_APP_DOMAIN:-stream.${CFG_BASE_DOMAIN}}"
CFG_AUTH_DOMAIN="${SF_AUTH_DOMAIN:-auth.${CFG_BASE_DOMAIN}}"
CFG_JF_DOMAIN="${SF_JF_DOMAIN:-jellyfin.${CFG_BASE_DOMAIN}}"
CFG_WIZARD_PORT="${SF_WIZARD_PORT:-8088}"
CFG_AUTHELIA_PORT="${SF_AUTHELIA_PORT:-9091}"
CFG_JF_PORT="${SF_JF_PORT:-8096}"
SF_CADDY_APPS="${SF_CADDY_APPS:-}"
CFG_TLS_CERT="${SF_TLS_CERT:-/etc/caddy/tls/fullchain.cer}"
CFG_TLS_KEY="${SF_TLS_KEY:-/etc/caddy/tls/${CFG_BASE_DOMAIN}.key}"

render_caddyfile(){
  cat > "$CFG_CADDYFILE" <<CADDY_RENDER_EOF
# templates/Caddyfile.dev - RENDERED by lib/configure.sh. Do not hand-edit.
# REAL wildcard TLS for *.${CFG_BASE_DOMAIN} (EC/Let's Encrypt cert, mounted RO).
# 'tls internal' RETIRED. Flat real hostnames. Routes by service name.
{
	admin off
	auto_https disable_redirects
}

# Wizard - GATED (two_factor).
${CFG_APP_DOMAIN} {
	tls ${CFG_TLS_CERT} ${CFG_TLS_KEY}
	forward_auth authelia:${CFG_AUTHELIA_PORT} {
		uri /api/authz/forward-auth
		copy_headers Remote-User Remote-Groups Remote-Name Remote-Email
	}
	reverse_proxy wizard:${CFG_WIZARD_PORT}
}

# Authelia portal.
${CFG_AUTH_DOMAIN} {
	tls ${CFG_TLS_CERT} ${CFG_TLS_KEY}
	reverse_proxy authelia:${CFG_AUTHELIA_PORT}
}

# Jellyfin - GATE-SPLIT: only the web UI (/web*) forced through Authelia; the
# API surface (native clients, own token auth) is EXEMPT.
${CFG_JF_DOMAIN} {
	tls ${CFG_TLS_CERT} ${CFG_TLS_KEY}
	@webui {
		path /web /web/*
		not path /web/ConfigurationPage*
	}
	forward_auth @webui authelia:${CFG_AUTHELIA_PORT} {
		uri /api/authz/forward-auth
		copy_headers Remote-User Remote-Groups Remote-Name Remote-Email
	}
	reverse_proxy jellyfin:${CFG_JF_PORT}
}

# Immich - GATE-SPLIT: web UI gated (two_factor); the /api/* surface is EXEMPT
# so native mobile/desktop clients use Immich's OWN JWT/API-key auth (Authelia
# bypassed for /api only; Immich still 401s without a valid token).
immich.${CFG_BASE_DOMAIN} {
	tls ${CFG_TLS_CERT} ${CFG_TLS_KEY}
	@gated {
		not path /api /api/*
	}
	forward_auth @gated authelia:${CFG_AUTHELIA_PORT} {
		uri /api/authz/forward-auth
		copy_headers Remote-User Remote-Groups Remote-Name Remote-Email
	}
	reverse_proxy immich:2283
}

# Navidrome - GATE-SPLIT: web UI gated (two_factor); the Subsonic API (/rest/*)
# is EXEMPT so native Subsonic clients use Navidrome's OWN auth (salt+token /
# password; Authelia bypassed for /rest only, Subsonic still fails bad creds).
navidrome.${CFG_BASE_DOMAIN} {
	tls ${CFG_TLS_CERT} ${CFG_TLS_KEY}
	@gated {
		not path /rest /rest/*
	}
	forward_auth @gated authelia:${CFG_AUTHELIA_PORT} {
		uri /api/authz/forward-auth
		copy_headers Remote-User Remote-Groups Remote-Name Remote-Email
	}
	reverse_proxy navidrome:4533
}

# Kavita - GATE-SPLIT: web UI gated (two_factor); the OPDS feed (/api/opds/*)
# is EXEMPT so native OPDS e-readers use Kavita's OWN per-user apiKey (in the
# URL; Authelia bypassed for /api/opds ONLY - the rest of /api stays gated).
kavita.${CFG_BASE_DOMAIN} {
	tls ${CFG_TLS_CERT} ${CFG_TLS_KEY}
	@gated {
		not path /api/opds /api/opds/*
	}
	forward_auth @gated authelia:${CFG_AUTHELIA_PORT} {
		uri /api/authz/forward-auth
		copy_headers Remote-User Remote-Groups Remote-Name Remote-Email
	}
	reverse_proxy kavita:5000
}

# Audiobookshelf - GATE-SPLIT: web UI gated (two_factor); the native-app surface
# (/login auth, /api, /hls audio streaming, /socket.io realtime sync) is EXEMPT so
# mobile/desktop apps use ABS's OWN JWT auth. reverse_proxy proxies the websocket
# upgrade transparently. The web UI + its assets (everything else) stay gated.
audiobookshelf.${CFG_BASE_DOMAIN} {
	tls ${CFG_TLS_CERT} ${CFG_TLS_KEY}
	@gated {
		not path /login /api /api/* /hls /hls/* /socket.io /socket.io/*
	}
	forward_auth @gated authelia:${CFG_AUTHELIA_PORT} {
		uri /api/authz/forward-auth
		copy_headers Remote-User Remote-Groups Remote-Name Remote-Email
	}
	reverse_proxy audiobookshelf:13378
}
CADDY_RENDER_EOF

  # Media apps (DRY loop) - flat subdomains of the base domain, whole-app gated.
  local _app _name _port
  for _app in ${SF_CADDY_APPS}; do
    _name="${_app%%:*}"; _port="${_app##*:}"
    cat >> "$CFG_CADDYFILE" <<APP_ROUTE_EOF

# ${_name} - whole-app GATED (two_factor); no API exemption this pass.
${_name}.${CFG_BASE_DOMAIN} {
	tls ${CFG_TLS_CERT} ${CFG_TLS_KEY}
	forward_auth authelia:${CFG_AUTHELIA_PORT} {
		uri /api/authz/forward-auth
		copy_headers Remote-User Remote-Groups Remote-Name Remote-Email
	}
	reverse_proxy ${_name}:${_port}
}
APP_ROUTE_EOF
  done

  cat >> "$CFG_CADDYFILE" <<CADDY_TAIL_EOF

# Host-agnostic plain-HTTP liveness (keeps the Caddy healthcheck simple).
:80 {
	@ok path /health /healthz
	respond @ok "ok" 200
	respond 404
}
CADDY_TAIL_EOF
}

render_authelia_config(){
  mkdir -p "$CFG_AUTHELIA_DIR"
  cat > "${CFG_AUTHELIA_DIR}/configuration.yml" <<AUTHELIA_RENDER_EOF
# templates/authelia/configuration.yml - RENDERED by lib/configure.sh.
# Cookie domain is the BASE domain so the session carries across all flat
# subdomains (stream./auth./jellyfin./...). authelia_url over real https.
theme: light
server:
  address: 'tcp://0.0.0.0:${CFG_AUTHELIA_PORT}'
log:
  level: info
authentication_backend:
  file:
    path: /config/users_database.yml
access_control:
  default_policy: two_factor
session:
  cookies:
    - domain: '${CFG_BASE_DOMAIN}'
      authelia_url: 'https://${CFG_AUTH_DOMAIN}'
      default_redirection_url: 'https://${CFG_APP_DOMAIN}'
regulation:
  max_retries: 3
  find_time: 120
  ban_time: 300
storage:
  local:
    path: /data/db.sqlite3
notifier:
  filesystem:
    filename: /data/notification.txt
totp:
  issuer: '${CFG_BASE_DOMAIN}'
AUTHELIA_RENDER_EOF
}

render_authelia_users(){
  mkdir -p "$CFG_AUTHELIA_DIR"
  local hashfile="${CFG_SECRETS}/authelia_admin_password_hash" hash
  [ -s "$hashfile" ] || { echo "missing admin hash: $hashfile" >&2; return 1; }
  hash="$(cat "$hashfile")"
  cat > "${CFG_AUTHELIA_DIR}/users_database.yml" <<USERS_RENDER_EOF
# templates/authelia/users_database.yml - RENDERED (gitignored: carries a hash).
users:
  admin:
    disabled: false
    displayname: 'Administrator'
    password: '${hash}'
    email: 'admin@${CFG_BASE_DOMAIN}'
    groups:
      - admins
USERS_RENDER_EOF
  chmod 600 "${CFG_AUTHELIA_DIR}/users_database.yml"
}

configure_all(){
  if [ "${DRY_RUN:-0}" -eq 1 ]; then log_info "DRY-RUN would render Caddyfile + Authelia config + users_database"; return 0; fi
  render_caddyfile; render_authelia_config; render_authelia_users
  log_info "configure: rendered Caddyfile + Authelia config + users_database (real wildcard TLS, flat hostnames)"
}

_dca(){ docker compose -p fcuk-em-all-auth -f "${PROJECT_ROOT}/compose/authelia.yml" --project-directory "$PROJECT_ROOT" "$@"; }
deploy_authelia(){ if [ "${DRY_RUN:-0}" -eq 1 ]; then log_info "DRY-RUN would up authelia"; return 0; fi; log_info "configure: bringing up Authelia"; _dca up -d --remove-orphans; }
teardown_authelia(){ if [ "${DRY_RUN:-0}" -eq 1 ]; then log_info "DRY-RUN would down authelia"; return 0; fi; _dca down --remove-orphans; }
