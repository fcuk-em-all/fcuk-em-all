# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] — 2026-07-03

First public release.

### Added
- **One-command installer** (`bootstrap.sh`) with host detection for Debian
  12/13, Ubuntu 22.04/24.04, and macOS 13+ on arm64 and x86_64; config
  validation; local and domain TLS modes; idempotent crontab and hosts-file
  management; a 30-point health check (`--verify-only`); `--dry-run` and
  `--debug`.
- **Module system** — `core` (the media appliance), optional `arr`
  (request/download stack), and optional `vpn` (route downloads through NordVPN).
- **Core media services** behind single sign-on: Jellyfin (video + live TV),
  Navidrome (music), Audiobookshelf (audiobooks/podcasts), Kavita (books/comics),
  Immich (photos), plus the Jellyseerr request stack under the `arr` module.
- **Authelia** SSO with TOTP two-factor and OpenID Connect for every app;
  **Caddy** edge with automatic HTTPS; **Samba** file sharing.
- **Jellyseerr `Remote-User` SSO patch** so Jellyseerr trusts the Authelia
  session (see docs/jellyseerr-sso-patch.md).
- **First-run setup wizard** (FastAPI + React) and a service launcher.
- **Secret generation** (`secrets/generate.sh`): Authelia secrets, per-app OIDC
  client secrets with argon2id hashes, admin passwords, and API-key placeholders
  — idempotent, all `0600`.
- **Per-architecture pinned image digests** (`pins/arm64.json`, `pins/x86_64.json`).
- **Nightly automation** via cron: media importer, database backups, certificate
  renewal, library prune, and a boot-time guide refresh.
- Documentation suite, issue/PR templates, and a ShellCheck CI workflow.

[Unreleased]: https://github.com/YOUR_USERNAME/fcuk-em-all/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/YOUR_USERNAME/fcuk-em-all/releases/tag/v0.1.0
