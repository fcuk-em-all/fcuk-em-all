#!/usr/bin/env bash
# =============================================================================
# install.sh - FCUK-EM-ALL one-shot installer for a ZERO-STATE host.
#
#   curl -4 -fsSL https://install.fcuk-em-all.com/install.sh | sudo bash
#
# Turns a fresh Debian/Ubuntu box into a running media appliance: system checks,
# Docker, release download, users + directories, secrets, runtime config, images,
# bootstrap, and client-side instructions. It is SELF-CONTAINED - the only inputs
# are the OS package repos, Docker's apt repo, and the pinned GitHub release.
#
# NOTE ON PROVISIONING (see the block below step 10): bootstrap.sh and
# secrets/generate.sh assume a tree that the numbered build scripts already
# populated on the dev VM. On a clean box that tree does not exist, so this
# installer renders/creates what they omit: the external network, the local-mode
# Caddyfile (tls internal), the Authelia config + users_database, and the wizard
# env file. (immich.env + smb.env are produced by secrets/generate.sh; the
# installer only verifies they exist.) The remaining renders belong
# architecturally in a configure stage; doing them here keeps a clean box
# bootable today. See the release notes / .cc-state.md for the follow-up.
# =============================================================================
set -euo pipefail

# --- fixed facts -------------------------------------------------------------
BRAND="FCUK-EM-ALL"
DOMAIN="fcuk-em-all.com"
INSTALL_DIR="/opt/fcuk-em-all"
MEDIA_ROOT="/srv/media"
MEDIA_UID=1100
MEDIA_USER="media"
RELEASE_TAG="v0.1.1"
RELEASE_URL="https://install.fcuk-em-all.com/fcuk-em-all.tar.gz"
CA_HTTP_PORT=8080
CA_SERVE_SECONDS=600

# Every user-facing subdomain the CORE stack serves (the client hosts-file block
# and the local Caddyfile both derive from this list).
CORE_SUBDOMAINS="stream auth jellyfin navidrome kavita audiobookshelf immich requests"

PROOT=""       # set in step 3 (== INSTALL_DIR)
VM_IP=""       # set in step 6
TIMEZONE=""    # set in step 6

# --- minimal, self-contained logging (no external lib) -----------------------
_c()   { printf '%s\n' "$*"; }
info() { printf '  \033[0;36m[*]\033[0m %s\n' "$*"; }
ok()   { printf '  \033[0;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '  \033[0;33m[!]\033[0m %s\n' "$*" >&2; }
err()  { printf '  \033[0;31m[x]\033[0m %s\n' "$*" >&2; }
die()  { err "$*"; err "installation aborted; no partial appliance was started."; exit 1; }
step() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }

banner() {
  _c ""
  _c "==================================================================="
  _c "  ${BRAND} - OWN YOUR MEDIA - installer"
  _c "==================================================================="
  _c ""
  _c "  This will install the appliance to: ${INSTALL_DIR}"
  _c "  Media library root:                 ${MEDIA_ROOT}"
  _c "  Release:                            ${RELEASE_TAG}"
  _c ""
  _c "  It will (only if needed): install Docker, create the '${MEDIA_USER}'"
  _c "  system user, apply host firewall rules, write /etc/hosts entries,"
  _c "  build two local images, and start ~14 containers."
  _c ""
}

# --- root / sudo requirement -------------------------------------------------
require_root() {
  if [ "$(id -u)" -eq 0 ]; then
    SUDO=""
    return 0
  fi
  if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    SUDO="sudo"
    warn "running as non-root; using passwordless sudo for privileged steps."
    return 0
  fi
  die "this installer must run as root (or via passwordless sudo). Re-run with: sudo bash install.sh"
}

# =============================================================================
# STEP 1 - System checks (all must pass before ANY change)
# =============================================================================
check_system() {
  step "Step 1/14 - System checks"

  # -- OS --
  [ -r /etc/os-release ] || die "cannot read /etc/os-release; unsupported system."
  # shellcheck disable=SC1091
  . /etc/os-release
  local osid="${ID:-unknown}" osver="${VERSION_ID:-}"
  # Debian testing/unstable (and pre-release trixie) ship /etc/os-release WITHOUT
  # VERSION_ID, which left osver empty -> "debian:unknown" -> false "unsupported"
  # failure. Derive the major version from the codename (then /etc/debian_version).
  if [ -z "$osver" ] && [ "$osid" = "debian" ]; then
    case "${VERSION_CODENAME:-}" in
      forky)    osver="14" ;;
      trixie)   osver="13" ;;
      bookworm) osver="12" ;;
      bullseye) osver="11" ;;
      *)
        if [ -r /etc/debian_version ]; then
          case "$(cat /etc/debian_version)" in
            14*|forky*)    osver="14" ;;
            13*|trixie*)   osver="13" ;;
            12*|bookworm*) osver="12" ;;
          esac
        fi ;;
    esac
  fi
  : "${osver:=unknown}"
  case "${osid}:${osver}" in
    debian:12|debian:13|debian:14|ubuntu:22.04|ubuntu:24.04)
      ok "OS: ${osid} ${osver} (supported)" ;;
    *)
      die "unsupported OS: ${osid} ${osver}. Supported: Debian 12/13/14, Ubuntu 22.04/24.04." ;;
  esac

  # -- arch --
  local raw; raw="$(uname -m)"
  case "$raw" in
    arm64|aarch64) ok "architecture: ${raw} (arm64)" ;;
    x86_64|amd64)  ok "architecture: ${raw} (x86_64)" ;;
    *) die "unsupported CPU architecture: ${raw}. Supported: arm64, x86_64." ;;
  esac

  # -- RAM (kB in /proc/meminfo) --
  local mem_kb mem_mb
  mem_kb="$(awk '/^MemTotal:/{print $2; exit}' /proc/meminfo 2>/dev/null || echo 0)"
  mem_mb=$(( mem_kb / 1024 ))
  if [ "$mem_mb" -lt 4096 ]; then
    die "insufficient RAM: ${mem_mb} MB (need >= 4 GB; 8 GB+ recommended)."
  elif [ "$mem_mb" -lt 8192 ]; then
    warn "RAM: ${mem_mb} MB - below the recommended 8 GB. Immich (photos) may be tight; continuing."
  else
    ok "RAM: ${mem_mb} MB"
  fi

  # -- disk: check free space on the filesystem that will actually hold Docker's
  #    data (images/volumes/overlay2), which is not necessarily /. If Docker is
  #    already installed, ask it for its data root; otherwise use the default
  #    /var/lib/docker (falling back to /var/lib if that path does not exist yet). --
  local disk_df disk_kb disk_gb disk_mount docker_root
  if docker info >/dev/null 2>&1; then
    docker_root="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null)"
    disk_df="$(df -Pk "${docker_root:-/var/lib/docker}" 2>/dev/null || df -Pk /var/lib 2>/dev/null)"
  else
    disk_df="$(df -Pk /var/lib/docker 2>/dev/null || df -Pk /var/lib 2>/dev/null)"
  fi
  disk_kb="$(printf '%s\n' "$disk_df" | awk 'NR==2{print $4; exit}')"
  disk_mount="$(printf '%s\n' "$disk_df" | awk 'NR==2{print $6; exit}')"
  disk_gb=$(( disk_kb / 1024 / 1024 ))
  if [ "$disk_gb" -lt 20 ]; then
    die "insufficient free disk on ${disk_mount} (Docker data root): ${disk_gb} GB (need >= 20 GB; 100 GB+ recommended)."
  elif [ "$disk_gb" -lt 100 ]; then
    warn "free disk on ${disk_mount} (Docker data root): ${disk_gb} GB - below the recommended 100 GB; continuing."
  else
    ok "free disk on ${disk_mount} (Docker data root): ${disk_gb} GB"
  fi

  # -- port conflicts (80/443) --
  local p listeners
  for p in 80 443; do
    listeners="$(ss -H -ltnp "( sport = :${p} )" 2>/dev/null || true)"
    if [ -n "$listeners" ]; then
      err "port ${p} is already in use:"
      printf '      %s\n' "$listeners" >&2
      die "free port ${p} before installing (the appliance edge needs 80 and 443)."
    fi
  done
  ok "ports 80 and 443 are free"

  # -- existing install --
  if [ -e "$INSTALL_DIR" ]; then
    die "existing installation found at ${INSTALL_DIR}. Reinstall/upgrade handling is a future episode; remove it manually to proceed."
  fi
  ok "no existing installation at ${INSTALL_DIR}"
}

