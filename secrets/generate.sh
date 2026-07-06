#!/usr/bin/env bash
# =============================================================================
# secrets/generate.sh - generate every secret the appliance needs, on a fresh
# install. Idempotent: an existing NON-EMPTY secret file is left untouched, so
# re-running never rotates live credentials. Use --force (typed confirmation) to
# deliberately regenerate. Secret VALUES are never printed - only file names.
#
#   bash secrets/generate.sh [--dry-run] [--force] [--debug] [--help]
#
# All output files are 0600 in a 0700 directory. OIDC client hashes are argon2id
# (m=65536, t=3, p=4) produced by the pinned Authelia image itself (no extra
# Python dependency), which is exactly the format Authelia validates against.
# =============================================================================
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SELF_DIR")"
# shellcheck source=../lib/common.sh
. "${PROJECT_ROOT}/lib/common.sh"
# shellcheck disable=SC2034  # LOG_TAG is consumed by the sourced lib/common.sh logger
LOG_TAG="secrets-gen"

SECRETS="${SF_SECRETS_DIR:-${PROJECT_ROOT}/secrets}"
CONFIG="${PROJECT_ROOT}/config.json"
# Authelia image straight from the compose file => always locally present.
SF_AUTHELIA_IMAGE="${SF_AUTHELIA_IMAGE:-$(awk '/image:/{print $2; exit}' "${PROJECT_ROOT}/compose/authelia.yml" 2>/dev/null)}"
: "${SF_AUTHELIA_IMAGE:=authelia/authelia:4.39.20}"

GEN=0; SKIPPED=0

usage() {
  cat <<'GEN_USAGE'
Usage: bash secrets/generate.sh [--dry-run] [--force] [--debug] [--help]
  Generates Authelia secrets, per-app OIDC client secrets+hashes, admin
  passwords, and third-party API-key placeholders into secrets/.
  --dry-run  Narrate only; create/overwrite nothing.
  --force    Regenerate even existing secrets (requires typing REGENERATE).
  --debug    Verbose logging.
  --help     Show this help and exit.
GEN_USAGE
}

# --force is generate-specific; strip before parse_common_flags.
FORCE=0
_args=""
for a in "$@"; do
  if [ "$a" = "--force" ]; then FORCE=1; else _args="${_args} ${a}"; fi
done
# shellcheck disable=SC2086
parse_common_flags $_args

# --- random primitives (no pipefail surprises) -------------------------------
rand_hex()   { local n="$1" h; h="$(openssl rand -hex "$(( (n + 1) / 2 ))")"; printf '%s' "${h:0:n}"; }
rand_alnum() { local n="$1" s; s="$(set +o pipefail; LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$n")"; printf '%s' "$s"; }
rand_b64_32(){ openssl rand -base64 24; }   # 24 bytes -> exactly 32 base64 chars
gen_rsa()    { openssl genrsa 2048 2>/dev/null; }

argon2_hash() {   # $1 = plaintext; prints the argon2id digest (never logged)
  docker run --rm "$SF_AUTHELIA_IMAGE" authelia crypto hash generate argon2 \
    -m 65536 -i 3 -p 4 --password "$1" 2>/dev/null | sed -n 's/^Digest: //p'
}

# --- write helpers (idempotent; 0600; values never printed) ------------------
maybe_gen() {   # $1 = filename (rel to SECRETS); $2.. = generator cmd printing value
  local rel="$1"; shift
  local f="${SECRETS}/${rel}"
  if [ -s "$f" ] && [ "$FORCE" -eq 0 ]; then log_info "  skip (exists): ${rel}"; SKIPPED=$((SKIPPED + 1)); return 0; fi
  if [ "${DRY_RUN:-0}" -eq 1 ]; then log_info "  DRY-RUN would generate: ${rel}"; GEN=$((GEN + 1)); return 0; fi
  local val; val="$("$@")"
  ( umask 077; printf '%s\n' "$val" > "$f" ); chmod 600 "$f"
  log_info "  generated: ${rel}"; GEN=$((GEN + 1))
}

