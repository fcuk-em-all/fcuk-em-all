# Configuration

All non-secret runtime configuration lives in **`config.json`** at the project
root. Copy the template and edit it:

```
cp config.example.json config.json
```

`config.json` is **gitignored** — it never enters version control. Secrets
(NordVPN token, DNS API key, generated passwords) live in `secrets/` and `*.env`,
not here, though the two fields below accept a value locally for convenience.

`bootstrap.sh` validates every required field before it does anything, and
refuses to run on a placeholder (`YOUR_…`) value.

## Fields

| Field | Required | Example | Meaning |
|-------|----------|---------|---------|
| `domain` | yes | `fcuk-em-all.com` | Base domain. Services are served at `stream.<domain>`, `jellyfin.<domain>`, etc. |
| `tls_mode` | yes | `local` \| `domain` | `local` = self-signed certs + hosts entries; `domain` = real ACME certificates. |
| `storage_path` | yes | `/srv/media` | Root of your media library (contains `movies`, `shows`, `music`, `books`, `comics`, `audiobooks`). |
| `timezone` | yes | `America/New_York` | IANA timezone applied to every container. |
| `admin_email` | yes | `you@example.com` | Admin contact; used as the ACME account email in `domain` mode. |
| `modules` | yes | `["core"]` | Which module sets to enable — see below. |
| `nordvpn_token` | if `vpn` | `""` | NordVPN access token. Leave blank here and put it in `secrets/nordvpn_token.txt` if you prefer. |
| `dns_provider` | if `domain` | `cloudflare` | acme.sh DNS provider (e.g. `cloudflare`, `route53`) for DNS-01 issuance. |
| `dns_api_key` | if `domain` | `""` | DNS provider API token. Leave blank here and supply it to acme.sh from `secrets/`. |

### `modules`

- **`core`** *(always required)* — the media appliance itself: Jellyfin,
  Navidrome, Kavita, Audiobookshelf, Immich, Authelia, Caddy, Samba, and the
  wizard.
- **`arr`** *(optional)* — the request/download stack: Radarr, Sonarr,
  Jellyseerr, Prowlarr, qBittorrent, FlareSolverr.
- **`vpn`** *(optional, requires `arr`)* — routes the download stack through
  NordVPN via a Gluetun container. Requires a NordVPN token.

Examples: `["core"]`, `["core","arr"]`, `["core","arr","vpn"]`. Enabling `vpn`
without `arr` is rejected by validation.

### `preflight`

Resource thresholds checked before install. Sensible defaults ship in
`config.example.json`; override only if you know why.

| Field | Default | Meaning |
|-------|---------|---------|
| `min_ram_mb` | `2048` | Minimum host RAM. |
| `min_free_disk_gb` | `20` | Minimum free disk for the stack. |
| `immich_min_ram_mb` | `6144` | Extra RAM required when Immich is enabled. |
| `immich_db_filesystems` | `["ext4","xfs","btrfs","zfs"]` | Filesystems Immich's Postgres is allowed to run on. |

## A note on the `arr` / `vpn` modules

The download stack can fetch copyrighted material. You are responsible for what
you download and for the law where you live. The wizard shows a warning before
enabling `arr`, and no indexers are preconfigured.

## Applying changes

Edit `config.json`, then re-run `bash bootstrap.sh` (idempotent). Use
`--dry-run` to preview and `--verify-only` to just re-check health.
