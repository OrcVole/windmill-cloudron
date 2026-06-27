#!/bin/bash
set -euo pipefail

# Cloudron backupCommand. Runs in a TEMPORARY container built from the app image, with /app/data and
# the /app/pgdata persistentDir bind-mounted. Produces a consistent logical dump of the bundled
# PostgreSQL into /app/data so Cloudron captures it in the filesystem backup (PGDATA itself is a
# persistentDir and is NOT file-copied — avoiding the torn hot-copy of a running data directory).
#
# The main app may still be live during backup: prefer dumping the live server via the socket inside
# the (shared) persistentDir; only start a transient server if none is reachable.

DATA=/app/data
PGROOT=/app/pgdata
PGDATA="${PGROOT}/16"
PG_BIN=/usr/lib/postgresql/16/bin
DUMP_DIR="${DATA}/pgdump"
DUMP="${DUMP_DIR}/cluster.sql.gz"
TMP="${DUMP_DIR}/.cluster.sql.gz.partial"

echo "==> [backup] logical dump starting"
mkdir -p "${DUMP_DIR}"; chown cloudron:cloudron "${DUMP_DIR}"

if [[ ! -s "${PGDATA}/PG_VERSION" ]]; then
  echo "==> [backup] no PostgreSQL cluster yet (fresh app); nothing to dump"
  exit 0
fi

chown -R cloudron:cloudron "${PGROOT}" 2>/dev/null || true

started_transient=0
if gosu cloudron:cloudron "${PG_BIN}/pg_isready" -h "${PGROOT}" -p 5432 >/dev/null 2>&1; then
  echo "==> [backup] live server reachable via socket; dumping online (MVCC-consistent)"
else
  echo "==> [backup] no live server reachable; starting a transient server on the data dir"
  rm -f "${PGDATA}/postmaster.pid" 2>/dev/null || true
  gosu cloudron:cloudron "${PG_BIN}/pg_ctl" -D "${PGDATA}" -w -t 120 \
    -o "-c listen_addresses='' -k ${PGROOT}" start
  started_transient=1
fi

stop_transient() { [[ "${started_transient}" == "1" ]] && gosu cloudron:cloudron "${PG_BIN}/pg_ctl" -D "${PGDATA}" -w -t 60 -m fast stop || true; }
trap stop_transient EXIT

# pg_dumpall captures global roles (windmill_admin / windmill_user) AND every database with data.
( set -o pipefail; gosu cloudron:cloudron "${PG_BIN}/pg_dumpall" -h "${PGROOT}" -p 5432 -U cloudron | gzip -c > "${TMP}" )
mv -f "${TMP}" "${DUMP}"
chown cloudron:cloudron "${DUMP}"; chmod 0600 "${DUMP}"
echo "==> [backup] wrote ${DUMP} ($(du -h "${DUMP}" | cut -f1)) — included in this backup"
echo "==> [backup] done"