gen_oidc_client() {   # $1 = client name; writes secret + argon2id hash (paired)
  local c="$1" sf="${SECRETS}/authelia_oidc_secret_${1}.txt" hf="${SECRETS}/authelia_oidc_client_hash_${1}"
  if [ -s "$sf" ] && [ -s "$hf" ] && [ "$FORCE" -eq 0 ]; then
    log_info "  skip (exists): authelia_oidc_secret_${c}.txt + hash"; SKIPPED=$((SKIPPED + 2)); return 0
  fi
  if [ "${DRY_RUN:-0}" -eq 1 ]; then
    log_info "  DRY-RUN would generate: authelia_oidc_secret_${c}.txt + authelia_oidc_client_hash_${c}"; GEN=$((GEN + 2)); return 0
  fi
  local secret hash
  secret="$(rand_alnum 45)"
  hash="$(argon2_hash "$secret")"
  if [ -z "$hash" ]; then
    log_error "argon2 hashing failed for '${c}'. Need docker + the Authelia image (${SF_AUTHELIA_IMAGE%@*})."
    return 1
  fi
  ( umask 077; printf '%s\n' "$secret" > "$sf" ); chmod 600 "$sf"
  ( umask 077; printf '%s\n' "$hash"  > "$hf" ); chmod 600 "$hf"
  log_info "  generated: authelia_oidc_secret_${c}.txt + authelia_oidc_client_hash_${c}"; GEN=$((GEN + 2))
}

gen_placeholder() {   # $1 = filename; $2 = where-to-get-it note
  local rel="$1" note="$2" f="${SECRETS}/$1"
  if [ -s "$f" ] && [ "$FORCE" -eq 0 ]; then log_info "  skip (exists): ${rel}"; SKIPPED=$((SKIPPED + 1)); return 0; fi
  if [ "${DRY_RUN:-0}" -eq 1 ]; then log_info "  DRY-RUN would create placeholder: ${rel}"; GEN=$((GEN + 1)); return 0; fi
  ( umask 077; printf '# %s\n' "$note" > "$f" ); chmod 600 "$f"
  log_info "  placeholder: ${rel}"; GEN=$((GEN + 1))
}

gen_immich_env() {   # immich Postgres/Redis connection env (multi-line; DB_* MUST equal POSTGRES_*)
  local rel="immich.env" f="${SECRETS}/immich.env"
  if [ -s "$f" ] && [ "$FORCE" -eq 0 ]; then log_info "  skip (exists): ${rel}"; SKIPPED=$((SKIPPED + 1)); return 0; fi
  if [ "${DRY_RUN:-0}" -eq 1 ]; then log_info "  DRY-RUN would generate: ${rel}"; GEN=$((GEN + 1)); return 0; fi
  local pw; pw="$(rand_hex 32)"   # one password shared by DB_PASSWORD and POSTGRES_PASSWORD
  ( umask 077; cat > "$f" <<IMMICH_ENV_EOF
# secrets/immich.env - gitignored. Generated once. Never printed.
DB_HOSTNAME=immich-postgres
DB_USERNAME=immich
DB_PASSWORD=${pw}
DB_DATABASE_NAME=immich
POSTGRES_USER=immich
POSTGRES_PASSWORD=${pw}
POSTGRES_DB=immich
REDIS_HOSTNAME=immich-redis
IMMICH_MACHINE_LEARNING_URL=http://immich-machine-learning:3003
IMMICH_ENV_EOF
  )
  chmod 600 "$f"
  log_info "  generated: ${rel}"; GEN=$((GEN + 1))
}

gen_smb_env() {   # samba single-account env: ACCOUNT_<user> + UID_<user> (uid 1100 = media)
  local rel="smb.env" f="${SECRETS}/smb.env"
  if [ -s "$f" ] && [ "$FORCE" -eq 0 ]; then log_info "  skip (exists): ${rel}"; SKIPPED=$((SKIPPED + 1)); return 0; fi
  if [ "${DRY_RUN:-0}" -eq 1 ]; then log_info "  DRY-RUN would generate: ${rel}"; GEN=$((GEN + 1)); return 0; fi
  local smb_user smb_pw
  # `|| true`: on a fresh install .env is written AFTER generate.sh runs, so it
  # may not exist yet. awk on a missing file exits non-zero, which under
  # `set -euo pipefail` would abort before the ${smb_user:-media} default below.
  smb_user="$(awk -F= '/^SMB_USER=/{print $2; exit}' "${PROJECT_ROOT}/.env" 2>/dev/null || true)"
  smb_user="${smb_user:-media}"
  smb_pw="$(rand_alnum 36)"
  ( umask 077; cat > "$f" <<SMB_ENV_EOF
# secrets/smb.env - gitignored. Generated once. Never printed.
ACCOUNT_${smb_user}=${smb_pw}
UID_${smb_user}=1100
SMB_ENV_EOF
  )
  chmod 600 "$f"
  log_info "  generated: ${rel} (account ${smb_user})"; GEN=$((GEN + 1))
}

