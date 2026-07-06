# Jellyseerr `Remote-User` SSO Patch

## Problem

Every service in the appliance sits behind Authelia single sign-on: Caddy
forward-auths each request and, once authenticated, injects a trusted
`Remote-User` header naming the signed-in user. Apps that understand header
authentication log the user in automatically.

Jellyseerr (as of the version pinned here) has **no native header/SSO support**.
Behind the Authelia gate a user is already authenticated at the edge but is then
shown Jellyseerr's *own* login screen — a second, redundant login, and one whose
credentials Authelia does not manage.

## Solution

A small patch to Jellyseerr's auth middleware: if a request carries a
`Remote-User` header (which only Caddy can set, and only after Authelia
succeeds), look the user up by their Jellyfin username and establish the session.
Ten lines, one file, no new dependencies.

```diff
diff --git a/server/middleware/auth.ts b/server/middleware/auth.ts
index 326d460..76c479b 100644
--- a/server/middleware/auth.ts
+++ b/server/middleware/auth.ts
@@ -27,6 +27,16 @@ export const checkUser: Middleware = async (req, _res, next) => {
     user = await userRepository.findOne({
       where: { id: req.session.userId },
     });
+  } else if (req.headers['remote-user']) {
+    const userRepository = getRepository(User);
+
+    user = await userRepository.findOne({
+      where: { jellyfinUsername: req.headers['remote-user'] as string },
+    });
+
+    if (user && req.session) {
+      req.session.userId = user.id;
+    }
   }
 
   if (user) {
```

## Security analysis

The patch is safe **only because the header is not attacker-controllable**:

- **Caddy overwrites `Remote-User` on every request** (`header_up Remote-User`)
  after a successful Authelia forward-auth. A client-supplied `Remote-User` header
  is discarded at the edge before the request reaches Jellyseerr — it can never
  be forged from outside.
- There are **no path exemptions** on the Jellyseerr route: every request,
  including the API, passes through the same Authelia gate, so the header is
  always freshly set (or absent) by the time middleware runs.
- The lookup only *matches an existing* user by `jellyfinUsername`; it never
  creates accounts or elevates privileges. An unknown header value yields no user
  and falls through to normal handling.

If you deploy Jellyseerr **without** Caddy in front (direct exposure), this patch
must not be applied — the header would then be trusted from the network. In this
appliance Jellyseerr is only ever reached through Caddy.

## Applying it to a new Jellyseerr version

1. Clone the target Jellyseerr release.
2. `git apply patches/jellyseerr-remote-user-sso.patch`. If `server/middleware/auth.ts`
   has moved or the `checkUser` middleware changed shape, apply the same `else if
   (req.headers['remote-user'])` branch by hand — the logic is what matters, not
   the line numbers.
3. Confirm Caddy still overwrites `Remote-User` for the Jellyseerr host.

## Building the image (arm64 and x86_64)

Build from the patched source for your architecture:

```
git clone <jellyseerr-repo> jellyseerr && cd jellyseerr
git checkout <pinned-tag>
git apply ../patches/jellyseerr-remote-user-sso.patch
docker build -t fcuk-em-all/jellyseerr:<tag> .
```

The digest you build is architecture-specific — record it in the matching
`pins/<arch>.json`. On the dev appliance the arm64 image is built; the shipping
appliance is amd64.

## Upstream

Header-based SSO is a recurring Jellyseerr feature request. If/when it lands
upstream, drop this patch and configure the native option instead. Track the
upstream PR before pinning a newer image.
