# CLAUDE.md

Guidance for Claude Code (or any future developer) working on this repo. This
is a Cloudron **packaging** repo, not the XWiki application itself — we don't
own XWiki's code, only how it's containerized, configured, and upgraded inside
Cloudron. `README.md` covers install/usage; this file covers the packaging
internals, invariants, and gotchas that matter when changing the Dockerfile,
`start.sh`, or the release process.

## Architecture at a glance

- **Base image:** `xwiki:stable-postgres-tomcat` (official XWiki image, Tomcat
  + PostgreSQL flavour). We don't control its release cadence — it can stay
  unchanged across several of our own releases.
- **Dockerfile, stage 1 (`ldap`):** resolves the XWiki LDAP Authenticator
  extension (not bundled since XWiki 8.3) and its transitive Maven
  dependencies, via `mvn dependency:copy-dependencies` against
  `maven.xwiki.org`. Output copied into the final image's `WEB-INF/lib` in
  stage 2, skipping any jar whose artifact is already present (avoids
  duplicate/conflicting versions).
- **Dockerfile, stage 2:** the actual app image. Relocates the base image's
  `/usr/local/tomcat` and `/usr/local/xwiki` to `/app/pkg/*-dist` and symlinks
  the original paths into `/app/data/*`, because Cloudron's rootfs is
  read-only at runtime and only `/tmp`, `/run`, `/app/data` are writable.
- **`start.sh`:** runs on every boot.
  1. Seeds/reseeds `/app/data/tomcat` and `/app/data/xwiki` from the baked
     dist (see "Reseed version marker" below).
  2. Maps `CLOUDRON_POSTGRESQL_*` → the `DB_*` vars the upstream entrypoint
     expects, and patches the hardcoded `:5432` in `hibernate.cfg.xml` to the
     addon's actual port.
  3. Clears the entrypoint's first-start marker so DB config is re-applied
     every boot (addon credentials can rotate across restarts).
  4. Rewrites a managed LDAP block in `xwiki.cfg` from `CLOUDRON_LDAP_*` env
     vars (idempotent: strips old managed lines first).
  5. `exec`s the upstream `docker-entrypoint.sh xwiki`.

## Critical invariant: the reseed version marker

`start.sh` decides whether to wipe and reseed `/app/data/tomcat` (which is
where `WEB-INF/lib` — and therefore any jar we bake in — lives) by comparing
two version strings:

- `/app/pkg/xwiki.version` — baked into the image at build time.
- `/app/data/xwiki.version` — the version installed on the persistent volume,
  left over from whenever the app was last seeded.

**This marker must change on every release that touches anything under
`WEB-INF` or the Tomcat tree** — not just when the upstream XWiki version
bumps. It currently encodes `${XWIKI_VERSION}+${CloudronManifest.json
version}` (set in the Dockerfile around the `mv /usr/local/tomcat ...` step).

This is a real incident, not a hypothetical: v3.0.2 fixed a broken LDAP jar in
`WEB-INF/lib` (see CHANGELOG), but the marker only tracked
`${XWIKI_VERSION}`, which was unchanged from v3.0.1 — so upgrading in-place
never reseeded, and users kept hitting the bug on the "fixed" version. v3.0.3
fixed the marker itself. **If you ever revert the marker to just
`${XWIKI_VERSION}`, this bug comes back.**

Corollary: any change to the Dockerfile's `WEB-INF/lib` contents, Tomcat
config templates, or anything else under `/app/pkg/tomcat-dist` requires a
`CloudronManifest.json` version bump to actually reach existing installs —
even if the upstream XWiki version tag hasn't moved.

## Release process

1. Bump `"version"` in `CloudronManifest.json` (semver; matches the ghcr.io
   image tag).
2. Add a `[x.y.z]` entry at the top of `CHANGELOG` — this text is shown to
   users in the Cloudron dashboard and in `CloudronVersions.json`.
3. Commit and push to `main`. `.github/workflows/publish.yml` triggers on push
   to `main` for changes to `Dockerfile`, `start.sh`, `CloudronManifest.json`,
   `DESCRIPTION.md`, `CHANGELOG`, or the workflow file itself.
4. CI builds the image, pushes
   `ghcr.io/grienauer/xwiki-cloudron:<version>` and `:latest`, then
   regenerates and commits `CloudronVersions.json` (the catalog consumed by
   the Cloudron dashboard's "Community App" installer).
5. Publishing a new version does **not** auto-update already-installed apps —
   each install needs an explicit update (dashboard "Update" button, or
   `cloudron update`) before it picks up the new image.
6. After an in-place update, confirm `start.sh` actually reseeded: check
   `cloudron logs` for `"Upgrade detected: reseeding webapp to v..."`. If that
   line is missing on a release that touched `WEB-INF`/Tomcat, the version
   marker didn't change — see the invariant above.

## Known constraints (don't try to "fix" these without re-reading why)

- **PostgreSQL only, not MySQL.** XWiki's MySQL migration path needs the
  global `PROCESS` privilege on `information_schema`, which Cloudron's
  isolated MySQL addon doesn't grant. PostgreSQL's addon makes the app user
  own its own database, so no manual grant is needed. This is why the base
  image tag is `stable-postgres-tomcat`.
- **No subwikis.** Multi-wiki needs the DB user to create additional
  schemas/databases; the Cloudron-provisioned user can't.
- **LDAP addon can't be added post-install.** This is a Cloudron platform
  limitation, not ours — so 2.x → 3.x (which added the `ldap` addon) could
  only ship as "fresh install required," not an in-place upgrade.
- **`org.apache.tika` is explicitly excluded** from the LDAP dependency-copy
  stage (`-DexcludeGroupIds=...,org.apache.tika` in the Dockerfile).
  `ldap-authenticator` pins `xwiki-platform-oldcore` to a very old version
  (10.11 as of authenticator 9.16.2), which drags in an ancient transitive
  Tika. Two Tika class sets on the same classpath throw `NoSuchMethodError`
  during attachment mimetype detection — i.e. it breaks every file upload.
  Before adding any other dependency exclusion/inclusion here, check whether
  the transitive version is sane against the base image's own bundled
  version; `org.xwiki.platform`, `org.xwiki.commons`, `org.xwiki.rendering`
  are already excluded for the same reason.
- **JVM heap (`-Xmx2048m`) vs. container `memoryLimit` (3 GB).** The gap is
  intentional headroom for LibreOffice (office doc conversion/preview) and
  native memory. If you raise the heap, raise `memoryLimit` too, and keep a
  comfortable gap — don't set them close together.

## Diagnosing issues

- `cloudron logs -f` is the primary tool. Java stack traces show up there;
  read the innermost `Caused by:` line first.
- `cloudron exec` gives a shell inside the running container —
  `/app/data/xwiki.version` shows what's currently seeded, `/app/pkg/xwiki.version`
  shows what the current image would seed on the next reseed.
- If LDAP login fails with a class-loading error for
  `XWikiLDAPAuthServiceImpl`, the baked jar set in stage 1 is incomplete —
  compare against installing "LDAP Authenticator" manually from
  Administration → Extensions (which resolves its own deps at runtime) to see
  what's missing, then add it to the Dockerfile's dependency resolution.
- Local iteration on the Dockerfile/Maven resolution logic doesn't require a
  full Cloudron install — you can curl the relevant POMs directly from
  `https://maven.xwiki.org/releases/` and `/externals/` to inspect the
  dependency tree before touching the build (no local Maven needed).
