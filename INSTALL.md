# Installing FCUK-EM-ALL

Three ways in, all ending at the same first-run wizard. Read [Prerequisites](#prerequisites)
first, then pick your platform.

## Prerequisites

- **OS:** Debian 12/13, Ubuntu 22.04/24.04, or macOS 13+ (Apple Silicon or Intel).
- **Docker Engine + Compose plugin.** Verify with `docker compose version`.
- **RAM:** 2 GB minimum; 6 GB+ if enabling Immich.
- **Disk:** 20 GB free for the stack plus your library.
- **A domain** if you want public, browser-trusted HTTPS. Not required for local mode.
- `git`, `openssl`, `curl`, and `python3` (present on all supported OSes by default).

Everything runs in containers with per-architecture **pinned image digests**
(`pins/arm64.json`, `pins/x86_64.json`) — no floating `latest` tags.

## The three modes at a glance

| | Local mode (`tls_mode: local`) | Domain mode (`tls_mode: domain`) |
|-|-------------------------------|----------------------------------|
| DNS | none — hosts file → `127.0.0.1` | public DNS for `*.your-domain` |
| Certs | self-signed (`tls internal`) | Let's Encrypt via ACME DNS-01 |
| Best for | trying it on one machine / LAN | a real always-on appliance |
| Needs | nothing extra | domain + DNS provider API key |

---

## macOS

1. Download `FCUK-EM-ALL.dmg` from the [latest release](../../releases).
2. Open it, drag the app to **Applications**, and launch. On first launch macOS
   may ask you to allow it in **System Settings → Privacy & Security**.
3. The app installs the stack under its application support directory and opens
   the wizard. If prompted for your password, it is writing `*.fcuk-em-all.com`
   entries to `/etc/hosts` (local mode) — that is the only privileged step.
4. Continue at [First-run wizard](#first-run-wizard).

Manual macOS install is identical to the Linux steps below (Docker Desktop
provides the Compose plugin).

## Linux

```
git clone https://github.com/YOUR_USERNAME/fcuk-em-all.git
cd fcuk-em-all
cp config.example.json config.json
```

Edit `config.json` — at minimum set `domain`, `tls_mode`, and `modules`
(see [docs/configuration.md](docs/configuration.md)). Then:

```
bash secrets/generate.sh      # generates every secret, idempotent, all 0600
bash bootstrap.sh             # detects OS/arch, validates config, brings up the stack
```

`bootstrap.sh` refuses to touch anything until `config.json` is valid, backs up
any file before editing it, and finishes with a 30-point health check. Re-run it
any time — it is idempotent.

## Manual / any OS

The manual path is the Linux path, step by step, with nothing hidden:

1. **Clone and configure** — as above.
2. **Choose a TLS mode** in `config.json`:
   - `local`: nothing else to do; `bootstrap.sh` writes hosts entries and Caddy
     serves self-signed certs.
   - `domain`: also set `dns_provider` and `dns_api_key` (or place the key in
     `secrets/`). `bootstrap.sh` installs the renewal cron; issue the first cert
     with `acme.sh` (see `lib/cert-renew.sh` header).
3. **Generate secrets** — `bash secrets/generate.sh`. If the `vpn` module is
   enabled, put your NordVPN token in `secrets/nordvpn_token.txt` first.
4. **Bring it up** — `bash bootstrap.sh`. Add `--dry-run` to preview, `--debug`
   for verbose logs, `--verify-only` to just re-run the health check.
5. **Open the wizard** at `https://stream.<your-domain>`.

---

## First-run wizard

The wizard walks seven steps: **Welcome → Storage → Domain mode → Admin account
→ Modules → Two-factor (TOTP) → Ready.** It validates each step (free disk space,
writable storage, TLS reachability, password strength, TOTP code) before letting
you continue, then hands you a launcher for every service. Details in
[docs/wizard.md](docs/wizard.md).

## Troubleshooting

**1. `docker compose version` fails / "docker not accessible."**
Install Docker Engine + the Compose plugin and ensure your user is in the
`docker` group (`sudo usermod -aG docker "$USER"`, then re-login). `bootstrap.sh`
reports this as a failed health check rather than guessing.

**2. Browser warns the certificate is untrusted (local mode).**
Expected — local mode uses self-signed certs. Trust the cert or switch to
`tls_mode: domain` for a real one.

**3. A subdomain shows an Authelia login loop / 302.**
The service is up but you are not signed in, or your session expired. Sign in at
`https://auth.<your-domain>`. A persistent loop usually means a clock skew —
check the host time and TOTP.

**4. Immich fails to start / restarts.**
Immich needs 6 GB+ RAM and its database on a real filesystem (ext4/xfs/btrfs/zfs).
`bootstrap.sh` preflight warns before install; free up RAM or disable Immich in
`config.json` (`modules` without it is fine).

**5. `arr`/downloads not working, or leaking outside the VPN.**
The `vpn` module must be enabled *and* `secrets/nordvpn_token.txt` populated;
qBittorrent shares Gluetun's network namespace, so if Gluetun is down qBittorrent
has no network at all (fail-closed, by design). Check `docker logs fcuk-em-all-gluetun`.

Still stuck? Open an [issue](../../issues) with your OS, `docker compose version`,
the affected service, and logs (redact any personal data).
