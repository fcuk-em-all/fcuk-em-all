# FCUK-EM-ALL

## What This Is

An opinionated, idempotent orchestration layer that turns a bare Linux box
into a complete self-hosted media appliance - one that replaces paid streaming
(video, music, books, audiobooks, photos) with media the user owns, while
keeping the polished "it just works" feel of the services it replaces.

Shipped as a flashable Linux appliance image (with a VM/OVA variant). The
user's own Windows or Mac is a CLIENT, never the host - the appliance owns its
OS from boot so it can control onboarding, hardware, and updates.

It is a set of scripts and templates, reusable by others. Not a hosted
service, not a business, no control plane. Internal codename: PlexFckr.

## Who It's For

A user who understands nothing technical and has, at minimum, their wifi
credentials. Setup asks for as little as possible and is opinionated, not
customizable. "Drop your files in, get streaming."

## Deliverables (what "the code" is)

FCUK-EM-ALL is not a conventional application. Its deliverables are:
- The ORCHESTRATOR: idempotent scripts that take a bare OS through
  bootstrap -> wizard -> deploy -> configure -> verify, converging from any
  state by reading live system state (never trusting marker files).
- The COMPOSE TEMPLATES: pinned, hygiene-hardened service definitions.
- The WIZARD: a first-run web app that collects only what must be user-supplied
  or shared, writes config, and drives deployment. ITS IMPLEMENTATION LANGUAGE
  IS DELIBERATELY UNDECIDED and must not be assumed; describe behavior, not
  technology, until that decision is made with the maintainer.

## The Stack

Each app is an upstream container image we pull and orchestrate (we do not fork
or build them). Prefer LinuxServer.io images where they exist for a uniform
PUID/PGID/TZ surface.
- Jellyfin - video (the core; hardware transcode path)
- Navidrome - music (Subsonic API; the Spotify-feel clients target it)
- Kavita - books and comics
- Audiobookshelf - audiobooks
- Bazarr - automated subtitles (.srt sidecars)
- Immich - photos (FLAGGED: heavy - bundles Postgres + Redis + an ML
  container; gated behind a toggle and a preflight RAM/filesystem check)
- Caddy - the single TLS endpoint / reverse proxy
- Authelia - SSO + MFA (TOTP) engine
- Tailscale - remote access / trust boundary
- Samba (SMB) - the "drop your files in" network share

## The Four Laws

1. The VPN is the trust boundary. Tailscale-only by default; no bare public
   exposure.
2. One filesystem root for all media, so imports are an atomic mv, never a
   cross-device copy.
3. Provider IDs (tmdbid/tvdbid) are stamped into folder names so Jellyfin skips
   fuzzy matching - this is the anti-mismatch engine.
4. Pin every image by digest. Never use the latest tag. Digests are
   per-architecture (see Deferrals).

## Access and Naming

One hostname: stream.fcuk-em-all.com. One real cert via DNS-01 (a single DNS
record, identical in either mode). Caddy is the sole TLS endpoint both paths
share. Split-horizon resolution: on-VPN devices resolve to the box and stream
directly at LAN speed (bypassing any tunnel); off-VPN devices use the public
path only if WEB mode was chosen. VPN-DNS is the primary local-resolution path;
a hosts-file entry is the power-user fallback.

The user chooses HOST LOCALLY or HOST ON THE WEB at onboarding:
- LOCAL: reachable only on the LAN / tailnet. Private. Default and safe.
- WEB: reachable at the domain from anywhere, for sharing with people who will
  not install a VPN. Implemented via Cloudflare Tunnel (outbound-only, no
  port-forwarding, free TLS, home IP hidden), which requires the domain's DNS
  on Cloudflare and an auth gate (Cloudflare Access / Authelia) in front.
  Jellyfin's API path is exempted from the gate so native client apps still
  work.

## Onboarding Model

