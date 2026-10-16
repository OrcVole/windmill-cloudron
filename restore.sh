#!/bin/bash
set -euo pipefail

# Cloudron restoreCommand. Runs in a TEMPORARY container after Cloudron has restored /app/data from a
# backup, with the /app/pgdata persistentDir bind-mounted, while the app is stopped. It rebuilds a fresh
# PostgreSQL cluster from the logical dump that backup.sh placed in /app/data, so the app then starts on
# a clean, consistent data directory (never a torn filesystem copy).
#
# /app/pgdata is EMPTY only on a clone. On an in-place restore Cloudron leaves the persistentDir alone,
# and until 1.4.0 this script then kept the live cluster, so a restore rolled the database back by
# nothing (field guide #327; Batch 7 gate 3: 6 scripts after a restore of a 4-script backup). The live
# cluster is now moved to a dated quarantine, never deleted on the spot, and rebuilt from the dump.

DATA=/app/data
PGROOT=/app/pgdata
PGDATA="${PGROOT}/16"
PG_BIN=/usr/lib/postgresql/16/bin
DUMP="${DATA}/pgdump/cluster.sql.gz"
DB_ENV="${DATA}/.secrets/db.env"
LOG="${DATA}/pgdump/restore.log"

echo "==> [restore] rebuilding PostgreSQL from logical dump"
if [[ ! -s "${DUMP}" ]]; then
  echo "==> [restore] RESTORE NOT APPLIED to the database: the restored backup carries no dump at ${DUMP}."
  echo "==> [restore] The live cluster (if any) is kept; on a clone start.sh initialises a fresh one."
  exit 0
fi

mkdir -p "${PGROOT}"; chown -R cloudron:cloudron "${PGROOT}"; chmod 0700 "${PGROOT}"
quarantine=""
if [[ -s "${PGDATA}/PG_VERSION" ]]; then
  quarantine="${PGROOT}/quarantine-$(date -u +%Y%m%dT%H%M%SZ)"
  mv "${PGDATA}" "${quarantine}"
  echo "==> [restore] in-place restore: the live cluster was moved to ${quarantine} (kept 30 days);"
  echo "==> [restore] rebuilding from the backup's dump"
fi
# Quarantined clusters older than 30 days are removed.
find "${PGROOT}" -mindepth 1 -maxdepth 1 -type d -name 'quarantine-*' -mtime +30 -exec rm -rf {} + 2>/dev/null || true

gosu cloudron:cloudron "${PG_BIN}/initdb" --pgdata="${PGDATA}" \
  --username=cloudron --auth-local=trust --auth-host=scram-sha-256 --encoding=UTF8 >/dev/null
gosu cloudron:cloudron "${PG_BIN}/pg_ctl" -D "${PGDATA}" -w -t 120 \
  -o "-c listen_addresses='' -k ${PGROOT}" start
for i in $(seq 1 30); do
  gosu cloudron:cloudron "${PG_BIN}/pg_isready" -h "${PGROOT}" -p 5432 >/dev/null 2>&1 && break || sleep 1
done

# Replay roles + databases. ON_ERROR_STOP=0 tolerates "role cloudron already exists" (the fresh
# cluster's bootstrap superuser is re-declared by pg_dumpall).
set +e
gunzip -c "${DUMP}" | gosu cloudron:cloudron "${PG_BIN}/psql" -h "${PGROOT}" -p 5432 -U cloudron -d postgres \
  -v ON_ERROR_STOP=0 >"${LOG}" 2>&1
set -e

# Re-assert the windmill role password from the restored secret so the app can connect.
if [[ -s "${DB_ENV}" ]]; then
  # shellcheck source=/dev/null
  . "${DB_ENV}"
  gosu cloudron:cloudron "${PG_BIN}/psql" -h "${PGROOT}" -p 5432 -U cloudron -d postgres \
    -c "ALTER ROLE windmill WITH LOGIN SUPERUSER PASSWORD '${WINDMILL_DB_PASSWORD}';" >/dev/null
fi

# Verify the rebuild before trusting it: the windmill database must exist and hold its schema. A
# half-built cluster is worse than either version, so on failure put the live cluster back and fail
# the restore where the operator sees it.
tables=$(gosu cloudron:cloudron "${PG_BIN}/psql" -h "${PGROOT}" -p 5432 -U cloudron -d windmill -tAc \
  "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public'" 2>/dev/null || echo 0)
gosu cloudron:cloudron "${PG_BIN}/pg_ctl" -D "${PGDATA}" -w -t 60 -m fast stop
if [[ "${tables:-0}" -lt 10 ]]; then
  echo "==> [restore] FAILED: the rebuilt cluster has ${tables:-0} tables in windmill (see ${LOG})" >&2
  if [[ -n "${quarantine}" ]]; then
    mv "${PGDATA}" "${PGROOT}/failed-rebuild-$(date -u +%Y%m%dT%H%M%SZ)-$$"
    mv "${quarantine}" "${PGDATA}"
    echo "==> [restore] the live cluster was put back; the app keeps its current data" >&2
  fi
  exit 1
fi
echo "==> [restore] PGDATA rebuilt (${tables} tables in windmill); app will start on the restored cluster"
