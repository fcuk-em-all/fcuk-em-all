# `secrets/`

Everything the appliance needs to authenticate itself and its services lives
here. **This entire directory is gitignored** — only this `README.md` and
`generate.sh` are tracked. Nothing you see below should ever be committed,
pasted into an issue, or shared.

## Generate everything

From the project root, after copying `config.example.json` to `config.json`:

```
bash secrets/generate.sh
```

This is **idempotent** — an existing, non-empty secret is left untouched, so
re-running never rotates a live credential. It creates, all `0600`:

| Group | Files |
|-------|-------|
| Authelia core | `authelia_jwt_secret`, `authelia_session_secret`, `authelia_storage_encryption_key`, `authelia_oidc_hmac_secret`, `authelia_oidc_private_key.pem` |
| Per-app OIDC (SSO) | `authelia_oidc_secret_<app>.txt` + `authelia_oidc_client_hash_<app>` for jellyfin, navidrome, kavita, audiobookshelf, immich, jellyseerr — the hash is **argon2id** (m=65536, t=3, p=4), produced by the pinned Authelia image itself |
| App admin passwords | `<app>_admin_password.txt` for the five media apps, plus `qbittorrent_password.txt` |
| Third-party API keys | placeholder files you fill in: `tmdb_api_key.txt`, `acoustid_api_key.txt`, `opensubtitles_api_key.txt`, `opensubtitles_username.txt`, `opensubtitles_password.txt`, `europeana_api_key.txt` (see `docs/api-keys.md`) |

Secret **values are never printed** — the generator logs file names only.

## Flags

- `--dry-run` — narrate what it would create; write nothing.
- `--force` — regenerate **existing** secrets too. Requires typing `REGENERATE`
  at the prompt, because overwriting a live secret breaks the running stack
  until every service is reconfigured with the new value.
- `--debug` — verbose logging.

## NordVPN (only if the `vpn` module is enabled)

The generator cannot mint a NordVPN token for you. Put yours in
`secrets/nordvpn_token.txt` (`chmod 600`). Get one from the NordVPN dashboard →
Services → NordVPN → "Set up NordVPN manually" → generate an access token. If
the `vpn` module is enabled and this file is missing, `generate.sh` stops and
tells you exactly what to do.

## Third-party API keys

The API-key files start as one-line placeholders describing where to get each
key. Replace the placeholder line with your key. All are optional except where a
feature you enabled needs one — see `docs/api-keys.md` for free-tier details and
signup links.