# =============================================================================
# STEP 2 - Install Docker (official apt repo) if not already present
# =============================================================================
install_docker() {
  step "Step 2/14 - Docker"
  if docker version >/dev/null 2>&1; then
    ok "Docker already installed and working - skipping install"
    return 0
  fi

  info "installing Docker CE from Docker's official apt repository..."
  # shellcheck disable=SC1091
  . /etc/os-release
  local codename="${VERSION_CODENAME:-}"
  [ -n "$codename" ] || die "cannot determine distro codename for the Docker apt repo."

  export DEBIAN_FRONTEND=noninteractive
  # Idempotency: a previous failed run may have left a docker.list pointing at a
  # codename with no Release file (e.g. forky). Remove it BEFORE this first index
  # refresh, otherwise that stale broken entry 404s and (under set -e) aborts the
  # whole run before the fallback below can fix it. The correct repo is (re)written
  # further down, with the bookworm fallback.
  $SUDO rm -f /etc/apt/sources.list.d/docker.list
  $SUDO apt-get update -y
  $SUDO apt-get install -y ca-certificates curl gnupg

  $SUDO install -m 0755 -d /etc/apt/keyrings
  $SUDO rm -f /etc/apt/keyrings/docker.gpg
  curl -4 -fsSL "https://download.docker.com/linux/${ID}/gpg" \
    | $SUDO gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  $SUDO chmod a+r /etc/apt/keyrings/docker.gpg

  local arch; arch="$(dpkg --print-architecture)"
  local docker_codename="$codename"
  printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/%s %s stable\n' \
    "$arch" "$ID" "$docker_codename" | $SUDO tee /etc/apt/sources.list.d/docker.list >/dev/null

  # Docker publishes a per-codename repo; a brand-new/testing Debian codename
  # (e.g. forky, or trixie before Docker added it) has no Release file yet, so the
  # docker source 404s and apt-get update fails. Detect that specific failure,
  # then re-point the repo at bookworm (the newest stable Debian codename Docker
  # ships a repo for) and continue. Other update failures are left to surface.
  local aptout
  aptout="$($SUDO apt-get update -y 2>&1)" || true
  printf '%s\n' "$aptout"
  if printf '%s\n' "$aptout" | grep -qE "download\.docker\.com.*does not have a Release file"; then
    warn "Docker's apt repository has no release for Debian '${docker_codename}' yet; falling back to 'bookworm' as the compatibility target."
    docker_codename="bookworm"
    printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/%s %s stable\n' \
      "$arch" "$ID" "$docker_codename" | $SUDO tee /etc/apt/sources.list.d/docker.list >/dev/null
    $SUDO apt-get update -y
  fi

  $SUDO apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

  $SUDO systemctl enable --now docker

  docker version >/dev/null 2>&1 || die "Docker installed but 'docker version' still fails - check 'systemctl status docker'."
  ok "Docker installed and running"
}

