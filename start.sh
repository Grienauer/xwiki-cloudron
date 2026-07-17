#!/bin/bash
# ---------------------------------------------------------------------------
# Cloudron start script for XWiki (PostgreSQL flavour).
#
# Responsibilities:
#   1. Seed the persistent /app/data volume from the baked distribution on the
#      first run, and reseed the webapp (only) after an XWiki version bump.
#   2. Map the Cloudron PostgreSQL addon environment to the DB_* variables the
#      official XWiki entrypoint expects.
#   3. Re-apply the DB configuration on every boot (Cloudron addon credentials
#      can change across restarts) and hand off to the official entrypoint.
#
# Why PostgreSQL: XWiki's MySQL migration path queries information_schema InnoDB
# tables, which needs the global PROCESS privilege that Cloudron does not grant.
# The PostgreSQL path has no such requirement - the app user owns its own
# database and can create its schema, so XWiki initializes with no manual steps.
# ---------------------------------------------------------------------------
set -eu

DIST_TOMCAT=/app/pkg/tomcat-dist
DIST_XWIKI=/app/pkg/xwiki-dist
DATA_TOMCAT=/app/data/tomcat
DATA_XWIKI=/app/data/xwiki
WEBINF=${DATA_TOMCAT}/webapps/ROOT/WEB-INF
HIBERNATE_DIST=${DATA_TOMCAT}/hibernate.cfg.xml.dist

IMAGE_VERSION="$(cat /app/pkg/xwiki.version)"
DATA_VERSION_FILE=/app/data/xwiki.version

seed_tomcat() {
    rm -rf "${DATA_TOMCAT}"
    cp -a "${DIST_TOMCAT}" "${DATA_TOMCAT}"
    # The stock PostgreSQL hibernate template hardcodes the port as ":5432".
    # Cloudron's PostgreSQL addon may listen on a different port, so turn that
    # into a "replaceport" placeholder we substitute per-boot from the addon env.
    sed -i 's#replacecontainer:5432#replacecontainer:replaceport#' \
        "${WEBINF}/hibernate.cfg.xml"
    # Stash a pristine copy (still containing the replaceX placeholders) so we
    # can re-run the substitution on every boot.
    cp -a "${WEBINF}/hibernate.cfg.xml" "${HIBERNATE_DIST}"
}

# ---- 1. Seed / upgrade the Tomcat + XWiki webapp -------------------------------
if [[ ! -d "${DATA_TOMCAT}" ]]; then
    echo "==> First run: seeding XWiki webapp v${IMAGE_VERSION} into /app/data"
    seed_tomcat
    echo "${IMAGE_VERSION}" > "${DATA_VERSION_FILE}"
elif [[ "$(cat "${DATA_VERSION_FILE}" 2>/dev/null || true)" != "${IMAGE_VERSION}" ]]; then
    echo "==> Upgrade detected: reseeding webapp to v${IMAGE_VERSION} (permanent data + database are preserved)"
    seed_tomcat
    echo "${IMAGE_VERSION}" > "${DATA_VERSION_FILE}"
fi

# XWiki permanent directory (config, extensions, cache, search index).
if [[ ! -d "${DATA_XWIKI}" ]]; then
    echo "==> Seeding XWiki permanent directory into /app/data"
    cp -a "${DIST_XWIKI}" "${DATA_XWIKI}"
fi

# ---- 2. Map the Cloudron PostgreSQL addon to XWiki's DB_* variables ------------
export DB_USER="${CLOUDRON_POSTGRESQL_USERNAME}"
export DB_PASSWORD="${CLOUDRON_POSTGRESQL_PASSWORD}"
export DB_DATABASE="${CLOUDRON_POSTGRESQL_DATABASE}"
# The XWiki entrypoint substitutes DB_HOST for the host only; the port comes from
# our "replaceport" placeholder (see below), so DB_HOST must NOT include a port.
export DB_HOST="${CLOUDRON_POSTGRESQL_HOST}"

# ---- 3. Force re-configuration on every boot -----------------------------------
# Restore the placeholder hibernate config, inject the real port, and drop the
# first-start marker so the entrypoint re-applies the (possibly changed) creds.
if [[ -f "${HIBERNATE_DIST}" ]]; then
    cp -a "${HIBERNATE_DIST}" "${WEBINF}/hibernate.cfg.xml"
    sed -i "s#replaceport#${CLOUDRON_POSTGRESQL_PORT}#" "${WEBINF}/hibernate.cfg.xml"
fi
rm -f "${DATA_TOMCAT}/webapps/ROOT/.first_start_completed"

# Give the JVM enough heap for XWiki. The container's hard memory limit is set
# separately in CloudronManifest.json (memoryLimit) and must stay comfortably
# above this heap size to leave room for LibreOffice + native memory.
export JAVA_OPTS="${JAVA_OPTS:-} -Xmx2048m"

echo "==> Starting XWiki (db=${DB_DATABASE} @ ${DB_HOST}:${CLOUDRON_POSTGRESQL_PORT})"
exec /usr/local/bin/docker-entrypoint.sh xwiki
