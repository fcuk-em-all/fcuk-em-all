<!-- FCUK-EM-ALL logo goes here (docs/img/logo.png) -->
# FCUK-EM-ALL

### OWN YOUR MEDIA

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
[![ShellCheck](https://img.shields.io/badge/ShellCheck-passing-brightgreen.svg)](.github/workflows/shellcheck.yml)
[![Supported OS](https://img.shields.io/badge/OS-Debian%20%7C%20Ubuntu%20%7C%20macOS-lightgrey.svg)](INSTALL.md)

Streaming services rent you access to media you never own, watch what you watch,
and remove titles whenever a licensing deal lapses. **FCUK-EM-ALL** is a
self-hosted media appliance that replaces Netflix, Spotify, Audible, Kindle,
Google Photos, and live TV with services that run on hardware you control, serve
media you own, and answer to no one but you.

One command brings up the whole stack behind a single sign-on gate with
automatic TLS. A guided first-run wizard walks you through storage, your domain,
an admin account, two-factor auth, and which modules to enable — no YAML, no
Docker knowledge required. Everything is pinned, backed up nightly, and yours.

## What you get

| Service | Replaces | What it does |
|---------|----------|--------------|
| **Jellyfin** | Netflix, live TV | Films, shows, and live TV with EPG |
| **Navidrome** | Spotify | Your music library, Subsonic-compatible apps |
| **Audiobookshelf** | Audible | Audiobooks and podcasts |
| **Kavita** | Kindle | Books and comics |
| **Immich** | Google Photos | Photos and videos with mobile backup |
| **Jellyseerr** | — | Request movies and shows (optional `arr` module) |
| **Setup Wizard** | — | Guided first-run setup and a launcher for every service |

Everything sits behind **Authelia** single sign-on with TOTP two-factor, routed
by **Caddy** with automatic HTTPS. File sharing is handled by **Samba**.

## Quick start

Pick the path that matches your machine. All three end at the same first-run
wizard in your browser.

**macOS (app):**
1. Download `FCUK-EM-ALL.dmg` from the [latest release](../../releases) *(screenshot placeholder)*.
2. Drag the app to Applications and launch it.
3. Follow the wizard at `https://stream.fcuk-em-all.com`.

**Linux (one-liner):**
```
git clone https://github.com/YOUR_USERNAME/fcuk-em-all.git && cd fcuk-em-all \
  && cp config.example.json config.json && "${EDITOR:-nano}" config.json \
  && bash secrets/generate.sh && bash bootstrap.sh
```

**Any OS (git clone, manual):**
```
git clone https://github.com/YOUR_USERNAME/fcuk-em-all.git
cd fcuk-em-all
cp config.example.json config.json     # then edit: domain, tls_mode, modules…
bash secrets/generate.sh               # generate all secrets (idempotent)
bash bootstrap.sh                      # detect host, bring up the stack, verify
```

Full walkthrough, including local-mode vs. custom-domain and troubleshooting:
**[INSTALL.md](INSTALL.md)**.

*Wizard screenshots placeholder — welcome, storage, modules, TOTP, launcher.*

## Requirements

- **OS:** Debian 12/13, Ubuntu 22.04/24.04, or macOS 13+ (Apple Silicon or Intel).
- **Docker** with the Compose plugin.
- **RAM:** 2 GB minimum; **6 GB+** if you enable Immich (photos).
- **Disk:** 20 GB for the stack, plus whatever your library needs.
- A domain (for public HTTPS) *or* nothing at all (local mode uses self-signed certs).

## Documentation

- [INSTALL.md](INSTALL.md) — full setup guide
- [docs/architecture.md](docs/architecture.md) — how the pieces fit together
- [docs/configuration.md](docs/configuration.md) — every config field
- [docs/wizard.md](docs/wizard.md) — the setup wizard
- [docs/api-keys.md](docs/api-keys.md) — optional third-party keys
- [CONTRIBUTING.md](CONTRIBUTING.md) · [SECURITY.md](SECURITY.md) · [CHANGELOG.md](CHANGELOG.md)

## License

[GPL-3.0](LICENSE) © 2026 FCUK-EM-ALL Contributors.

> **On the `arr` module:** the optional request/download stack can fetch
> copyrighted material. You are solely responsible for what you download and for
> complying with the law in your jurisdiction. See the wizard's warning and
> [docs/configuration.md](docs/configuration.md).