# =============================================================================
# STEP 3 - Download + extract the release
# =============================================================================
download_release() {
  step "Step 3/14 - Download release ${RELEASE_TAG}"
  local tgz; tgz="$(mktemp /tmp/fcuk-em-all.XXXXXX.tar.gz)"
  info "fetching ${RELEASE_URL}"
  curl -4 -fsSL -o "$tgz" "$RELEASE_URL" \
    || die "download failed. Confirm ${RELEASE_URL} is reachable from this host."
  $SUDO mkdir -p "$INSTALL_DIR"
  # Tarball top-level is fcuk-em-all-<ver>/; strip it so files land at INSTALL_DIR root.
  $SUDO tar -xzf "$tgz" --strip-components=1 -C "$INSTALL_DIR" \
    || die "extraction failed (corrupt download?)."
  rm -f "$tgz"
  PROOT="$INSTALL_DIR"
  [ -f "${PROOT}/bootstrap.sh" ] || die "extracted tree is missing bootstrap.sh - unexpected release layout."
  ok "release extracted to ${PROOT}"
}

# =============================================================================
# STEP 4 - System user + media directories
# =============================================================================
create_user_dirs() {
  step "Step 4/14 - System user + media directories"
  if getent passwd "$MEDIA_UID" >/dev/null 2>&1; then
    ok "uid ${MEDIA_UID} already exists ($(getent passwd "$MEDIA_UID" | cut -d: -f1)) - not creating '${MEDIA_USER}'"
  else
    $SUDO useradd --system --uid "$MEDIA_UID" --no-create-home --shell /usr/sbin/nologin "$MEDIA_USER"
    ok "created system user '${MEDIA_USER}' (uid ${MEDIA_UID}, no login, no home)"
  fi

  local d
  for d in \
    "${MEDIA_ROOT}/dropzone/media" "${MEDIA_ROOT}/dropzone/music" \
    "${MEDIA_ROOT}/dropzone/books" "${MEDIA_ROOT}/dropzone/audiobooks" \
    "${MEDIA_ROOT}/dropzone/photos" \
    "${MEDIA_ROOT}/films" "${MEDIA_ROOT}/music" "${MEDIA_ROOT}/books" \
    "${MEDIA_ROOT}/audiobooks" "${MEDIA_ROOT}/photos"
  do
    $SUDO install -d -o "$MEDIA_UID" -g "$MEDIA_UID" -m 0755 "$d"
  done
  ok "media directories created under ${MEDIA_ROOT} (owner ${MEDIA_UID}:${MEDIA_UID}, mode 0755)"
}

# =============================================================================
# STEP 5 - Generate secrets
# =============================================================================
generate_secrets() {
  step "Step 5/14 - Generate secrets"
  info "running secrets/generate.sh (argon2id hashes via the pinned Authelia image)..."
  $SUDO bash "${PROOT}/secrets/generate.sh" || die "secrets/generate.sh failed."

  # Verify a representative set of required secrets landed non-empty.
  local req f
  req="authelia_jwt_secret authelia_session_secret authelia_storage_encryption_key authelia_oidc_hmac_secret authelia_oidc_private_key.pem"
  for f in $req; do
    [ -s "${PROOT}/secrets/${f}" ] || die "expected secret missing after generate.sh: secrets/${f}"
  done
  ok "core secrets present"
}

# =============================================================================
# STEP 6 - Write config.json (superset: spec fields + fields bootstrap requires)
# =============================================================================
write_config() {
  step "Step 6/14 - config.json"
  # Detect the LAN IP on the default route (needed for client instructions).
  VM_IP="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
  [ -n "$VM_IP" ] || VM_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
  [ -n "$VM_IP" ] || die "could not determine this host's LAN IP address."
  TIMEZONE="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
  [ -n "$TIMEZONE" ] || TIMEZONE="$(cat /etc/timezone 2>/dev/null || echo Etc/UTC)"

  # bootstrap.sh load_config REQUIRES domain, tls_mode, storage_path, timezone,
  # admin_email + modules[core], and lib/preflight.sh reads the preflight block.
  # The public spec's config.json omits storage_path/timezone/admin_email, so we
  # write the documented superset here (values from the spec kept verbatim).
  $SUDO tee "${PROOT}/config.json" >/dev/null <<CONFIG_JSON_EOF
{
  "domain": "${DOMAIN}",
  "tls_mode": "local",
  "storage_path": "${MEDIA_ROOT}",
  "media_root": "${MEDIA_ROOT}",
  "timezone": "${TIMEZONE}",
  "admin_email": "admin@${DOMAIN}",
  "modules": ["core"],
  "preflight": {
    "min_ram_mb": 2048,
    "min_free_disk_gb": 20,
    "immich_min_ram_mb": 6144,
    "immich_db_filesystems": ["ext4", "xfs", "btrfs", "zfs"]
  }
}
CONFIG_JSON_EOF
  # config.json is bind-mounted into the wizard (user 1100), which rewrites it
  # during first-run setup, so it must be owned by 1100.
  $SUDO chown 1100:1100 "${PROOT}/config.json"
  ok "wrote ${PROOT}/config.json (domain=${DOMAIN}, tls_mode=local, tz=${TIMEZONE}, LAN IP=${VM_IP})"
}

