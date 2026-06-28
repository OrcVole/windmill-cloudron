#!/bin/bash
set -euo pipefail

# ==========================================================================================
# Windmill on Cloudron — entrypoint.
# Runs as root for setup, then hands the long-running processes to supervisor (each dropping
# to the unprivileged `cloudron` user).
#
# State:
#   /app/pgdata        — PostgreSQL data dir (a Cloudron persistentDir: survives updates, is
#                        EXCLUDED from the filesystem backup; backed up logically via backup.sh).
#   /app/data          — secrets, dependency caches, and the logical PG dump (backed up).
# See docs/decisions/0003-bundled-postgres.md.
# ==========================================================================================

CODE=/app/code
DATA=/app/data
PGROOT=/app/pgdata
PGDATA="${PGROOT}/16"
PGSOCKET="${PGROOT}"          # socket inside the persistentDir so the backup temp-container can reach a live server
PG_BIN=/usr/lib/postgresql/16/bin
PG_MAJOR=16
OLD_PGDATA="${DATA}/postgresql/16"   # pre-1.0.1 location (migrated below)
SECRETS_DIR="${DATA}/.secrets"
DB_ENV="${SECRETS_DIR}/db.env"
VERSION="${WINDMILL_VERSION:-unknown}"

echo "==> [start] Windmill ${VERSION} booting"

# ------------------------------------------------------------------------------------------
# 1. Layout + ownership. A restore can reset both, so assert on every boot.
# ------------------------------------------------------------------------------------------
mkdir -p \
  "${PGROOT}" "${SECRETS_DIR}" "${DATA}/pgdump" \
  "${DATA}/cache/uv" "${DATA}/cache/py_runtime" "${DATA}/cache/go" "${DATA}/cache/gopath" \
  "${DATA}/cache/deno" "${DATA}/cache/bun" "${DATA}/cache/rustup" "${DATA}/cache/cargo" \
  "${DATA}/cache/npm" "${DATA}/logs"
mkdir -p /run/nginx/body /run/nginx/proxy /run/nginx/fastcgi /run/nginx/scgi /run/nginx/uwsgi
chown -R cloudron:cloudron "${DATA}" "${PGROOT}" /run/nginx
chmod 0700 "${SECRETS_DIR}" "${PGROOT}"

# ------------------------------------------------------------------------------------------
# 1b. One-time migration of the bundled DB from the old /app/data location (pre-1.0.1) into the
#     persistentDir, so existing installs are not re-initialised over a fresh cluster.
# ------------------------------------------------------------------------------------------
if [[ ! -s "${PGDATA}/PG_VERSION" && -s "${OLD_PGDATA}/PG_VERSION" ]]; then
  echo "==> [start] migrating existing PostgreSQL cluster ${OLD_PGDATA} -> ${PGDATA}"
  mv "${OLD_PGDATA}" "${PGDATA}"
  rmdir "${DATA}/postgresql" 2>/dev/null || true
  chown -R cloudron:cloudron "${PGDATA}"
fi

# ------------------------------------------------------------------------------------------
# 1c. Postgres major-version guard (we now own pg_upgrade — never silently re-init over old data).
# ------------------------------------------------------------------------------------------
if [[ -s "${PGDATA}/PG_VERSION" ]]; then
  have="$(cat "${PGDATA}/PG_VERSION")"
  if [[ "${have}" != "${PG_MAJOR}" ]]; then
    echo "==> [start] FATAL: PGDATA is PostgreSQL ${have} but this image bundles ${PG_MAJOR}."
    echo "==> [start] A pg_upgrade is required. Restore from a backup taken with the matching"
    echo "==> [start] version, or run pg_upgrade manually in 'cloudron debug'. Refusing to start."
    exit 1
  fi
fi

# ------------------------------------------------------------------------------------------
# 2. First-run-only secrets (idempotent; never reseeded — a reseed would orphan the DB).
# ------------------------------------------------------------------------------------------
if [[ ! -f "${DB_ENV}" ]]; then
  echo "==> [start] first run: generating database password"
  ( umask 077; printf 'WINDMILL_DB_PASSWORD=%s\n' "$(openssl rand -hex 24)" > "${DB_ENV}" )
fi
chown cloudron:cloudron "${DB_ENV}"; chmod 0600 "${DB_ENV}"
# shellcheck source=/dev/null
set -a; . "${DB_ENV}"; set +a

# ------------------------------------------------------------------------------------------
# 3. Bundled PostgreSQL: initialise once (true first install only — a restore is pre-populated by
#    restore.sh), then bootstrap the Windmill superuser role + DB. Windmill REQUIRES a superuser
#    connection (CREATE EXTENSION uuid-ossp, CREATE ROLE windmill_admin WITH BYPASSRLS, SET ROLE)
#    which the Cloudron postgresql addon cannot provide.
# ------------------------------------------------------------------------------------------
if [[ ! -s "${PGDATA}/PG_VERSION" ]]; then
  echo "==> [start] initializing fresh PostgreSQL cluster"
  gosu cloudron:cloudron "${PG_BIN}/initdb" --pgdata="${PGDATA}" \
    --username=cloudron --auth-local=trust --auth-host=scram-sha-256 --encoding=UTF8 >/dev/null
