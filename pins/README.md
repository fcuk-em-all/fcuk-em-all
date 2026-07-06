# `pins/` — pinned image digests

Every container image the appliance runs is pinned to an exact **content digest**
(`image@sha256:…`), never a floating tag like `:latest` or even `:1.2.3`. A tag
can be re-pointed at a new build at any time; a digest cannot — it names one
immutable image. Pinning is how a fresh install a year from now brings up the
*same* stack that was tested, and how a supply-chain swap of a tag is caught.

## Files

| File | Architecture | Notes |
|------|--------------|-------|
| `arm64.json` | `linux/arm64` | Apple Silicon / ARM hosts. |
| `x86_64.json` | `linux/amd64` | Intel/AMD hosts (the shipping appliance). |

**Digests are per-architecture.** The arm64 and amd64 builds of the same tag have
different digests, so each architecture has its own manifest. `bootstrap.sh`
selects the file matching `uname -m` at install time.

Each image entry records its `tag` (human-readable version), its `digest` (the
law), when it was `recorded_at`, and often a `note` explaining the choice.

## Why it matters

- **Reproducibility** — the same digest always yields the same image.
- **Supply-chain safety** — if an upstream tag is compromised or re-pointed, the
  pinned digest won't match and the pull fails loudly instead of silently running
  a different image.
- **Auditability** — the exact bytes running in production are recorded in git.

Some images are tracked here by a `:latest` tag *plus* a digest. The `:latest`
tag is volatile — **the digest is what actually runs**; the tag is only a hint.

## Updating a pin (new upstream version)

1. Find the new tag's digest for **each** architecture:
   ```
   docker manifest inspect <image>:<newtag>
   ```
   Read the `digest` of the `linux/amd64` entry for `x86_64.json` and the
   `linux/arm64` entry for `arm64.json`.
2. Update the `tag`, `digest`, and `recorded_at` fields in **both** files.
3. Update the corresponding `image:` line in the relevant `compose/*.yml`.
4. Bring the service up, run `bash bootstrap.sh --verify-only`, and confirm the
   feature still works before committing.

For **locally built** images (the wizard, the SSO-patched Jellyseerr) the pinned
input is the **base image** digest; rebuild per architecture and record the new
base digest. See `patches/README.md` and `docs/jellyseerr-sso-patch.md`.

The `docker-compose` binary is architecture-specific too: `x86_64.json` names the
`docker-compose-linux-x86_64` asset, whose `sha256` is verified on the amd64 host.

## Policy

**Never run an unpinned image in production.** A missing pin for your
architecture is a hard stop, not a "pull latest and hope" — resolve the digest
first, record it here, then install.
