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
LDAP_JARS_DIST=/app/pkg/ldap-jars.list
LDAP_JARS_DATA=/app/data/ldap-jars.list

IMAGE_VERSION="$(cat /app/pkg/xwiki.version)"
IMAGE_UPSTREAM_VERSION="$(cat /app/pkg/xwiki-upstream.version)"
DATA_VERSION_FILE=/app/data/xwiki.version
DATA_UPSTREAM_VERSION_FILE=/app/data/xwiki-upstream.version

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
    cp -a "${LDAP_JARS_DIST}" "${LDAP_JARS_DATA}"
}

# Refresh only the baked LDAP dependency jars in WEB-INF/lib, without touching
# anything else there. Used for packaging-only releases (XWiki itself
# unchanged) - never do a full Tomcat wipe for these, since that would also
# delete any extension XWiki's own Extension Manager installed directly into
# WEB-INF/lib at runtime (e.g. CKEditor Integration and its webjar
# dependencies), which do not come from our baked distribution and would be
# gone for good. This is how a fix like "exclude org.apache.tika" (3.0.2)
# reaches an existing install without collateral damage.
sync_ldap_jars() {
    local lib="${WEBINF}/lib"
    if [[ -f "${LDAP_JARS_DATA}" ]]; then
        while IFS= read -r jar; do
            [[ -n "${jar}" ]] || continue
            grep -qxF "${jar}" "${LDAP_JARS_DIST}" 2>/dev/null || rm -f "${lib}/${jar}"
        done < "${LDAP_JARS_DATA}"
    fi
    while IFS= read -r jar; do
        [[ -n "${jar}" ]] || continue
        cp -a "${DIST_TOMCAT}/webapps/ROOT/WEB-INF/lib/${jar}" "${lib}/${jar}"
    done < "${LDAP_JARS_DIST}"
    cp -a "${LDAP_JARS_DIST}" "${LDAP_JARS_DATA}"
}

# ---- 1. Seed / upgrade the Tomcat + XWiki webapp -------------------------------
if [[ ! -d "${DATA_TOMCAT}" ]]; then
    echo "==> First run: seeding XWiki webapp v${IMAGE_VERSION} into /app/data"
    seed_tomcat
    echo "${IMAGE_VERSION}" > "${DATA_VERSION_FILE}"
    echo "${IMAGE_UPSTREAM_VERSION}" > "${DATA_UPSTREAM_VERSION_FILE}"
elif [[ ! -f "${DATA_UPSTREAM_VERSION_FILE}" ]]; then
    # Upgrading from a release that predates the split-marker scheme (<= 3.0.3):
    # we have no record of which upstream XWiki version was last seeded. The
    # base image tag has not actually changed across our recent releases, so
    # backfill the marker as "unchanged" rather than assuming an upstream bump
    # - a full reseed here would immediately re-delete any extensions that
    # were just reinstalled to recover from the 3.0.3 incident. Still apply the
    # normal packaging-only sync below if our own version has moved on.
    echo "==> Migrating to the split version-marker scheme (assuming upstream XWiki unchanged)"
    echo "${IMAGE_UPSTREAM_VERSION}" > "${DATA_UPSTREAM_VERSION_FILE}"
    if [[ "$(cat "${DATA_VERSION_FILE}" 2>/dev/null || true)" != "${IMAGE_VERSION}" ]]; then
        sync_ldap_jars
        echo "${IMAGE_VERSION}" > "${DATA_VERSION_FILE}"
    fi
elif [[ "$(cat "${DATA_UPSTREAM_VERSION_FILE}")" != "${IMAGE_UPSTREAM_VERSION}" ]]; then
    echo "==> XWiki upgrade detected: reseeding webapp to v${IMAGE_UPSTREAM_VERSION} (permanent data + database are preserved)"
    seed_tomcat
    echo "${IMAGE_VERSION}" > "${DATA_VERSION_FILE}"
    echo "${IMAGE_UPSTREAM_VERSION}" > "${DATA_UPSTREAM_VERSION_FILE}"