fi

# Re-assert PG config every boot (listen localhost only; socket in the persistentDir).
cat > "${PGDATA}/postgresql.conf" <<EOF
data_directory = '${PGDATA}'
hba_file = '${PGDATA}/pg_hba.conf'
ident_file = '${PGDATA}/pg_ident.conf'
listen_addresses = '127.0.0.1'
port = 5432
unix_socket_directories = '${PGSOCKET}'
max_connections = 200
shared_buffers = 192MB
work_mem = 8MB
maintenance_work_mem = 128MB
dynamic_shared_memory_type = posix
log_destination = 'stderr'
logging_collector = off
EOF
cat > "${PGDATA}/pg_hba.conf" <<EOF
local   all   all                  trust
host    all   all   127.0.0.1/32   scram-sha-256
host    all   all   ::1/128        scram-sha-256
EOF
chown -R cloudron:cloudron "${PGDATA}"

echo "==> [start] bootstrapping Windmill role + database (transient PostgreSQL)"
gosu cloudron:cloudron "${PG_BIN}/pg_ctl" -D "${PGDATA}" -w -t 60 \
  -o "-c listen_addresses=127.0.0.1 -p 5432 -k ${PGSOCKET}" start
for i in $(seq 1 30); do
  gosu cloudron:cloudron "${PG_BIN}/pg_isready" -h "${PGSOCKET}" -p 5432 >/dev/null 2>&1 && break || sleep 1
done

PSQL=("${PG_BIN}/psql" -v ON_ERROR_STOP=1 -h "${PGSOCKET}" -p 5432 -U cloudron -d postgres -tAc)
if [[ "$(gosu cloudron:cloudron "${PSQL[@]}" "SELECT 1 FROM pg_roles WHERE rolname='windmill'")" != "1" ]]; then
  gosu cloudron:cloudron "${PG_BIN}/psql" -v ON_ERROR_STOP=1 -h "${PGSOCKET}" -p 5432 -U cloudron -d postgres \
    -c "CREATE ROLE windmill WITH LOGIN SUPERUSER PASSWORD '${WINDMILL_DB_PASSWORD}';"
else
  gosu cloudron:cloudron "${PG_BIN}/psql" -v ON_ERROR_STOP=1 -h "${PGSOCKET}" -p 5432 -U cloudron -d postgres \
    -c "ALTER ROLE windmill WITH LOGIN SUPERUSER PASSWORD '${WINDMILL_DB_PASSWORD}';"
fi
if [[ "$(gosu cloudron:cloudron "${PSQL[@]}" "SELECT 1 FROM pg_database WHERE datname='windmill'")" != "1" ]]; then
  gosu cloudron:cloudron "${PG_BIN}/psql" -v ON_ERROR_STOP=1 -h "${PGSOCKET}" -p 5432 -U cloudron -d postgres \
    -c "CREATE DATABASE windmill WITH OWNER windmill;"
fi
gosu cloudron:cloudron "${PG_BIN}/pg_ctl" -D "${PGDATA}" -w -t 60 -m fast stop
echo "==> [start] PostgreSQL bootstrap complete"

# ------------------------------------------------------------------------------------------
# 4. Windmill runtime environment (mapped from Cloudron every boot; caches under /app/data).
# ------------------------------------------------------------------------------------------
export DATABASE_URL="postgres://windmill:${WINDMILL_DB_PASSWORD}@127.0.0.1:5432/windmill?sslmode=disable"
# MODE and PORT are set PER PROCESS in the supervisor units (server vs worker), never globally:
# a global PORT would make every worker try to bind 8001. We deliberately do NOT run
# MODE=standalone — upstream supports it for development only (one process, NUM_WORKERS pinned to 1).
# Instead we run the real split: one MODE=server process + N MODE=worker processes, the same
# topology Windmill ships in docker-compose, co-located in this single Cloudron container.
export BASE_URL="${CLOUDRON_APP_ORIGIN:-http://localhost:8000}"
export BASE_INTERNAL_URL="http://127.0.0.1:8001"
export RUST_LOG="${RUST_LOG:-info}"

export HOME="${DATA}"
export TMPDIR=/tmp
export UV_CACHE_DIR="${DATA}/cache/uv"
export UV_PYTHON_INSTALL_DIR="${DATA}/cache/py_runtime"
export UV_PYTHON_PREFERENCE=only-managed
export UV_TOOL_DIR=/usr/local/uv
export GOCACHE="${DATA}/cache/go"
export GOPATH="${DATA}/cache/gopath"
export DENO_DIR="${DATA}/cache/deno"
export BUN_INSTALL_CACHE_DIR="${DATA}/cache/bun"
export RUSTUP_HOME="${DATA}/cache/rustup"
export CARGO_HOME="${DATA}/cache/cargo"
export npm_config_cache="${DATA}/cache/npm"

