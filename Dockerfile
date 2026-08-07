# Windmill for Cloudron — thin packaging layer.
# We orchestrate the official Windmill Community Edition binary UNMODIFIED (license + AGENTS.md rule #2).
# Final stage is cloudron/base (platform tooling depends on it); the Windmill binary and its language
# runtimes are COPY'd, unmodified, from the official CE image. PostgreSQL is bundled (the Cloudron
# postgresql addon cannot grant Windmill the superuser/BYPASSRLS it requires — see docs/decisions/0003).

ARG WINDMILL_VERSION=1.782.0

# --- source of the unmodified upstream binary + runtimes ---
FROM ghcr.io/windmill-labs/windmill:1.782.0@sha256:1e80963ad95abdb02752ad40f70920b99c4039e04e12d5690b547d868eeae0dd AS windmill

# --- the Cloudron app image ---
FROM cloudron/base:5.0.0@sha256:04fd70dbd8ad6149c19de39e35718e024417c3e01dc9c6637eaf4a41ec4e596c

ARG WINDMILL_VERSION
ENV WINDMILL_VERSION=${WINDMILL_VERSION}

# Bundled PostgreSQL 16 server (Ubuntu 24.04 ships 16.x in main).
RUN apt-get update \
    && apt-get install -y --no-install-recommends postgresql-16 \
    && rm -rf /var/lib/apt/lists/*

# Windmill binary + the language runtimes it needs, copied UNMODIFIED from the official CE image.
# Keep deno/bun at the paths Windmill probes by default (/usr/bin/{deno,bun}); pin the rest explicitly.
COPY --from=windmill /usr/src/app/windmill /app/code/windmill
COPY --from=windmill /usr/bin/deno         /usr/bin/deno
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