check_nordvpn() {
  json_array_has "$CONFIG" modules vpn 2>/dev/null || { log_debug "vpn module not enabled; skipping NordVPN check"; return 0; }
  local tf="${SECRETS}/nordvpn_token.txt"
  if [ -s "$tf" ]; then log_info "  NordVPN token present (vpn module)"; return 0; fi
  log_error "vpn module is enabled but secrets/nordvpn_token.txt is missing/empty."
  log_error "  Get a token: NordVPN dashboard -> Services -> NordVPN -> 'Set up NordVPN manually' -> generate an access token."
  log_error "  Save it:  printf '%s' '<YOUR_TOKEN>' > secrets/nordvpn_token.txt && chmod 600 secrets/nordvpn_token.txt"
  return 1
}

main() {
  log_info "================================================================"
  log_info "secrets/generate.sh (dry-run=${DRY_RUN}, force=${FORCE})"
  log_info "target: ${SECRETS}"
  log_info "================================================================"

  if [ "$FORCE" -eq 1 ] && [ "${DRY_RUN:-0}" -eq 0 ]; then
    log_warn "--force OVERWRITES existing secrets; the running appliance can break until reconfigured."
    printf 'Type REGENERATE to proceed: '
    IFS= read -r ans || ans=""
    [ "$ans" = "REGENERATE" ] || { log_error "confirmation failed; aborting (nothing changed)"; exit 1; }
  fi

  if [ "${DRY_RUN:-0}" -eq 0 ]; then mkdir -p "$SECRETS"; chmod 700 "$SECRETS"; fi

  log_info "Authelia core secrets:"
  maybe_gen authelia_jwt_secret               rand_hex 64
  maybe_gen authelia_session_secret           rand_hex 64
  maybe_gen authelia_storage_encryption_key   rand_hex 64
  maybe_gen authelia_oidc_hmac_secret         rand_hex 73
  maybe_gen authelia_oidc_private_key.pem     gen_rsa

  log_info "Per-app OIDC client secrets + argon2id hashes:"
  local c
  for c in jellyfin navidrome kavita audiobookshelf immich jellyseerr; do
    gen_oidc_client "$c"
  done

  log_info "App admin passwords:"
  local app
  for app in jellyfin navidrome kavita audiobookshelf immich; do
    maybe_gen "${app}_admin_password.txt" rand_b64_32
  done
  maybe_gen qbittorrent_password.txt rand_b64_32

  log_info "App service env files (immich DB creds, samba account):"
  gen_immich_env
  gen_smb_env

  log_info "Third-party API-key placeholders (fill in your own; see docs/api-keys.md):"
  gen_placeholder tmdb_api_key.txt            "TMDB API key - free at https://www.themoviedb.org/settings/api (replace this line with the key)"
  gen_placeholder acoustid_api_key.txt        "AcoustID API key - free at https://acoustid.org/api-key (replace this line)"
  gen_placeholder opensubtitles_api_key.txt   "OpenSubtitles API key - https://www.opensubtitles.com/consumers (replace this line)"
  gen_placeholder opensubtitles_username.txt  "OpenSubtitles account username (replace this line)"
  gen_placeholder opensubtitles_password.txt  "OpenSubtitles account password (replace this line)"
  gen_placeholder europeana_api_key.txt       "Europeana API key - free at https://pro.europeana.eu/pages/get-api-key (replace this line)"

  log_info "NordVPN:"
  check_nordvpn

  log_info "----------------------------------------------------------------"
  if [ "${DRY_RUN:-0}" -eq 1 ]; then
    log_info "DRY-RUN complete: would generate ${GEN}, would skip ${SKIPPED}. Nothing written."
  else
    log_info "done: generated ${GEN}, skipped ${SKIPPED} (all files 0600)."
  fi
}

main
