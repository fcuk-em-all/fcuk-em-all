# Architecture

FCUK-EM-ALL is a set of containers on a single shared Docker network, fronted by
one reverse proxy and gated by one identity provider. Nothing but the proxy is
exposed to the outside world.

## Service map

```
                          Internet / LAN
                               │  443 (HTTPS), 80 (redirect)
                       ┌───────▼────────┐
                       │     Caddy      │  edge + automatic TLS
                       │  (fcuk-em-all- │  routes by subdomain,
                       │     caddy)     │  sets Remote-User after auth
                       └───┬────────┬───┘
             forward-auth  │        │  reverse proxy by hostname
                       ┌───▼───┐    │
                       │Authelia│   ├── stream.  → wizard
                       │  SSO + │   ├── jellyfin.→ Jellyfin
                       │  TOTP  │   ├── navidrome→ Navidrome
                       └────────┘   ├── kavita.  → Kavita
                                    ├── audiobookshelf → Audiobookshelf
                                    ├── immich.  → Immich (+ postgres, redis, ml)
                                    ├── requests.→ Jellyseerr        ┐
                                    ├── radarr.  → Radarr            │ arr
                                    ├── sonarr.  → Sonarr            │ module
                                    ├── prowlarr.→ Prowlarr          │
                                    └── qbittorrent → qBittorrent ───┘
                                                        │ network_mode
                                                   ┌────▼────┐
                                                   │ Gluetun │  vpn module
                                                   │ (NordVPN)│  (fail-closed)
                                                   └─────────┘
       Samba (445/139) shares the media library on the LAN.
```

## Network topology

- A single user-defined Docker bridge network (`fcuk-em-all`) connects every
  container. Services address each other by container name.
- **Only Caddy publishes ports** to the host: `80` and `443`. Samba publishes
  `445`/`139` for LAN file sharing. Everything else is reachable *only* through
  Caddy — the app ports below are internal to the Docker network.
- Under the `vpn` module, qBittorrent uses `network_mode: service:gluetun`, so
  all of its traffic egresses through the NordVPN WireGuard tunnel or not at all.

## Data flows

**1. Single sign-on (every request to a gated app):**
```
Browser → Caddy → (forward_auth) Authelia
   Authelia: valid session? ── no ─→ 302 to auth.<domain> (login + TOTP)
                             └─ yes → Caddy sets `Remote-User: <username>`
                                       → proxied to the app → app trusts the header
```

**2. Import pipeline (nightly + on demand):**
```
New files in /srv/media  →  importer (cron, every minute, flock-guarded)
   → scans libraries, tags, and notifies each app to refresh
   → Jellyfin / Navidrome / Kavita / Audiobookshelf / Immich pick up new items
```

**3. Download pipeline (arr module):**
```
Jellyseerr request → Radarr/Sonarr → Prowlarr (indexer search)
   → qBittorrent (through Gluetun VPN) → completed → importer → libraries
```

## Port map (internal to the Docker network)

| Service | Container | Internal port |
|---------|-----------|---------------|
| Caddy (edge) | fcuk-em-all-caddy | 80, 443 *(published)* |
| Authelia | fcuk-em-all-authelia | 9091 |
| Wizard | fcuk-em-all-wizard | 8088 |
| Jellyfin | fcuk-em-all-jellyfin | 8096 |
| Navidrome | fcuk-em-all-navidrome | 4533 |
| Kavita | fcuk-em-all-kavita | 5000 |
| Audiobookshelf | fcuk-em-all-audiobookshelf | 80 |
| Immich | fcuk-em-all-immich | 2283 |
| Jellyseerr | fcuk-em-all-jellyseerr | 5055 |
| Radarr | fcuk-em-all-radarr | 7878 |
| Sonarr | fcuk-em-all-sonarr | 8989 |
| Prowlarr | fcuk-em-all-prowlarr | 9696 |
| qBittorrent | fcuk-em-all-qbittorrent | 8080 |
| FlareSolverr | fcuk-em-all-flaresolverr | 8191 |
| Samba | fcuk-em-all-samba | 445, 139 *(published)* |

Immich additionally runs `fcuk-em-all-immich-postgres`, `-redis`, and `-ml`
containers, reachable only by Immich.

## Volume map

- **`<storage_path>` (default `/srv/media`)** — your library: `movies`, `shows`,
  `music`, `books`, `comics`, `audiobooks`. Mounted into the media apps and the
  importer. These are your originals; backups never copy them.
- **Per-app config volumes** — each app keeps its database/config in its own
  named volume or `appdata/` path.
- **`secrets/`** — all generated secrets and TLS material, mounted read-only
  where needed. Gitignored, `0600`.
- **`backups/`** — nightly database/config backups (never media). Gitignored.