# =============================================================================
# STEP 7 - Write .env (compose variable anchor)
# =============================================================================
write_env() {
  step "Step 7/14 - .env"
  $SUDO tee "${PROOT}/.env" >/dev/null <<ENV_EOF
SF_BASE_DOMAIN=${DOMAIN}
SMB_USER=${MEDIA_USER}
ENV_EOF
  ok "wrote ${PROOT}/.env"
}

# =============================================================================
# STEP 8 - Firewall (DOCKER-USER rules) + persistence
# =============================================================================
apply_firewall() {
  step "Step 8/14 - Firewall (DOCKER-USER)"
  # DOCKER-USER exists only after dockerd has initialised its chains; create it
  # if missing so -I never errors on a brand-new daemon.
  $SUDO iptables -L DOCKER-USER -n >/dev/null 2>&1 || $SUDO iptables -N DOCKER-USER 2>/dev/null || true

  # Insert idempotently: only add a rule that is not already present (-C check).
  _fw() {
    if ! $SUDO iptables -C "$@" 2>/dev/null; then
      $SUDO iptables -I "$@"
    fi
  }
  # 80/443 from anywhere; SMB (139/445) LAN-only, everything else to SMB dropped.
  _fw DOCKER-USER -p tcp -m multiport --dports 80,443 -m conntrack --ctstate NEW -j ACCEPT
  _fw DOCKER-USER -p tcp -m multiport --dports 139,445 -s 192.168.0.0/16 -m conntrack --ctstate NEW -j ACCEPT
  _fw DOCKER-USER -p tcp -m multiport --dports 139,445 -m conntrack --ctstate NEW -j DROP
  ok "DOCKER-USER rules applied"

  export DEBIAN_FRONTEND=noninteractive
  # Preseed so iptables-persistent installs without an interactive prompt.
  printf 'iptables-persistent iptables-persistent/autosave_v4 boolean true\n' | $SUDO debconf-set-selections
  printf 'iptables-persistent iptables-persistent/autosave_v6 boolean true\n' | $SUDO debconf-set-selections
  $SUDO apt-get install -y iptables-persistent >/dev/null 2>&1 || warn "iptables-persistent install had issues; rules are live but may not survive reboot."
  if command -v netfilter-persistent >/dev/null 2>&1; then
    $SUDO netfilter-persistent save >/dev/null 2>&1 || warn "could not persist iptables rules."
    ok "firewall rules saved (persist across reboot)"
  else
    warn "netfilter-persistent not available; firewall rules are live but not persisted."
  fi
}

# =============================================================================
# STEP 9 - Build local images (importer + wizard + Seerr)
# =============================================================================
# Seerr (jellyseerr:sso-patch) is built from source, NOT pulled: upstream Seerr
# v3.3.0 + the Remote-User trusted-header SSO patch. The two patched inputs
# (server/middleware/auth.ts + Dockerfile.fcuk-em-all) ship in the release tree
# under wizard-ext/jellyseerr/; the upstream source is fetched at build time.
build_seerr_image() {
  local patched="${PROOT}/wizard-ext/jellyseerr/server/middleware/auth.ts"
  local dfile="${PROOT}/wizard-ext/jellyseerr/Dockerfile.fcuk-em-all"
  [ -f "$patched" ] || die "Seerr SSO patch missing from release tree: ${patched}"
  [ -f "$dfile" ]   || die "Seerr Dockerfile missing from release tree: ${dfile}"
  info "building fcuk-em-all/jellyseerr:sso-patch (Seerr v3.3.0 + SSO patch; downloads source + compiles, several minutes + ~2 GB)..."
  local src; src="$(mktemp -d /tmp/seerr-src.XXXXXX)"
  curl -4 -fsSL "https://github.com/seerr-team/seerr/archive/refs/tags/v3.3.0.tar.gz" \
    | $SUDO tar -xz -C "$src" --strip-components=1 \
    || { $SUDO rm -rf "$src"; die "failed to download Seerr v3.3.0 source."; }
  $SUDO cp "$patched" "${src}/server/middleware/auth.ts" || { $SUDO rm -rf "$src"; die "failed to overlay patched auth.ts"; }
  $SUDO cp "$dfile"   "${src}/Dockerfile.fcuk-em-all"    || { $SUDO rm -rf "$src"; die "failed to overlay Dockerfile.fcuk-em-all"; }
  ( cd "$src" || exit 1
    $SUDO env DOCKER_BUILDKIT=1 docker build \
      -f Dockerfile.fcuk-em-all -t fcuk-em-all/jellyseerr:sso-patch \
      --build-arg COMMIT_TAG=v3.3.0 . ) \
    || { $SUDO rm -rf "$src"; die "Seerr image build failed."; }
  $SUDO rm -rf "$src"
  ok "Seerr (jellyseerr:sso-patch) image built"
}

build_images() {
  step "Step 9/14 - Build images"
  info "building fcuk-em-all/importer:local ..."
  $SUDO docker build -t fcuk-em-all/importer:local "${PROOT}/importer/" \
    || die "importer image build failed."
  ok "importer image built"

  info "building fcuk-em-all/wizard:local (two-stage: Vite/React -> Python; this takes a few minutes)..."
  $SUDO env DOCKER_BUILDKIT=1 docker build -t fcuk-em-all/wizard:local "${PROOT}/wizard/" \
    || die "wizard image build failed."
  ok "wizard image built"

  build_seerr_image
}