# Outgoing email via the Cloudron sendmail addon → Windmill SMTP env (DB instance settings, if set,
# take precedence). The plain SMTP port has STARTTLS disabled, so disable TLS on the internal hop.
if [[ -n "${CLOUDRON_MAIL_SMTP_SERVER:-}" ]]; then
  export SMTP_HOST="${CLOUDRON_MAIL_SMTP_SERVER}"
  export SMTP_PORT="${CLOUDRON_MAIL_SMTP_PORT:-2525}"
  export SMTP_USERNAME="${CLOUDRON_MAIL_SMTP_USERNAME:-}"
  export SMTP_PASSWORD="${CLOUDRON_MAIL_SMTP_PASSWORD:-}"
  export SMTP_FROM="${CLOUDRON_MAIL_FROM:-noreply@${CLOUDRON_APP_DOMAIN:-localhost}}"
  export SMTP_DISABLE_TLS=true
fi

# ------------------------------------------------------------------------------------------
# 4b. Worker units. Windmill runs as one dedicated API-server process plus N dedicated worker
#     processes (the split upstream ships in docker-compose), NOT MODE=standalone. The worker
#     COUNT scales with the app's memory limit, reserving headroom for PostgreSQL + the server,
#     so an operator raises throughput simply by raising memory (Cloudron → Resources). The
#     server unit lives in supervisord.conf; the worker units are generated here into a writable
#     include dir so the count can vary per boot. WINDMILL_WORKER_COUNT overrides the math.
# ------------------------------------------------------------------------------------------
compute_worker_count() {
  if [[ "${WINDMILL_WORKER_COUNT:-}" =~ ^[1-9][0-9]*$ ]]; then
    echo "${WINDMILL_WORKER_COUNT}"; return
  fi
  local mem_bytes="${CLOUDRON_MEMORY_LIMIT:-}"
  if [[ ! "${mem_bytes}" =~ ^[0-9]+$ ]]; then
    mem_bytes="$(cat /sys/fs/cgroup/memory.max 2>/dev/null \
              || cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null || echo '')"
  fi
  # cgroup v2 'max' (unlimited) or anything unparseable → assume the documented 3 GiB default.
  [[ "${mem_bytes}" =~ ^[0-9]+$ ]] || mem_bytes=$((3 * 1024 * 1024 * 1024))
  local mem_mb=$(( mem_bytes / 1024 / 1024 ))
  local reserve_mb=1024    # PostgreSQL + server + nginx + headroom (always-on)
  local per_worker_mb=768  # per-worker peak budget
  local n=$(( (mem_mb - reserve_mb) / per_worker_mb ))
  (( n < 1 )) && n=1
  (( n > 6 )) && n=6        # past this, scale memory (or a real multi-node deploy), not in-box workers
  echo "${n}"
}
WORKER_COUNT="$(compute_worker_count)"

WM_SUPERVISOR_DIR=/run/windmill/supervisor.d
mkdir -p "${WM_SUPERVISOR_DIR}"
rm -f "${WM_SUPERVISOR_DIR}"/worker-*.conf
WM_PG_WAIT='until /usr/lib/postgresql/16/bin/pg_isready -h /app/pgdata -p 5432 >/dev/null 2>&1; do echo "==> [windmill] waiting for postgresql"; sleep 1; done'
for i in $(seq 1 "${WORKER_COUNT}"); do
  cat > "${WM_SUPERVISOR_DIR}/worker-${i}.conf" <<EOF
[program:windmill-worker-${i}]
priority=25
command=/bin/bash -c '${WM_PG_WAIT}; exec /app/code/windmill'
environment=MODE="worker",WORKER_GROUP="default"
user=cloudron
directory=${DATA}
autostart=true
autorestart=true
startsecs=10
stopsignal=TERM
stopwaitsecs=30
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
EOF
done

echo "==> [start] topology=server+${WORKER_COUNT}worker(s) server_port=8001 base_url=${BASE_URL}"
echo "==> [start] db_password $( [[ -s "${DB_ENV}" ]] && echo present || echo MISSING )  smtp $( [[ -n "${SMTP_HOST:-}" ]] && echo configured || echo unset )"

# ------------------------------------------------------------------------------------------
# 5. Hand off to supervisor (postgres + windmill-server + windmill-worker-N + nginx, each as the
#    cloudron user). Worker units were generated above into /run/windmill/supervisor.d.
# ------------------------------------------------------------------------------------------
exec /usr/bin/supervisord --configuration "${CODE}/supervisord.conf" --nodaemon
