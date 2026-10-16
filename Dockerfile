# Windmill for Cloudron — thin packaging layer.
# We orchestrate the official Windmill Community Edition binary UNMODIFIED (license + AGENTS.md rule #2).
# Final stage is cloudron/base (platform tooling depends on it); the Windmill binary and its language
# runtimes are COPY'd, unmodified, from the official CE image. PostgreSQL is bundled (the Cloudron
# postgresql addon cannot grant Windmill the superuser/BYPASSRLS it requires — see docs/decisions/0003).

ARG WINDMILL_VERSION=1.837.0

# --- source of the unmodified upstream binary + runtimes ---
FROM ghcr.io/windmill-labs/windmill:1.837.0@sha256:661aa3e338be081812ef301a2be8defc50bd9d3c4dde89f8cd53a763e6452a74 AS windmill
# Deno, DEPRECATED: from 1.837 upstream ships it only in the full image (#11648) and no longer offers it
# for new scripts, and the Deno runtime itself ends development around October 2027 (announced
# 2026-10-09). Kept, at the same 2.2.1 as before, so existing installs' Deno scripts keep running
# after this update. Remove in a later release, announced ahead, once users have moved to Bun.
FROM ghcr.io/windmill-labs/windmill-full:1.837.0@sha256:002b5d313902b0b71d632e2ce7faa83e7f059df9a8d43a1c94d3b2d34b49ad50 AS windmill-full

# --- the Cloudron app image ---
FROM docker.io/cloudron/base:6.0.0@sha256:9bed4c8fa880645f8e669041ee28febe941481d00e9445e3e5a5483cb541d09b

ARG WINDMILL_VERSION
ENV WINDMILL_VERSION=${WINDMILL_VERSION}

# Bundled PostgreSQL 16 server. Ubuntu 26.04 (base 6) ships only PostgreSQL 18, and a PostgreSQL 18
# server cannot open an existing install's 16 data directory, so the server major stays 16, from the
# PostgreSQL project's own repository (PGDG), which builds 16 for 26.04. Same major and the same
# /usr/lib/postgresql/16/bin path as before: no data migration. The repository key is checked against
# PGDG's published fingerprint before it is trusted. Moving to 18 is a separate, deliberate change
# (pg_upgrade of every install's data), not part of a base move.
ARG PGDG_FINGERPRINT=B97B0AFCAA1A47F044F244A07FCC7D46ACCC4CF8
RUN set -eu; \
    apt-get update; \
    apt-get install -y --no-install-recommends gnupg; \
    curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc -o /usr/share/keyrings/pgdg.asc; \
    got="$(gpg --show-keys --with-colons /usr/share/keyrings/pgdg.asc | awk -F: '$1=="fpr"{print $10; exit}')"; \
    [ "$got" = "$PGDG_FINGERPRINT" ] || { echo "FATAL: PGDG key fingerprint $got"; exit 1; }; \
    echo "deb [signed-by=/usr/share/keyrings/pgdg.asc] https://apt.postgresql.org/pub/repos/apt resolute-pgdg main" \
      > /etc/apt/sources.list.d/pgdg.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends postgresql-16; \
    apt-get purge -y gnupg; apt-get autoremove -y; \
    rm -rf /var/lib/apt/lists/*; \
    /usr/lib/postgresql/16/bin/postgres --version

# Windmill binary + the language runtimes it needs, copied UNMODIFIED from the official CE image.
# Keep deno/bun at the paths Windmill probes by default (/usr/bin/{deno,bun}); pin the rest explicitly.
COPY --from=windmill /usr/src/app/windmill /app/code/windmill
COPY --from=windmill-full /usr/bin/deno    /usr/bin/deno
COPY --from=windmill /usr/bin/bun          /usr/bin/bun
COPY --from=windmill /usr/local/bin/uv     /usr/local/bin/uv
COPY --from=windmill /usr/local/go         /usr/local/go
COPY --from=windmill /usr/bin/wmill        /usr/local/bin/wmill

# Runtime path overrides Windmill reads, pinned so they never depend on PATH probing order.
ENV GO_PATH=/usr/local/go/bin/go \
    DENO_PATH=/usr/bin/deno \
    BUN_PATH=/usr/bin/bun \
    PATH=/usr/local/go/bin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Build-time linkage gate: the build fails here if the binary/runtimes do not resolve on the base.
RUN set -eux; \
    if ldd /app/code/windmill | grep -q 'not found'; then ldd /app/code/windmill; echo 'unresolved libs'; exit 1; fi; \
    /app/code/windmill version; \
    deno --version; \
    bun --version; \
    uv --version; \
    /usr/local/go/bin/go version; \
    /usr/lib/postgresql/16/bin/postgres --version

COPY start.sh backup.sh restore.sh supervisord.conf nginx.conf /app/code/
RUN chmod 0755 /app/code/start.sh /app/code/backup.sh /app/code/restore.sh

# CMD (never ENTRYPOINT — keeps Cloudron debug mode usable).
CMD [ "/app/code/start.sh" ]