# =============================================================================
# STEP 10 - /etc/hosts on the VM (containers resolve each other via Caddy)
# =============================================================================
write_hosts() {
  step "Step 10/14 - /etc/hosts (appliance side)"
  local sub names="" line
  for sub in $CORE_SUBDOMAINS; do names="${names} ${sub}.${DOMAIN}"; done
  # collapse leading space
  names="${names# }"
  line="127.0.0.1 ${names}"

  if grep -qF "stream.${DOMAIN}" /etc/hosts 2>/dev/null; then
    ok "/etc/hosts already contains appliance subdomains - not duplicating"
  else
    printf '%s\n' "$line" | $SUDO tee -a /etc/hosts >/dev/null
    ok "added appliance subdomains to /etc/hosts -> 127.0.0.1"
  fi
}

# =============================================================================
# PROVISION - fill the zero-state gaps bootstrap.sh / generate.sh assume exist.
# (external network, local-mode Caddyfile, Authelia config + users, env files)
# =============================================================================
provision_runtime() {
  step "Provisioning runtime state (network, edge/auth config, env files)"

  # -- external network (bootstrap never creates it; every compose file needs it) --
  if $SUDO docker network inspect fcuk-em-all >/dev/null 2>&1; then
    ok "docker network 'fcuk-em-all' exists"
  else
    $SUDO docker network create fcuk-em-all >/dev/null && ok "created docker network 'fcuk-em-all'"
  fi

  $SUDO mkdir -p "${PROOT}/templates/authelia" "${PROOT}/state/wizard" "${PROOT}/secrets/tls"
  # the wizard (user 1100) writes into state/wizard (pending_reset, usersdb backups,
  # setup_complete marker), so it must own that directory.
  $SUDO chown -R 1100:1100 "${PROOT}/state/wizard"

  # -- local-mode Caddyfile (tls internal). Mirrors lib/configure.sh routing +
  #    API/native-client exemptions, but self-signed instead of mounted certs. --
  info "rendering templates/Caddyfile.dev (local mode: tls internal)"
  $SUDO tee "${PROOT}/templates/Caddyfile.dev" >/dev/null <<CADDY_LOCAL_EOF
# templates/Caddyfile.dev - RENDERED by install.sh (LOCAL mode: self-signed
# 'tls internal'). Routes by service name; gate-split exemptions match
# lib/configure.sh so native apps keep their own auth. Do not hand-edit.
{
	admin off
	auto_https disable_redirects
}

# Wizard / control plane - GATED (two_factor).
stream.${DOMAIN} {
	tls internal
	forward_auth authelia:9091 {
		uri /api/authz/forward-auth
		copy_headers Remote-User Remote-Groups Remote-Name Remote-Email
	}
	reverse_proxy wizard:8088
}

# Authelia portal.
auth.${DOMAIN} {
	tls internal
	reverse_proxy authelia:9091
}

# Jellyfin - only the web UI gated; API surface exempt (native clients).
jellyfin.${DOMAIN} {
	tls internal
	@webui {
		path /web /web/*
		not path /web/ConfigurationPage*
	}
	forward_auth @webui authelia:9091 {
		uri /api/authz/forward-auth
		copy_headers Remote-User Remote-Groups Remote-Name Remote-Email
	}
	reverse_proxy jellyfin:8096
}

# Immich - web UI gated; /api/* exempt (native app JWT/API-key auth).
immich.${DOMAIN} {
	tls internal
	@gated {
		not path /api /api/*
	}
	forward_auth @gated authelia:9091 {
		uri /api/authz/forward-auth
		copy_headers Remote-User Remote-Groups Remote-Name Remote-Email
	}
	reverse_proxy immich:2283
}

# Navidrome - web UI gated; Subsonic /rest/* exempt (native Subsonic clients).
navidrome.${DOMAIN} {
	tls internal
	@gated {
		not path /rest /rest/*
	}
	forward_auth @gated authelia:9091 {
		uri /api/authz/forward-auth
		copy_headers Remote-User Remote-Groups Remote-Name Remote-Email
	}
	reverse_proxy navidrome:4533
}

# Kavita - web UI gated; OPDS feed /api/opds/* exempt (native e-readers).
kavita.${DOMAIN} {
	tls internal
	@gated {
		not path /api/opds /api/opds/*
	}
	forward_auth @gated authelia:9091 {
		uri /api/authz/forward-auth
		copy_headers Remote-User Remote-Groups Remote-Name Remote-Email
	}
	reverse_proxy kavita:5000
}

# Audiobookshelf - web UI gated; native-app surface exempt (ABS JWT).
audiobookshelf.${DOMAIN} {
	tls internal
	@gated {
		not path /login /api /api/* /hls /hls/* /socket.io /socket.io/*
	}
	forward_auth @gated authelia:9091 {
		uri /api/authz/forward-auth
		copy_headers Remote-User Remote-Groups Remote-Name Remote-Email
	}
	reverse_proxy audiobookshelf:13378
}

# Host-agnostic plain-HTTP liveness (keeps the Caddy healthcheck simple).
:80 {
	@ok path /health /healthz
	respond @ok "ok" 200
	respond 404
}
CADDY_LOCAL_EOF

  # In local mode the caddy.yml cert mounts are vestigial; touch placeholder
  # files so the single-file bind mounts bind FILES (not root-owned empty dirs).
  $SUDO touch "${PROOT}/secrets/tls/fullchain.cer" "${PROOT}/secrets/tls/${DOMAIN}.key"
  $SUDO chmod 600 "${PROOT}/secrets/tls/fullchain.cer" "${PROOT}/secrets/tls/${DOMAIN}.key"

  # -- Authelia configuration.yml (mirrors lib/configure.sh render) --
  info "rendering templates/authelia/configuration.yml"
  $SUDO tee "${PROOT}/templates/authelia/configuration.yml" >/dev/null <<AUTHELIA_CFG_EOF
# templates/authelia/configuration.yml - RENDERED by install.sh.
theme: light
server:
  address: 'tcp://0.0.0.0:9091'
log:
  level: info
authentication_backend:
  file:
    path: /config/users_database.yml
access_control:
  default_policy: two_factor
session:
  cookies:
    - domain: '${DOMAIN}'
      authelia_url: 'https://auth.${DOMAIN}'
      default_redirection_url: 'https://stream.${DOMAIN}'
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
  issuer: '${DOMAIN}'
AUTHELIA_CFG_EOF

  # -- Authelia bootstrap admin. Authelia needs >=1 user to start AND the gated
  #    wizard must be reachable, so seed an admin now; the setup wizard replaces
  #    it. Password is generated, stored 0600 in secrets/, NEVER printed. --
  local authelia_image admin_pw admin_hash
  authelia_image="$(awk '/image:/{print $2; exit}' "${PROOT}/compose/authelia.yml")"
  [ -n "$authelia_image" ] || die "could not read the Authelia image from compose/authelia.yml"
  admin_pw="$(openssl rand -base64 18)"
  info "hashing bootstrap admin password (argon2id via ${authelia_image%@*})"
  admin_hash="$($SUDO docker run --rm "$authelia_image" authelia crypto hash generate argon2 \
                 -m 65536 -i 3 -p 4 --password "$admin_pw" 2>/dev/null | sed -n 's/^Digest: //p')"
  [ -n "$admin_hash" ] || die "argon2 hashing of the bootstrap admin password failed."
  printf '%s\n' "$admin_pw"  | $SUDO tee "${PROOT}/secrets/authelia_admin_password.txt" >/dev/null
  printf '%s\n' "$admin_hash" | $SUDO tee "${PROOT}/secrets/authelia_admin_password_hash" >/dev/null
  $SUDO chmod 600 "${PROOT}/secrets/authelia_admin_password.txt" "${PROOT}/secrets/authelia_admin_password_hash"

  info "rendering templates/authelia/users_database.yml"
  $SUDO tee "${PROOT}/templates/authelia/users_database.yml" >/dev/null <<USERS_EOF
# templates/authelia/users_database.yml - RENDERED by install.sh (carries a hash).
users:
  admin:
    disabled: false
    displayname: 'Administrator'
    password: '${admin_hash}'
    email: 'admin@${DOMAIN}'
    groups:
      - admins
USERS_EOF
  $SUDO chmod 600 "${PROOT}/templates/authelia/users_database.yml"
  # the wizard (user 1100) rewrites users_database.yml in place during setup
  # (same inode Authelia watches), so it must own the file.
  $SUDO chown 1100:1100 "${PROOT}/templates/authelia/users_database.yml"

  # -- compose/wizard.env (generate.sh does NOT create it; wizard.yml requires
  #    it). Only SF_BASE_DOMAIN is needed at boot; integration creds are written
  #    by the wizard's own configuration flow later. --
  info "creating compose/wizard.env"
  $SUDO tee "${PROOT}/compose/wizard.env" >/dev/null <<WIZ_ENV_EOF
# compose/wizard.env - created by install.sh. Only SF_BASE_DOMAIN is required at
# boot; the wizard populates the service-integration keys during setup.
SF_BASE_DOMAIN=${DOMAIN}
WIZ_ENV_EOF
  $SUDO chmod 600 "${PROOT}/compose/wizard.env"

  # -- secrets/immich.env + secrets/smb.env are produced by secrets/generate.sh
  #    (Step 5), the single source of truth for them. provision does NOT re-create
  #    them: doing so would overwrite generate.sh's values with divergent DB
  #    user/hostnames and rotate the samba password. Verify they landed. --
  local envf
  for envf in secrets/immich.env secrets/smb.env; do
    [ -s "${PROOT}/${envf}" ] || die "expected ${envf} missing after generate.sh (Step 5) - cannot provision runtime."
  done
  ok "immich.env + smb.env present (from generate.sh)"

  ok "runtime state provisioned"
}

# =============================================================================
# STEP 11 - Run bootstrap, then verify the CORE stack is healthy
# =============================================================================
run_bootstrap() {
  step "Step 11/14 - Bootstrap the appliance"
  # bootstrap.sh returns non-zero when its verify stage sees the arr-stack
  # subdomains missing - EXPECTED on a core-only install. So we don't trust its
  # exit code alone: we run it, then verify the CORE containers + edge ourselves.

  # UNCONDITIONAL - always runs before bootstrap. Drop credential-bearing volumes
  # a prior/partial install may have left, so Immich Postgres + Authelia
  # re-initialise with THIS run's freshly generated secrets (a stale pgdata keeps
  # its OLD password and then auth-fails). Force-remove any lingering containers
  # holding those volumes FIRST - otherwise `docker volume rm` fails "volume in
  # use" and, silenced by || true, leaves the stale volume in place.
  $SUDO docker rm -f fcuk-em-all-immich fcuk-em-all-immich-postgres \
    fcuk-em-all-immich-redis fcuk-em-all-immich-ml fcuk-em-all-authelia 2>/dev/null || true
  $SUDO docker volume rm -f \
    fcuk-em-all_immich_pgdata \
    fcuk-em-all_immich_upload \
    fcuk-em-all_immich_modelcache \
    fcuk-em-all_authelia_data 2>/dev/null || true

  local brc=0
  $SUDO bash "${PROOT}/bootstrap.sh" || brc=$?
  if [ "$brc" -ne 0 ]; then
    warn "bootstrap.sh exited ${brc} (its verify checks the arr stack, which core-only installs do not run) - checking core health directly."
  fi

  # Module-aware expected-container set: core is always expected; add the
  # arr-stack containers only when config.json enables the arr module (mirrors
  # bootstrap.sh stage_verify). install.sh writes modules=[core], so on a stock
  # install this is the core set; it stays correct if arr is later enabled.
  local expect must st missing=0
  expect="fcuk-em-all-caddy fcuk-em-all-authelia fcuk-em-all-jellyfin fcuk-em-all-navidrome fcuk-em-all-kavita fcuk-em-all-audiobookshelf fcuk-em-all-immich fcuk-em-all-immich-postgres fcuk-em-all-immich-redis fcuk-em-all-immich-ml fcuk-em-all-samba fcuk-em-all-wizard"
  if grep '"modules"' "${PROOT}/config.json" 2>/dev/null | grep -q '"arr"'; then
    info "arr module enabled - including arr-stack containers in the health check"
    expect="${expect} fcuk-em-all-gluetun fcuk-em-all-qbittorrent fcuk-em-all-prowlarr fcuk-em-all-radarr fcuk-em-all-sonarr fcuk-em-all-flaresolverr fcuk-em-all-jellyseerr"
  fi
  for must in $expect; do
    st="$($SUDO docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$must" 2>/dev/null || echo missing)"
    case "$st" in
      healthy|running) ok "stack: ${must} (${st})" ;;
      *) err "stack: ${must} (${st})"; missing=$((missing + 1)) ;;
    esac
  done
  if [ "$missing" -ne 0 ]; then
    err "appliance stack has ${missing} unhealthy/missing container(s)."
    _c "Bootstrap failed - run: sudo bash ${PROOT}/bootstrap.sh --verify-only"
    exit 1
  fi
  ok "appliance stack healthy"
}

# =============================================================================
# STEP 11b - Provision the Audiobookshelf API token for the wizard
# =============================================================================
# Best-effort: mints an ABS API key and writes it to secrets/abs_token.txt +
# compose/wizard.env, then recreates the wizard. On a FRESH install ABS has no
# admin yet (the setup wizard creates it), so this typically DEFERS with a
# warning and the wizard provisions the token during setup. Never fatal.
provision_abs_token() {
  step "Step 11b/14 - Audiobookshelf API token (wizard integration)"
  command -v python3 >/dev/null 2>&1 || { warn "python3 unavailable; the wizard will set the ABS token later. Skipping."; return 0; }
  local absip; absip="$($SUDO docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' fcuk-em-all-audiobookshelf 2>/dev/null || true)"
  [ -n "$absip" ] || { warn "audiobookshelf container not found; skipping ABS token."; return 0; }
  local base="http://${absip}:13378"
  local isinit
  isinit="$(curl -4 -fsS -m 8 "${base}/status" 2>/dev/null | python3 -c 'import json,sys;print(json.load(sys.stdin).get("isInit"))' 2>/dev/null || echo None)"
  if [ "$isinit" != "True" ]; then
    warn "Audiobookshelf has no admin yet (isInit=${isinit}); the setup wizard provisions the ABS token. Deferring (non-fatal)."
    return 0
  fi
  local pw; pw="$($SUDO cat "${PROOT}/secrets/audiobookshelf_admin_password.txt" 2>/dev/null || true)"
  [ -n "$pw" ] || { warn "audiobookshelf_admin_password.txt missing; skipping ABS token."; return 0; }
  info "authenticating to Audiobookshelf as root..."
  local login token uid
  login="$(curl -4 -fsS -m 10 -X POST "${base}/login" -H 'Content-Type: application/json' \
      --data "$(python3 -c 'import json,sys;print(json.dumps({"username":"root","password":sys.argv[1]}))' "$pw")" 2>/dev/null || true)"
  token="$(printf '%s' "$login" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d.get("user",{}).get("token") or d.get("token") or "")' 2>/dev/null || true)"
  uid="$(printf '%s' "$login" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d.get("user",{}).get("id") or d.get("id") or "")' 2>/dev/null || true)"
  if [ -z "$token" ] || [ -z "$uid" ]; then
    warn "Audiobookshelf root login returned no token (admin password may not match); the wizard can set the ABS token later. Skipping."
    return 0
  fi
  info "creating ABS API key 'fcuk-em-all-wizard'..."
  local key
  key="$(curl -4 -fsS -m 10 -X POST "${base}/api/api-keys" -H "Authorization: Bearer ${token}" -H 'Content-Type: application/json' \
      --data "$(python3 -c 'import json,sys;print(json.dumps({"name":"fcuk-em-all-wizard","userId":sys.argv[1],"isActive":True}))' "$uid")" 2>/dev/null \
      | python3 -c 'import json,sys;a=json.load(sys.stdin).get("apiKey");print((a.get("apiKey") if isinstance(a,dict) else a) or "")' 2>/dev/null || true)"
  if [ -z "$key" ]; then
    warn "ABS API-key creation failed; the wizard can set the ABS token later. Skipping."
    return 0
  fi
  printf '%s\n' "$key" | $SUDO tee "${PROOT}/secrets/abs_token.txt" >/dev/null
  $SUDO chmod 600 "${PROOT}/secrets/abs_token.txt"
  if $SUDO grep -q '^ABS_TOKEN=' "${PROOT}/compose/wizard.env" 2>/dev/null; then
    $SUDO sed -i "s#^ABS_TOKEN=.*#ABS_TOKEN=${key}#" "${PROOT}/compose/wizard.env"
  else
    printf 'ABS_TOKEN=%s\n' "$key" | $SUDO tee -a "${PROOT}/compose/wizard.env" >/dev/null
  fi
  local wproj; wproj="$($SUDO docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' fcuk-em-all-wizard 2>/dev/null || true)"
  info "recreating wizard to apply ABS_TOKEN..."
  if [ -n "$wproj" ]; then
    $SUDO docker compose -p "$wproj" --project-directory "${PROOT}" -f "${PROOT}/compose/wizard.yml" up -d wizard >/dev/null 2>&1 \
      || warn "wizard recreate failed; restart it manually to apply ABS_TOKEN."
  else
    $SUDO docker compose --project-directory "${PROOT}" -f "${PROOT}/compose/wizard.yml" up -d wizard >/dev/null 2>&1 \
      || warn "wizard recreate failed; restart it manually to apply ABS_TOKEN."
  fi
  ok "Audiobookshelf API token provisioned (first4 ${key:0:4}...); wizard updated."
}

# =============================================================================
# STEP 12 - Wait for the wizard to answer
# =============================================================================
wait_for_wizard() {
  step "Step 12/14 - Wait for the setup wizard"
  local waited=0
  while [ "$waited" -lt 120 ]; do
    if curl -4 -fsS -m 4 -o /dev/null "http://127.0.0.1:8088/health" 2>/dev/null; then
      ok "wizard is responding (after ${waited}s)"
      return 0
    fi
    sleep 5
    waited=$((waited + 5))
    info "waiting for wizard... (${waited}s)"
  done
  err "wizard did not respond on http://127.0.0.1:8088/health within 120s. Container status:"
  $SUDO docker ps --format 'table {{.Names}}\t{{.Status}}' >&2 || true
  exit 1
}

# =============================================================================
# STEP 13 - Completion instructions
# =============================================================================
print_completion() {
  cat <<COMPLETION_EOF

===================================================
  ${BRAND} installed successfully
===================================================

Your appliance is running at:
  https://stream.${DOMAIN}

--- STEP 1: Add these lines to /etc/hosts on your Mac/PC ---

  ${VM_IP}  stream.${DOMAIN}
  ${VM_IP}  auth.${DOMAIN}
  ${VM_IP}  jellyfin.${DOMAIN}
  ${VM_IP}  navidrome.${DOMAIN}
  ${VM_IP}  kavita.${DOMAIN}
  ${VM_IP}  audiobookshelf.${DOMAIN}
  ${VM_IP}  immich.${DOMAIN}
  ${VM_IP}  requests.${DOMAIN}

--- STEP 2: Trust the local TLS certificate ---

  1. Open: http://${VM_IP}:${CA_HTTP_PORT}/caddy-root-ca.crt
     (available for 10 minutes after install)
  2. Download and install the certificate as a
     trusted root CA on your Mac or PC.
     macOS: double-click -> Keychain -> Always Trust
     Windows: double-click -> Install -> Trusted Root

--- STEP 3: Open the setup wizard ---

  https://stream.${DOMAIN}

  The wizard is protected by the login gate. Sign in with the
  bootstrap administrator account, then the wizard walks you
  through creating your own admin, storage, and modules:
     username: admin
     password: on this VM in ${PROOT}/secrets/authelia_admin_password.txt

===================================================
COMPLETION_EOF
}

# =============================================================================
# STEP 14 - Serve Caddy's root CA over HTTP for 10 minutes, then stop
# =============================================================================
serve_root_ca() {
  step "Step 14/14 - Publish the local root CA (10 minutes)"
  # Resolve the real host path of Caddy's /data mount instead of hardcoding a
  # volume name (bootstrap's compose project name is not 'fcuk-em-all').
  local data_dir root_src
  data_dir="$($SUDO docker inspect fcuk-em-all-caddy \
      -f '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Source}}{{end}}{{end}}' 2>/dev/null || true)"
  root_src="${data_dir}/caddy/pki/authorities/local/root.crt"

  if [ -z "$data_dir" ] || ! $SUDO test -f "$root_src"; then
    warn "could not locate Caddy's root CA yet (${root_src:-unknown})."
    warn "It appears shortly after first HTTPS request; retrieve it later from that path."
    return 0
  fi
  $SUDO cp "$root_src" /tmp/caddy-root-ca.crt
  $SUDO chmod 644 /tmp/caddy-root-ca.crt

  # Detached, self-terminating server so the installer exits cleanly.
  $SUDO nohup bash -c "python3 -m http.server ${CA_HTTP_PORT} --directory /tmp >/dev/null 2>&1 & HP=\$!; sleep ${CA_SERVE_SECONDS}; kill \$HP 2>/dev/null || true; rm -f /tmp/caddy-root-ca.crt" >/dev/null 2>&1 &
  disown 2>/dev/null || true
  ok "serving root CA at http://${VM_IP}:${CA_HTTP_PORT}/caddy-root-ca.crt for ${CA_SERVE_SECONDS}s"
}

# =============================================================================
main() {
  banner
  require_root
  check_system
  install_docker
  download_release
  create_user_dirs
  generate_secrets
  write_config
  write_env
  apply_firewall
  build_images
  write_hosts
  provision_runtime
  run_bootstrap
  provision_abs_token
  wait_for_wizard
  print_completion
  serve_root_ca
}

main "$@"
