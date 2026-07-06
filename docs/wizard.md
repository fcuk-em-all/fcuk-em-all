# The Setup Wizard

The wizard is a FastAPI backend plus a React frontend (`wizard/`), served at
`stream.<domain>` through Caddy. It has two jobs: walk a new operator through
**first-run setup**, then act as the day-to-day **launcher** for every service.

## First-run setup

Until setup is complete the wizard redirects every route to `/setup`. It runs
seven steps and validates each before letting you advance:

1. **Welcome** — what the appliance is; a single "Let's go" button.
2. **Storage** — choose the library directory. Validated for existence,
   writability, and free space (warns below 100 GB, blocks below 50 GB).
3. **Domain mode** — pick **Local** (self-signed certs + hosts entries) or
   **Custom domain** (real ACME certificates; collects domain, DNS provider, and
   API key). Must succeed before continuing.
4. **Admin account** — username and a password (12+ chars, strength meter). The
   account propagates to Authelia and every app, shown as a per-app grid.
5. **Modules** — toggle **Media Core** (locked on), **Requests** (`arr`, with the
   legal warning about downloading), and **VPN protection** (`vpn`, requires
   Requests; reveals the NordVPN token field).
6. **Two-factor (TOTP)** — scan the inline QR code and enter a 6-digit code.
   Required; no skip.
7. **Ready** — a summary and "Enter the vault," which marks setup complete and
   sends you to the launcher.

Progress is shown as "step N of 7." Back is allowed on steps 2–5; once TOTP is
enrolled there is no going back, and steps cannot be jumped.

## Launcher (after setup)

The home page is a tiled launcher — one card per enabled service (Jellyfin,
Navidrome, Kavita, Audiobookshelf, Immich, and, with the `arr` module,
Jellyseerr) — plus library stats, a recent-imports feed, import queue status, and
a discovery panel that searches public-domain sources.

## HTTP API reference

All endpoints are served by the FastAPI backend. Setup endpoints (added by the
first-run flow) live under `/api/setup/` and are blocked once setup is complete.

### Health & identity
| Method | Path | Purpose |
|--------|------|---------|
| GET | `/health`, `/api/health` | Liveness. |
| GET | `/api/me` | Current signed-in user (from the `Remote-User` header). |
| GET | `/api/system` | Host/appliance status. |
| GET | `/api/stats` | Library counts and totals. |

### Library, queue & users
| Method | Path | Purpose |
|--------|------|---------|
| GET | `/api/recent` | Recently imported items. |
| GET | `/api/search` | Search across libraries. |
| GET | `/api/queue/status`, `/api/queue/progress` | Import queue state. |
| POST | `/api/queue` | Enqueue an import job. |
| GET | `/api/users` · POST `/api/users` · DELETE `/api/users/{username}` | User management. |
| POST | `/api/users/{username}/change-password` | Rotate a user's password. |

### Discovery (public-domain sources)
`GET /api/discover/{source}` for `archive`, `europeana`, `gutenberg`,
`librivox`, `loc`, `openlibrary`, `wikimedia`.

### Setup (only before completion, under `/api/setup/`)
`GET status`, `POST validate-storage`, `POST configure-local-tls`,
`POST configure-domain-tls`, `POST create-admin`, `POST configure-modules`,
`POST verify-totp`, `POST complete`.

> Setup routes return `404`/redirect once `state/setup_complete` exists, and the
> setup endpoints return `403` — setup cannot be re-run without manual intervention.
