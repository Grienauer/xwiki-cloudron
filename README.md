# XWiki for Cloudron

A custom Cloudron package that runs the official [XWiki](https://www.xwiki.org)
Docker image (Tomcat + PostgreSQL) inside Cloudron's managed environment. XWiki
is **not** in the Cloudron App Store (it has been a wishlist item since 2018), so
this is the supported way to run it with Cloudron backups, TLS and domain
handling.

> **Why PostgreSQL and not MySQL?** XWiki's MySQL schema migration queries
> `information_schema` InnoDB tables, which needs the global `PROCESS` privilege
> that Cloudron's isolated MySQL addon does not grant — so the MySQL variant
> fails on first boot unless you manually grant it as root. The PostgreSQL addon
> makes the app user the owner of its own database, so XWiki initializes with no
> manual database steps.

## What's in this package

| File | Purpose |
|------|---------|
| `CloudronManifest.json` | App metadata, PostgreSQL + ldap + localstorage + sendmail addons, 3 GB memory limit, port 8080 |
| `Dockerfile` | Multi-stage: bakes the LDAP Authenticator extension in, builds on `xwiki:stable-postgres-tomcat`, relocates writable dirs for Cloudron's read-only rootfs |
| `start.sh` | Seeds `/app/data`, maps the PostgreSQL addon to XWiki's `DB_*` vars, auto-configures LDAP from the `CLOUDRON_LDAP_*` vars, handles version upgrades |
| `DESCRIPTION.md` | Store description text |
| `CloudronVersions.json` | Version catalog for the Community App installer (auto-updated by CI) |
| `CHANGELOG` | Per-version changelog shown in Cloudron |
| `logo.png` | App icon (referenced by `iconUrl`) |
| `.github/workflows/publish.yml` | Builds + pushes the image to ghcr.io and updates the catalog |
| `.dockerignore` | Keeps the build context small |

## Install (recommended) — Community App via the dashboard

No CLI, no clone, no GitHub account of your own needed — this repo already
publishes a maintained image and version catalog. In your Cloudron dashboard:

1. **Add custom app → Community App**.
2Paste this **CloudronVersions.json URL**:

   ```
   https://raw.githubusercontent.com/grienauer/xwiki-cloudron/main/CloudronVersions.json
   ```

3. Choose the location/domain and install.

This catalog is regenerated automatically by this repo's GitHub Actions
workflow every time a new version ships, so future versions appear as updates
in the dashboard with no further action from you.

> First boot builds the whole XWiki schema and can take several minutes. Be patient, reload App. You can follow
> the status in the logs. The app is reachable once you see Tomcat report the
> ROOT context has started. On first visit XWiki runs a short setup wizard where
> you create the admin user and choose which default flavor/extensions to install.

## Alternative: CLI install with the pre-built image

Same published image, but installed via the Cloudron CLI instead of the
dashboard — no clone needed.

**1. Install the Cloudron CLI and log in:**

```bash
sudo npm install -g cloudron
cloudron login my.cloudron-domain.com
```

**2. Find the version tag you want.** Open the
[package page](https://github.com/grienauer/xwiki-cloudron/pkgs/container/xwiki-cloudron)
on GitHub — it lists every published version as a tag (e.g. `2.0.0`), newest
first. You can also just use `latest`. The same version list lives in this
repo's [`CHANGELOG`](CHANGELOG) if you want release notes per version.

**3. Install:**

```bash
cloudron install --image ghcr.io/grienauer/xwiki-cloudron:VERSION --location wiki.your-domain.com
```

Replace `VERSION` with the tag from step 2 (or `latest`). Cloudron pulls the
image, provisions a PostgreSQL database, and starts the app — no build step on
your machine or on the server.

### Update to a newer version

Find the new tag on the [package page](https://github.com/grienauer/xwiki-cloudron/pkgs/container/xwiki-cloudron), then:

```bash
cloudron update --app wiki.your-domain.com --image ghcr.io/grienauer/xwiki-cloudron:NEW_VERSION
```

On the next start `start.sh` detects the version change, reseeds the webapp and
lets XWiki's Distribution Wizard migrate the database. **Your content, the
permanent directory and the database are preserved.** As always, take a backup
first (`cloudron update` does this automatically).

## Alternative: run your own build (optional)

Only needed if you want to maintain your **own fork** — e.g. to customize the
package, publish under your own registry namespace, or get auto-discovered
updates in the Cloudron dashboard's **Community App** installer instead of
running `cloudron update` by hand.

**One-time setup:**

1. Clone this repo and push it to your own GitHub repo (e.g.
   `yourname/xwiki-cloudron`), including `.github/workflows/publish.yml`:

   ```bash
   git clone https://github.com/grienauer/xwiki-cloudron.git
   cd xwiki-cloudron
   git remote set-url origin git@github.com:yourname/xwiki-cloudron.git
   git push -u origin main
   ```

2. Adjust these to your repo before pushing: the repo owner/name in any URLs
   below, and `iconUrl` / `packagerUrl` / `mediaLinks` in
   `CloudronManifest.json` (they currently point at `grienauer/xwiki-cloudron`).
3. The workflow runs on push to `main` (or manually via the Actions tab). It:
   - builds the image and pushes it to **GitHub Container Registry**
     (`ghcr.io/<owner>/xwiki-cloudron:<version>`),
   - regenerates `CloudronVersions.json` and commits it back.
4. Make the container image **public**: repo → *Packages* → `xwiki-cloudron` →
   *Package settings* → *Change visibility* → **Public**. (Cloudron pulls it
   anonymously.)
5. In the Cloudron dashboard: **Add custom app → Community App**, and paste:

   ```
   https://raw.githubusercontent.com/<owner>/xwiki-cloudron/main/CloudronVersions.json
   ```

   Then choose the location/domain and install. Future versions you publish
   appear as updates automatically in the dashboard.

### Building on the Cloudron server instead

If you'd rather not use GitHub Actions at all, clone the repo and build
directly on your Cloudron server:

```bash
# from inside your clone of this repo
cloudron install --location wiki.your-domain.com
```

Cloudron uploads the folder and builds the image **on the server** instead of
pulling a pre-built one.

## Authentication (LDAP / Cloudron users)

This package authenticates XWiki against the **Cloudron user directory** using
the Cloudron `ldap` addon — no manual LDAP setup, no TLS/IP-whitelisting.

How it works:

- The manifest enables the `ldap` addon, so Cloudron injects `CLOUDRON_LDAP_*`
  (an internal, plaintext LDAP endpoint scoped to this app).
- The **LDAP Authenticator** extension JARs are baked into the image at build
  time (Maven multi-stage → `WEB-INF/lib`).
- On every boot, `start.sh` writes a managed LDAP block into `xwiki.cfg`
  (authenticator class, server, port, base DN, bind DN/password, field mapping).
  Users log in with their Cloudron **username or email**; XWiki creates the
  account on first login and refreshes name/email each time.
- `trylocal=1` keeps local XWiki accounts working, so the admin created by the
  setup wizard still logs in.

> **Requires a fresh install.** Cloudron cannot add the `ldap` addon to an
> already-installed app, so moving from 2.x to 3.x is not an in-place upgrade —
> install the app fresh.

Restrict who can log in (optional): add an `xwiki.authentication.ldap.user_group`
line to the managed block in `start.sh` pointing at a Cloudron group DN under
`ou=groups,dc=cloudron`.

Troubleshoot: enable debug logging for `org.xwiki.contrib.ldap` via
Administration → Logging (or add it to `WEB-INF/classes/logback.xml`), then watch
`cloudron logs -f` during a login attempt.

If the logs show a "cannot load class `...XWikiLDAPAuthServiceImpl`" error, the
baked JAR set was incomplete — install **LDAP Authenticator** once from
Administration → Extensions (it resolves its own dependencies and persists in the
permanent directory), then restart. Tell me if that happens and I'll pin the
missing dependency in the Dockerfile.

## Useful commands

```bash
cloudron logs -f                       # follow logs
cloudron exec                          # shell inside the container
# check the DB connection from inside the app:
cloudron exec -- bash -c 'PGPASSWORD="$CLOUDRON_POSTGRESQL_PASSWORD" psql \
  -h "$CLOUDRON_POSTGRESQL_HOST" -p "$CLOUDRON_POSTGRESQL_PORT" \
  -U "$CLOUDRON_POSTGRESQL_USERNAME" -d "$CLOUDRON_POSTGRESQL_DATABASE"'
```

## How it works (design notes)

- **Read-only rootfs.** Cloudron only allows writes to `/tmp`, `/run` and
  `/app/data`. The Dockerfile moves the baked `/usr/local/tomcat` and
  `/usr/local/xwiki` to `/app/pkg/*-dist` and symlinks the runtime paths into
  `/app/data` (seeded on first boot). Everything under `/app/data` is included
  in Cloudron backups.
- **Database.** The Cloudron `postgresql` addon exposes `CLOUDRON_POSTGRESQL_*`.
  `start.sh` maps these to the `DB_USER` / `DB_PASSWORD` / `DB_DATABASE` /
  `DB_HOST` variables the official XWiki entrypoint consumes. The stock Postgres
  hibernate template hardcodes port `5432`; `start.sh` turns that into a
  placeholder and injects the addon's actual port, so any port works.
- **Config re-applied each boot.** Because Cloudron addon credentials can change
  across restarts, `start.sh` restores a pristine (placeholder) hibernate config
  and clears the entrypoint's first-start marker so the DB settings are
  re-written on every start.
- **LDAP.** The `ldap` addon exposes `CLOUDRON_LDAP_*`. The LDAP Authenticator
  extension is baked into `WEB-INF/lib`, and `start.sh` rewrites a managed LDAP
  block in `xwiki.cfg` each boot from those vars — so the config always tracks
  the current addon credentials and survives XWiki upgrades.
- **Memory.** JVM heap is set to `-Xmx2048m`; the container limit is 3 GB
  (`memoryLimit` in the manifest) to leave room for LibreOffice and native
  memory. Raise both for large wikis. XWiki needs ~1 GB heap minimum.

## Known caveats

- **Subwikis.** XWiki's multi-wiki feature needs to create additional
  schemas/databases, which the Cloudron-provisioned DB user is not allowed to do.
  A single main wiki works fully; subwikis do not.
- **Embedded Solr.** This package uses XWiki's embedded search index (stored in
  the permanent directory). For large wikis, XWiki recommends an external Solr;
  that would be a separate addon/container and is out of scope for v1.
- **No SSO wired up.** The Cloudron LDAP/OIDC addons are intentionally not
  enabled — XWiki has its own user management and LDAP/OIDC apps you can
  configure in-wiki. LDAP cannot be added to an already-installed app, so decide
  before install if you want to wire it in.
- **Icon.** No `icon` is bundled; add a 256x256 PNG and an `"icon": "logo.png"`
  line to the manifest if you want a custom store icon.

## More on packaging

For the full Cloudron packaging reference (building locally with
`cloudron build`, publishing to other registries, manifest options, etc.), see
https://docs.cloudron.io/packaging/.
