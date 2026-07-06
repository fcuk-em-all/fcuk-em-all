# Security Policy

## Reporting a vulnerability

**Do not open a public issue for a security problem.** Report it privately via
GitHub's [**Report a vulnerability**](../../security/advisories/new) button
(Security → Advisories). This opens a private advisory only you and the
maintainers can see.

Please include:
- A description of the issue and its impact.
- Steps to reproduce (redact any real secrets, tokens, or domains).
- Affected component and version/commit.

## Our commitment

- **Acknowledgement within 3 business days.**
- An initial assessment and severity within **7 days**.
- Fix or mitigation timeline shared once triaged; coordinated disclosure once a
  fix is available. We will credit you unless you ask us not to.

## In scope

- The installer (`bootstrap.sh`), library scripts (`lib/`), and modules.
- The setup wizard (`wizard/`) — FastAPI backend and React frontend.
- Secret generation and handling (`secrets/generate.sh`).
- Default Authelia / Caddy configuration and the SSO wiring.
- The Jellyseerr `Remote-User` SSO patch (see
  [docs/jellyseerr-sso-patch.md](docs/jellyseerr-sso-patch.md)).

## Out of scope

- Vulnerabilities in upstream images (Jellyfin, Immich, etc.) — report those to
  their projects; we will bump the pin once fixed upstream.
- Issues that require a already-compromised host or physical access.
- A self-signed certificate warning in **local mode** — that is expected; use
  `tls_mode: domain` for a trusted certificate.
- Anything requiring the operator to have already published their own secrets.

## Hardening notes

- All secrets are generated locally, stored `0600` in a gitignored `secrets/`
  directory, and never printed or committed.
- Every service sits behind Authelia SSO with TOTP two-factor; Caddy sets the
  trusted `Remote-User` header only after successful authentication.
- Images are pinned by digest per architecture; there are no floating tags.
- When the `vpn` module is enabled the download stack is fail-closed: qBittorrent
  shares the VPN container's network namespace and loses all connectivity if the
  tunnel drops.