elif [[ "$(cat "${DATA_VERSION_FILE}" 2>/dev/null || true)" != "${IMAGE_VERSION}" ]]; then
    echo "==> Packaging update detected (XWiki itself unchanged): refreshing baked LDAP dependency jars only"
    sync_ldap_jars
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

# ---- 4. Wire XWiki authentication to the Cloudron LDAP directory ---------------
# The Cloudron `ldap` addon injects CLOUDRON_LDAP_* pointing at an internal,
# plaintext LDAP server scoped to this app. We (re)write the LDAP block of
# xwiki.cfg on every boot so it always reflects the current addon credentials
# and survives XWiki upgrades. The LDAP Authenticator JARs are baked into the
# image (see Dockerfile). trylocal=1 keeps the local admin (created by the setup
# wizard) usable alongside LDAP logins.
configure_ldap() {
    local cfg="${WEBINF}/xwiki.cfg"
    [[ -f "${cfg}" ]] || return 0
    if [[ -z "${CLOUDRON_LDAP_HOST:-}" ]]; then
        echo "==> LDAP addon env not present - skipping LDAP configuration"
        return 0
    fi
    echo "==> Configuring XWiki authentication against the Cloudron LDAP directory"
    local keys=(
        xwiki.authentication.authclass
        xwiki.authentication.ldap
        xwiki.authentication.ldap.trylocal
        xwiki.authentication.ldap.ssl
        xwiki.authentication.ldap.server
        xwiki.authentication.ldap.port
        xwiki.authentication.ldap.base_DN
        xwiki.authentication.ldap.bind_DN
        xwiki.authentication.ldap.bind_pass
        xwiki.authentication.ldap.UID_attr
        xwiki.authentication.ldap.user_search_fmt
        xwiki.authentication.ldap.fields_mapping
        xwiki.authentication.ldap.update_user
    )
    # Strip any existing (commented or active) occurrences to avoid duplicates.
    local k kre
    for k in "${keys[@]}"; do
        kre="${k//./\\.}"
        sed -i "/^#\{0,1\}[[:space:]]*${kre}[[:space:]]*=/d" "${cfg}"
    done
    # Append a clean, managed block. Values are written literally (no shell/sed
    # interpolation) so DNs, commas and generated passwords are safe.
    {
        echo "# --- Managed by start.sh: Cloudron LDAP integration (do not edit) ---"
        echo "xwiki.authentication.authclass=org.xwiki.contrib.ldap.XWikiLDAPAuthServiceImpl"
        echo "xwiki.authentication.ldap=1"
        echo "xwiki.authentication.ldap.trylocal=1"
        echo "xwiki.authentication.ldap.ssl=0"
        echo "xwiki.authentication.ldap.server=${CLOUDRON_LDAP_HOST}"
        echo "xwiki.authentication.ldap.port=${CLOUDRON_LDAP_PORT}"
        echo "xwiki.authentication.ldap.base_DN=${CLOUDRON_LDAP_USERS_BASE_DN}"
        echo "xwiki.authentication.ldap.bind_DN=${CLOUDRON_LDAP_BIND_DN}"
        echo "xwiki.authentication.ldap.bind_pass=${CLOUDRON_LDAP_BIND_PASSWORD}"
        echo "xwiki.authentication.ldap.UID_attr=username"
        echo "xwiki.authentication.ldap.user_search_fmt=(&(objectclass=user)(|(username={1})(mail={1})))"
        echo "xwiki.authentication.ldap.fields_mapping=last_name=sn,first_name=givenName,email=mail"
        echo "xwiki.authentication.ldap.update_user=1"
    } >> "${cfg}"
}
configure_ldap

# Give the JVM enough heap for XWiki. The container's hard memory limit is set
# separately in CloudronManifest.json (memoryLimit) and must stay comfortably
# above this heap size to leave room for LibreOffice + native memory.
export JAVA_OPTS="${JAVA_OPTS:-} -Xmx2048m"

echo "==> Starting XWiki (db=${DB_DATABASE} @ ${DB_HOST}:${CLOUDRON_POSTGRESQL_PORT})"
exec /usr/local/bin/docker-entrypoint.sh xwiki