IoT-appliance pattern: the box broadcasts a setup wifi, the user joins it from
a phone, hands over home wifi credentials via a captive portal, and the box
joins the network and becomes reachable. The user never sees an IP, a port, a
path, or a terminal.

Required user inputs (kept tiny): wifi password, domain, and the LOCAL/WEB
choice. Auto-detected: media storage location, GPU vendor. Auto-generated:
every app admin credential (written to a root-only secrets file, shown once).
Optional: OpenSubtitles credentials (Bazarr); Cloudflare credential (WEB only).
Tailscale joins via an interactive login link, not a pasted key.

## The Importer

Continuous watch-folder. The SMB share exposes a drop zone - the only
read-write media area. The importer parses a dropped file, matches it against
TMDB/TVDB, renames to strict SxxExx and stamps the provider ID, then does an
atomic mv into the organized tree. It NEVER edits the user's originals in
place. On an ambiguous match it quarantines to a visible "Needs Attention"
area rather than guessing - wrong-sorting is worse than not-sorting.

## The Seven Locked Decisions

1. Ship a flashable Linux appliance image (VM/OVA variant offered); host OS is
   ours.
2. Importer: continuous watch-folder, quarantine on ambiguity, never touch
   originals.
3. Preflight: three tiers - hard-stop (halt), capability warning (proceed and
   log), per-app gate (auto-decide safe default with visible override).
   Warnings surface in the web UI, never a terminal.
4. Updates: published versioned pinned manifests, one-click in the UI; re-pin +
   re-run + verify; keep N-1 for rollback.
5. Backup: nightly pg_dump of every DB + tar of appdata to a user-designated
   second location; bulk media and Immich originals are the user's
   responsibility, exposed over SMB.
6. GPU: Intel QSV/VAAPI first-class; NVIDIA supported; AMD best-effort (Linux
   VAAPI); CPU fallback with a clear notice.
7. Auth: Authelia is the SSO/MFA engine; our build effort is the provisioning +
   TOTP-enrollment UX on top; web UIs gated, Jellyfin API exempted for native
   apps. We do NOT hand-roll session/crypto.

## Hardening and Hygiene (carry into every service)

Read-only media mounts for serving apps; read-write only for the importer and
SMB; Bazarr writes to subtitle paths. Use --remove-orphans on every compose up.
Set JELLYFIN_PublishedServerUrl. Per-service hygiene: restart policy, log
rotation, healthchecks, health-gated depends_on. Jellyfin specifics: two-phase
config (lean index first, enrich after first scan), QSV + HDR tone-mapping,
transcode scratch to a capped RAM tmpfs, filenames-over-embedded-titles,
default-language and bitrate caps.

## Honest Deferrals (this dev VM is arm64)

The build VM is an Apple-silicon (M2 Pro) Mac mini running Debian 13 arm64. Two
things CANNOT be exercised here and must be marked owed on real amd64 Intel
hardware, never faked:
1. Hardware (QSV) transcoding - no Intel iGPU; Docker cannot reach Apple
   VideoToolbox. Jellyfin here software-transcodes only. Build and verify the
   CONFIGURATION path; defer the real hardware-transcode test.
2. amd64 image digests - pins are per-arch. Digests validated here are arm64;
   the shipping appliance is amd64. Treat pinning here as rehearsal; re-resolve
   and re-verify on amd64. Keep the pin list arch-tagged.
Build the architecture-agnostic majority here (orchestrator, Caddy, Authelia,
importer, wizard, the non-Jellyfin apps).

## Explicitly Out of Scope

No automated content-acquisition pipeline (no Sonarr/Radarr/Prowlarr/indexers/
debrid). The media root is populated by the user's own rips and uploads.
FCUK-EM-ALL organizes and serves; it does not source.

## Project Status

Scaffold initialized. Host VM bootstrapped and hardened (build scripts 1-2 run:
system hardening + key-only SSH). No application code written yet. Next:
confirm the first build phase with the maintainer before planning it.
