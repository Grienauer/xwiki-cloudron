# XWiki for Cloudron

A custom Cloudron package that runs the official [XWiki](https://www.xwiki.org)
Docker image (Tomcat + MySQL) inside Cloudron's managed environment. XWiki is
**not** in the Cloudron App Store (it has been a wishlist item since 2018), so
this is the supported way to run it with Cloudron backups, TLS and domain
handling.

## What's in this package

| File | Purpose |
|------|---------|
| `CloudronManifest.json` | App metadata, MySQL + localstorage + sendmail addons, 3 GB memory limit, port 8080 |
| `Dockerfile` | Builds on `xwiki:stable-mysql-tomcat`, relocates writable dirs for Cloudron's read-only rootfs |
| `start.sh` | Seeds `/app/data`, maps the Cloudron MySQL addon to XWiki's `DB_*` vars, handles version upgrades |
| `DESCRIPTION.md` | Store description text |
| `CloudronVersions.json` | Version catalog for the Community App installer (auto-updated by CI) |
| `CHANGELOG` | Per-version changelog shown in Cloudron |
| `logo.png` | App icon (referenced by `iconUrl`) |
| `.github/workflows/publish.yml` | Builds + pushes the image to ghcr.io and updates the catalog |
| `.dockerignore` | Keeps the build context small |

## Two ways to install

| | Community App (UI, no local CLI) | CLI |
|---|---|---|
| Where you build | GitHub Actions builds & pushes the image for you | On your Cloudron server |
| How you install | Paste one URL into the dashboard | `cloudron install` from this folder |
| Best when | You want a repeatable, UI-driven install/update | One-off, quick test |

Pick **Community App** if you want to avoid the CLI entirely (recommended). See below.

## Option A — Community App via the dashboard (recommended)

This is the "Add custom app → **Community App** (CloudronVersions.json URL)" box
in your Cloudron dashboard. It installs a **pre-built image from a registry** —
so the source on GitHub is not enough by itself; an image has to be built and
pushed, and a `CloudronVersions.json` catalog has to point at it. The included
GitHub Actions workflow does all of that automatically.

**One-time setup:**

1. Create a GitHub repo (e.g. `grienauer/xwiki-cloudron`) and push **all** the
   files in this folder to it, including `.github/workflows/publish.yml`.
2. The workflow runs on push to `main` (or manually via the Actions tab). It:
   - builds the image and pushes it to **GitHub Container Registry**
     (`ghcr.io/<owner>/xwiki-cloudron:<version>`),
   - regenerates `CloudronVersions.json` and commits it back.
3. Make the container image **public**: repo → *Packages* → `xwiki-cloudron` →
   *Package settings* → *Change visibility* → **Public**. (Cloudron pulls it
   anonymously.)
4. In the Cloudron dashboard: **Add custom app → Community App**, and paste:

   ```
   https://raw.githubusercontent.com/<owner>/xwiki-cloudron/main/CloudronVersions.json
   ```

   Then choose the location/domain and install. Future versions you publish
   appear as updates automatically.

> ⚠️ Adjust these to your actual repo before pushing: the repo owner/name in the
> URLs, and `iconUrl` / `packagerUrl` / `mediaLinks` in `CloudronManifest.json`
> (they currently assume `grienauer/xwiki-cloudron`).

## Option B — CLI (build on the server)

- SSH / API access to your Cloudron and a domain you can point at the app.
- The Cloudron CLI on your machine:

  ```bash
  sudo npm install -g cloudron
  cloudron login my.cloudron-domain.com
  ```

```bash
# from inside this folder
cloudron install --location wiki.your-domain.com
```

Cloudron uploads the folder, builds the image **on the server**, provisions a
MySQL database and starts the app.

> First boot builds the whole XWiki schema and can take several minutes. Follow
> it with `cloudron logs -f`. The app is reachable once you see Tomcat report the
> ROOT context has started. On first visit XWiki runs a short setup wizard where
> you create the admin user and choose which default flavor/extensions to install.

## Update / rebuild

```bash
cloudron update --app wiki.your-domain.com
```

To move to a newer XWiki release, either keep `stable-mysql-tomcat` (rebuild
picks up the latest) or pin an explicit tag in the `Dockerfile`, e.g.:

```dockerfile
FROM xwiki:17.10-mysql-tomcat
```

On the next start `start.sh` detects the version change, reseeds the webapp and
lets XWiki's Distribution Wizard migrate the database. **Your content, the
permanent directory and the database are preserved.** As always, take a backup
first (`cloudron update` does this automatically).

## Useful commands

```bash
cloudron logs -f                       # follow logs
cloudron exec                          # shell inside the container
# check the DB connection from inside the app:
cloudron exec -- mysql --user="$CLOUDRON_MYSQL_USERNAME" \
  --password="$CLOUDRON_MYSQL_PASSWORD" --host="$CLOUDRON_MYSQL_HOST" \
  "$CLOUDRON_MYSQL_DATABASE"
```

## How it works (design notes)

- **Read-only rootfs.** Cloudron only allows writes to `/tmp`, `/run` and
  `/app/data`. The Dockerfile moves the baked `/usr/local/tomcat` and
  `/usr/local/xwiki` to `/app/pkg/*-dist` and symlinks the runtime paths into
  `/app/data` (seeded on first boot). Everything under `/app/data` is included
  in Cloudron backups.
- **Database.** The Cloudron `mysql` addon exposes `CLOUDRON_MYSQL_*`. `start.sh`
  maps these to the `DB_USER` / `DB_PASSWORD` / `DB_DATABASE` / `DB_HOST`
  variables the official XWiki entrypoint consumes (host and port are folded
  into `DB_HOST`).
- **Config re-applied each boot.** Because Cloudron addon credentials can change
  across restarts, `start.sh` restores a pristine (placeholder) hibernate config
  and clears the entrypoint's first-start marker so the DB settings are
  re-written on every start.
- **Memory.** JVM heap is set to `-Xmx2048m`; the container limit is 3 GB
  (`memoryLimit` in the manifest) to leave room for LibreOffice and native
  memory. Raise both for large wikis. XWiki needs ~1 GB heap minimum.

## Known caveats

- **Collation.** XWiki recommends the `utf8mb4_bin` collation; the Cloudron
  MySQL addon provisions databases as `utf8mb4_unicode_ci`. XWiki runs fine on
  this, but page-name case handling is less strict. If you need binary collation
  you'd have to alter the database after creation.
- **Embedded Solr.** This package uses XWiki's embedded search index (stored in
  the permanent directory). For large wikis, XWiki recommends an external Solr;
  that would be a separate addon/container and is out of scope for v1.
- **No SSO wired up.** The Cloudron LDAP/OIDC addons are intentionally not
  enabled — XWiki has its own user management and LDAP/OIDC apps you can
  configure in-wiki. LDAP cannot be added to an already-installed app, so decide
  before install if you want to wire it in.
- **Icon.** No `icon` is bundled; add a 256x256 PNG and an `"icon": "logo.png"`
  line to the manifest if you want a custom store icon.

## Publishing to your own Cloudron App Store (optional)

For a repeatable, non-server build you can build locally and push to a registry:

```bash
docker login
cloudron build           # builds + pushes username/xwiki:<tag>
cloudron install --image username/xwiki:<tag> --location wiki.your-domain.com
```

See https://docs.cloudron.io/packaging/ for the full packaging reference.
