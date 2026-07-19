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
     dist (see "Reseed version markers" below).
  2. Maps `CLOUDRON_POSTGRESQL_*` → the `DB_*` vars the upstream entrypoint
     expects, and patches the hardcoded `:5432` in `hibernate.cfg.xml` to the
     addon's actual port.
  3. Clears the entrypoint's first-start marker so DB config is re-applied
     every boot (addon credentials can rotate across restarts).
  4. Rewrites a managed LDAP block in `xwiki.cfg` from `CLOUDRON_LDAP_*` env
     vars (idempotent: strips old managed lines first).
  5. `exec`s the upstream `docker-entrypoint.sh xwiki`.

## Critical invariant: the two reseed version markers

`start.sh` tracks **two** separate version markers, because a full wipe of
`/app/data/tomcat` and a targeted refresh have very different blast radii:

- `xwiki-upstream.version` — just `${XWIKI_VERSION}`, the base image's XWiki
  release. Changing this means the *upstream distribution itself* moved, so
  `start.sh` does a **full wipe-and-recopy** of `/app/data/tomcat` from the
  baked dist (`seed_tomcat`).
- `xwiki.version` — `${XWIKI_VERSION}+${CloudronManifest.json version}`.
  Changing this while `xwiki-upstream.version` stays the same means *only our
  own packaging* changed (e.g. a `WEB-INF/lib` dependency fix). `start.sh`
  then does a **targeted resync of just the baked LDAP jars**
  (`sync_ldap_jars`, driven by the `ldap-jars.list` manifest written in the
  Dockerfile) — it never wipes the rest of `WEB-INF/lib`.

Both are baked at build time under `/app/pkg/`, compared against copies
persisted under `/app/data/` from whenever the app was last seeded.

**Why the distinction matters:** a full wipe of `/app/data/tomcat` deletes
*anything* under `WEB-INF/lib`, including extensions XWiki's own Extension
Manager installs directly there at runtime (e.g. CKEditor Integration and its
webjar dependencies — these are not part of our baked distribution, so a full
wipe deletes them permanently). Two real incidents chain together here:

1. **v3.0.2** fixed a broken LDAP jar in `WEB-INF/lib` (see CHANGELOG), but
   back then there was only a single marker tracking `${XWIKI_VERSION}`,
   unchanged since v3.0.1 — so upgrading in-place never reseeded, and users
   kept hitting the bug on the "fixed" version.
2. **v3.0.3** fixed that marker to also include our own version. This worked
   — but it meant the *first real reseed this app had ever gone through*
   was a full wipe, which deleted the CKEditor/webjar extensions that had
   been silently surviving (by accident) across every prior "upgrade" that
   never actually reseeded. Editing any page broke (blank editor, 404s on
   `/webjars/...`), with no server-side exception — clean 404s for genuinely
   missing files.
3. **v3.0.4** split the single marker into the two above, so a packaging-only
   release like 3.0.2 reaches existing installs *without* touching anything
   in `WEB-INF/lib` beyond the specific LDAP jars we bake in ourselves.

**If you ever collapse these back into a single marker that triggers a full
wipe on every one of our own releases, this incident comes back** — and it
will keep recurring on every packaging-only release going forward, not just
once.

Corollary: a genuine upstream XWiki version bump *will* still fully wipe
`/app/data/tomcat`, and will still delete any Extension-Manager-installed
`WEB-INF/lib` extensions at that point — reinstall them afterward via
Administration → Extensions (or the Distribution Wizard). That's an inherent
limit of Cloudron's read-only rootfs adaptation, not something start.sh can
safely paper over (an old extension jar isn't guaranteed compatible with a
new XWiki core version anyway).

One more edge case worth knowing if you touch this logic again: upgrading
from a pre-3.0.4 release (single marker) has no persisted
`xwiki-upstream.version` to compare against. `start.sh` treats that as "assume
upstream unchanged" and backfills the marker rather than forcing a full wipe
— on the actual 3.0.3→3.0.4 transition the base image genuinely hadn't
changed, and defaulting to a full wipe here would immediately re-delete
whatever extensions were just reinstalled to recover from the 3.0.3 incident.

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
