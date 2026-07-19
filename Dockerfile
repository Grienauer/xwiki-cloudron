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

# ---------------------------------------------------------------------------
# Stage 1: resolve the LDAP Authenticator extension + its runtime dependencies.
# The extension is NOT bundled in XWiki since 8.3, so we fetch its JARs and drop
# them into WEB-INF/lib (the documented "manual install" method). We let Maven
# resolve the transitive set and exclude the XWiki platform/commons/rendering
# groups that already ship inside the base image, to avoid version conflicts.
# Also exclude org.apache.tika: ldap-authenticator pins xwiki-platform-oldcore
# to a very old version (10.11), which drags in an ancient Tika as a transitive
# dependency. Copying that ancient Tika jar alongside the base image's modern
# one splits the classpath (old TikaInputStream vs new ZipContainerDetector,
# or vice versa) and throws NoSuchMethodError on every attachment upload,
# since XWiki now runs Tika-based mimetype detection during upload validation.
# ---------------------------------------------------------------------------
FROM maven:3-eclipse-temurin-21 AS ldap
ARG LDAP_AUTHENTICATOR_VERSION=9.16.2
WORKDIR /build
RUN printf '%s\n' \
  '<project xmlns="http://maven.apache.org/POM/4.0.0">' \
  '  <modelVersion>4.0.0</modelVersion>' \
  '  <groupId>local</groupId>' \
  '  <artifactId>xwiki-ldap-deps</artifactId>' \
  '  <version>1</version>' \
  '  <packaging>pom</packaging>' \
  '  <repositories>' \
  '    <repository><id>xwiki-releases</id>' \
  '      <url>https://maven.xwiki.org/releases/</url></repository>' \
  '    <repository><id>xwiki-externals</id>' \
  '      <url>https://maven.xwiki.org/externals/</url></repository>' \
  '  </repositories>' \
  "  <dependencies><dependency>" \
  "    <groupId>org.xwiki.contrib.ldap</groupId>" \
  "    <artifactId>ldap-authenticator</artifactId>" \
  "    <version>${LDAP_AUTHENTICATOR_VERSION}</version>" \
  "  </dependency></dependencies>" \
  '</project>' > pom.xml && \
    mvn -q -B dependency:copy-dependencies \
      -DincludeScope=runtime \
      -DexcludeGroupIds=org.xwiki.platform,org.xwiki.commons,org.xwiki.rendering,org.apache.tika \
      -DoutputDirectory=/deps

# ---------------------------------------------------------------------------
# Stage 2: the actual Cloudron app image.
# ---------------------------------------------------------------------------
FROM xwiki:stable-postgres-tomcat

# Drop the LDAP Authenticator JARs into the webapp, skipping any artifact that is
# already present in the image (avoids shipping a conflicting duplicate version).
# Also record which jars we actually added, in /app/pkg/ldap-jars.list: start.sh
# uses this manifest to refresh only these specific files on a packaging-only
# release (see the reseed logic there), rather than wiping the whole WEB-INF/lib
# - which would also delete extensions XWiki's own Extension Manager installs
# directly into WEB-INF/lib at runtime (e.g. CKEditor Integration and its
# webjar dependencies).
COPY --from=ldap /deps /tmp/ldap-deps
RUN mkdir -p /app/pkg && \
    LIB=/usr/local/tomcat/webapps/ROOT/WEB-INF/lib && \
    : > /app/pkg/ldap-jars.list && \
    for j in /tmp/ldap-deps/*.jar; do \
      base="$(basename "$j")"; \
      stem="$(echo "$base" | sed -E 's/-[0-9].*$//')"; \
      if ls "$LIB" | grep -qE "^${stem}-[0-9]"; then \
        echo "skip (already present): $base"; \
      else \
        cp "$j" "$LIB/" && echo "added: $base" && echo "$base" >> /app/pkg/ldap-jars.list; \
      fi; \
    done && \
    rm -rf /tmp/ldap-deps

# --- Adapt the image to Cloudron's read-only root filesystem --------------------
# At runtime Cloudron mounts only /tmp, /run and /app/data as writable. XWiki
# needs to write to the Tomcat tree (logs, work, temp, and its WEB-INF config)
# and to its permanent directory. We therefore move the baked distribution aside
# under /app/pkg and symlink the runtime paths into the persistent /app/data
# volume. start.sh populates /app/data on first boot.
COPY CloudronManifest.json /tmp/CloudronManifest.json
RUN mkdir -p /app/pkg /app/code && \
    mv /usr/local/tomcat /app/pkg/tomcat-dist && \
    mv /usr/local/xwiki  /app/pkg/xwiki-dist && \
    ln -s /app/data/tomcat /usr/local/tomcat && \
    ln -s /app/data/xwiki  /usr/local/xwiki && \
    # Record two version markers so start.sh can tell apart two different kinds
    # of release and reseed accordingly (see start.sh):
    #   xwiki-upstream.version - just XWIKI_VERSION. Changes only when the base
    #     image itself moves to a new XWiki release. Triggers a FULL reseed
    #     (start.sh wipes and recopies the whole Tomcat tree), which is the only
    #     safe option when the underlying distribution changed.
    #   xwiki.version - XWIKI_VERSION plus our own CloudronManifest.json version.
    #     Changes on every release we ship, including packaging-only fixes where
    #     XWIKI_VERSION is unchanged (e.g. a WEB-INF/lib dependency fix like the
    #     Tika exclusion above). Triggers a TARGETED resync of just the baked
    #     LDAP jars (see ldap-jars.list above) - never a full wipe, since that
    #     would also delete extensions the Extension Manager installs directly
    #     into WEB-INF/lib at runtime (e.g. CKEditor Integration + its webjars).
    printf '%s\n' "${XWIKI_VERSION}" > /app/pkg/xwiki-upstream.version && \
    APP_VERSION="$(grep -o '"version"[[:space:]]*:[[:space:]]*"[^"]*"' /tmp/CloudronManifest.json | head -1 | sed -E 's/.*"([^"]+)"$/\1/')" && \
    printf '%s+%s\n' "${XWIKI_VERSION}" "${APP_VERSION}" > /app/pkg/xwiki.version && \
    rm /tmp/CloudronManifest.json

COPY start.sh /app/code/start.sh
RUN chmod +x /app/code/start.sh

# The default WORKDIR of the base image is /usr/local/tomcat, which is now a
# dangling symlink until /app/data is seeded - move it somewhere that exists.
WORKDIR /app/code

CMD [ "/app/code/start.sh" ]
