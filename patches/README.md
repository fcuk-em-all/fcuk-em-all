# `patches/`

Small, auditable source patches applied to upstream images that lack a feature
the appliance needs. Each patch is a plain `git apply`-able diff, kept as small
as possible so it can be re-read and re-applied against new upstream versions.

## Patches

| Patch | Target | Why |
|-------|--------|-----|
| `jellyseerr-remote-user-sso.patch` | Jellyseerr `server/middleware/auth.ts` | Teach Jellyseerr to trust the Authelia `Remote-User` header so it participates in single sign-on instead of showing a second login. See [../docs/jellyseerr-sso-patch.md](../docs/jellyseerr-sso-patch.md). |

## Build process

Each patch is applied to a fresh clone of the upstream project at a pinned tag,
then a custom image is built:

```
git clone <upstream-repo> src && cd src
git checkout <pinned-tag>
git apply ../patches/<patch-file>
docker build -t fcuk-em-all/<name>:<tag> .
```

The resulting image digest is **architecture-specific** — record it in the
matching `pins/<arch>.json`. Build the arm64 and x86_64 images separately.

## Applying to a new upstream version

1. Check out the new upstream tag.
2. `git apply patches/<patch-file>`. If it no longer applies cleanly (the target
   file moved or changed), port the change by hand — the diffs are intentionally
   tiny and the accompanying doc explains the intent.
3. Rebuild, re-pin the new digest, and verify the feature still works end to end.

## Contributing a patch

Keep it minimal, document the intent and any security implications in a matching
`docs/*.md`, and never patch in anything that weakens the SSO gate or exposes a
service directly. See [../CONTRIBUTING.md](../CONTRIBUTING.md).
