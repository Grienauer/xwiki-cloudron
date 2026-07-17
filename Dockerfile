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
  '  </repositories>' \
  "  <dependencies><dependency>" \
  "    <groupId>org.xwiki.contrib.ldap</groupId>" \
  "    <artifactId>ldap-authenticator</artifactId>" \
  "    <version>${LDAP_AUTHENTICATOR_VERSION}</version>" \
  "  </dependency></dependencies>" \
  '</project>' > pom.xml && \
    mvn -q -B dependency:copy-dependencies \
      -DincludeScope=runtime \
      -DexcludeGroupIds=org.xwiki.platform,org.xwiki.commons,org.xwiki.rendering \
      -DoutputDirectory=/deps

# ---------------------------------------------------------------------------
# Stage 2: the actual Cloudron app image.
# ---------------------------------------------------------------------------
FROM xwiki:stable-postgres-tomcat

# Drop the LDAP Authenticator JARs into the webapp, skipping any artifact that is
# already present in the image (avoids shipping a conflicting duplicate version).
COPY --from=ldap /deps /tmp/ldap-deps
RUN LIB=/usr/local/tomcat/webapps/ROOT/WEB-INF/lib && \
    for j in /tmp/ldap-deps/*.jar; do \
      base="$(basename "$j")"; \
      stem="$(echo "$base" | sed -E 's/-[0-9].*$//')"; \
      if ls "$LIB" | grep -qE "^${stem}-[0-9]"; then \
        echo "skip (already present): $base"; \
      else \
        cp "$j" "$LIB/" && echo "added: $base"; \
      fi; \
    done && \
    rm -rf /tmp/ldap-deps

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
