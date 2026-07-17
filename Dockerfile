# XWiki packaged for Cloudron.
#
# We build on top of the official XWiki image (Tomcat + PostgreSQL flavour). Pin
# to a concrete version tag when you want reproducible builds / controlled
# upgrades; "stable-postgres-tomcat" always tracks the latest stable release.
#
# PostgreSQL is used instead of MySQL on purpose: XWiki's MySQL migration needs
# the global PROCESS privilege that Cloudron's isolated MySQL addon does not
# grant. With PostgreSQL the app user owns its database and XWiki initializes
# with no manual database steps.
FROM xwiki:stable-postgres-tomcat

# --- Adapt the image to Cloudron's read-only root filesystem --------------------
# At runtime Cloudron mounts only /tmp, /run and /app/data as writable. XWiki
# needs to write to the Tomcat tree (logs, work, temp, and its WEB-INF config)
# and to its permanent directory. We therefore move the baked distribution aside
# under /app/pkg and symlink the runtime paths into the persistent /app/data
# volume. start.sh populates /app/data on first boot.
RUN mkdir -p /app/pkg /app/code && \
    mv /usr/local/tomcat /app/pkg/tomcat-dist && \
    mv /usr/local/xwiki  /app/pkg/xwiki-dist && \
    ln -s /app/data/tomcat /usr/local/tomcat && \
    ln -s /app/data/xwiki  /usr/local/xwiki && \
    # Record the XWiki version baked into this image so start.sh can detect
    # upgrades and reseed the webapp while preserving data + database.
    printf '%s\n' "${XWIKI_VERSION}" > /app/pkg/xwiki.version

COPY start.sh /app/code/start.sh
RUN chmod +x /app/code/start.sh

# The default WORKDIR of the base image is /usr/local/tomcat, which is now a
# dangling symlink until /app/data is seeded - move it somewhere that exists.
WORKDIR /app/code

CMD [ "/app/code/start.sh" ]
