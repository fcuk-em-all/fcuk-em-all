#!/usr/bin/env bash
# =============================================================================
# lib/cert-renew.sh - daily wildcard-TLS renewal check (cron wrapper).
#
# In tls_mode "domain", the wildcard *.${DOMAIN} cert (Let's Encrypt via acme.sh
# DNS-01) is renewed by acme.sh ~30 days before expiry and, when wired with
# --reloadcmd lib/cert-deploy-hook.sh, re-installed + Caddy restarted automatically.
#
# One-time setup on the host that runs acme.sh (only needed for tls_mode domain):
#   1. install acme.sh                         curl https://get.acme.sh | sh
#   2. provide the DNS API creds and issue:
#        acme.sh --issue --dns <dns_provider> -d "${DOMAIN}" -d "*.${DOMAIN}"
#      (DNS provider + key come from config.json dns_provider/dns_api_key or secrets/)
#   3. wire the deploy hook:
#        acme.sh --install-cert -d "${DOMAIN}" --ecc \
#          --fullchain-file <PROOT>/secrets/tls/fullchain.cer \
#          --key-file       <PROOT>/secrets/tls/${DOMAIN}.key \
#          --reloadcmd      <PROOT>/lib/cert-deploy-hook.sh
#   4. acme.sh --install-cronjob   (or rely on this wrapper's daily --cron call)
# In tls_mode "local" there is nothing to renew (self-signed 'tls internal').
# =============================================================================
set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"
PROOT="$(cd -- "$(dirname -- "$0")/.." >/dev/null 2>&1 && pwd -P)"
LOG="${PROOT}/state/cron-cert-renew.log"
DOMAIN="$(python3 - "${PROOT}/config.json" <<'CR_PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    print(d.get("domain") or d["hosting"]["base_domain"])
except Exception:
    print("")
CR_PY
)"
[ -n "$DOMAIN" ] || DOMAIN="localhost"
mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
log(){ printf '[%s] [cert-renew] %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG"; }

# days until the current cert expires (informational; never prints key material)
expiry_days(){
  docker run --rm -v "${PROOT}/secrets:/s:ro" alpine/openssl:latest \
    x509 -enddate -noout -in /s/tls/fullchain.cer 2>/dev/null \
    | sed 's/notAfter=//' || true
}

ACME="${HOME:-/root}/.acme.sh/acme.sh"
if [ -x "$ACME" ] || command -v acme.sh >/dev/null 2>&1; then
  bin="$([ -x "$ACME" ] && echo "$ACME" || command -v acme.sh)"
  log "acme.sh present; running --cron for ${DOMAIN} (renews when due; fires the wired deploy hook)"
  "$bin" --cron --home "$(dirname "$bin")" >>"$LOG" 2>&1 && log "acme.sh --cron completed" || log "acme.sh --cron returned non-zero (see log)"
else
  end="$(expiry_days)"
  log "WARNING: acme.sh NOT installed on this host - automated renewal is NOT active."
  log "         Current cert notAfter=${end:-unknown}. Renewal needs the one-time setup in this script's header (install acme.sh + DNS creds for ${DOMAIN} + wire ${PROOT}/lib/cert-deploy-hook.sh)."
fi
exit 0
