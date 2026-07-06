#!/bin/sh
# =============================================================================
# lib/cert-deploy-hook.sh - acme.sh deploy/reload hook for the wildcard TLS cert.
#
# WIRE IT (one-time, on whatever host runs acme.sh - see cert-renew.sh notes):
#   acme.sh --install-cert -d "<domain>" --ecc \
#     --fullchain-file <PROOT>/secrets/tls/fullchain.cer \
#     --key-file       <PROOT>/secrets/tls/<domain>.key \
#     --reloadcmd      <PROOT>/lib/cert-deploy-hook.sh
#
# acme.sh re-runs the install (copy + reloadcmd) automatically on every renewal
# and exports CERT_FULLCHAIN_PATH / CERT_KEY_PATH / CA_CERT_PATH pointing at its
# freshly-renewed storage copies. This hook (idempotent, safe) copies them into
# secrets/tls/ - backing up first, preserving the key's 0600 - and RESTARTS Caddy
# (admin off => no live reload). It REFUSES to overwrite the live cert with a
# missing / empty / non-PEM source, so a botched renewal can't break TLS.
#
# POSIX sh on purpose: runs as root wherever acme.sh runs. Reads no secrets to
# stdout. The domain is read from config.json (falls back to the nested schema).
# =============================================================================
set -eu

PROOT="$(cd -- "$(dirname -- "$0")/.." >/dev/null 2>&1 && pwd -P)"
DOMAIN="$(python3 - "${PROOT}/config.json" <<'CDH_PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    print(d.get("domain") or d["hosting"]["base_domain"])
except Exception:
    print("")
CDH_PY
)"
[ -n "$DOMAIN" ] || { printf 'ERROR: cannot resolve domain from config.json\n' >&2; exit 1; }

TLS="${PROOT}/secrets/tls"
LOG="${PROOT}/state/cron-cert-deploy-hook.log"
CADDY_PROJECT="fcuk-em-all-edge"
CADDY_COMPOSE="${PROOT}/compose/caddy.yml"
CADDY_CONTAINER="fcuk-em-all-caddy"

mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
log(){ printf '[%s] [cert-deploy-hook] %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG"; }

# Source paths: acme.sh exports these on a reloadcmd run; fall back to acme.sh's
# default ECC storage if invoked outside acme.sh.
ACME_HOME="${HOME:-/root}/.acme.sh"
SRC_FC="${CERT_FULLCHAIN_PATH:-${ACME_HOME}/${DOMAIN}_ecc/fullchain.cer}"
SRC_KEY="${CERT_KEY_PATH:-${ACME_HOME}/${DOMAIN}_ecc/${DOMAIN}.key}"
SRC_CA="${CA_CERT_PATH:-${ACME_HOME}/${DOMAIN}_ecc/ca.cer}"

# --- validate the source BEFORE touching the live cert -----------------------
for f in "$SRC_FC" "$SRC_KEY"; do
  if [ ! -s "$f" ]; then
    log "ERROR: renewed source missing or empty: $f - REFUSING (live cert untouched)"
    exit 1
  fi
done
if ! grep -q "BEGIN CERTIFICATE" "$SRC_FC"; then
  log "ERROR: $SRC_FC is not a PEM certificate - REFUSING (live cert untouched)"
  exit 1
fi
if ! grep -qE "BEGIN (EC |RSA )?PRIVATE KEY" "$SRC_KEY"; then
  log "ERROR: $SRC_KEY is not a PEM private key - REFUSING (live cert untouched)"
  exit 1
fi

# --- back up the current cert ------------------------------------------------
ts="$(date +%Y%m%d_%H%M%S)"
bk="${PROOT}/backups/${ts}/secrets/tls"
mkdir -p "$bk"
[ -f "${TLS}/fullchain.cer" ] && cp -p "${TLS}/fullchain.cer" "$bk/" 2>/dev/null || true
[ -f "${TLS}/${DOMAIN}.key" ] && cp -p "${TLS}/${DOMAIN}.key" "$bk/" 2>/dev/null || true
log "backed up current cert to backups/${ts}/secrets/tls"

# --- install the renewed cert (key 0600; certs 0644 - the existing pattern) ---
install -m 0644 "$SRC_FC" "${TLS}/fullchain.cer"
install -m 0644 "$SRC_FC" "${TLS}/${DOMAIN}.cer"
[ -s "$SRC_CA" ] && install -m 0644 "$SRC_CA" "${TLS}/ca.cer" || true
install -m 0600 "$SRC_KEY" "${TLS}/${DOMAIN}.key"
log "installed renewed cert into ${TLS} (key 0600)"

# --- reload Caddy (admin off => restart the container) -----------------------
if docker compose -p "$CADDY_PROJECT" -f "$CADDY_COMPOSE" --project-directory "$PROOT" restart >/dev/null 2>&1; then
  log "Caddy restarted via compose; now serving the renewed cert"
elif docker restart "$CADDY_CONTAINER" >/dev/null 2>&1; then
  log "Caddy restarted via docker restart; now serving the renewed cert"
else
  log "ERROR: cert installed but Caddy restart FAILED - restart ${CADDY_CONTAINER} manually"
  exit 1
fi
exit 0
