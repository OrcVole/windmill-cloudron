#!/bin/bash
set -euo pipefail

# Cloudron restoreCommand. Runs in a TEMPORARY container after Cloudron has restored /app/data from a
# backup, with the (empty) /app/pgdata persistentDir bind-mounted. It rebuilds a fresh PostgreSQL
# cluster from the logical dump that backup.sh placed in /app/data, so the app then starts on a
# clean, consistent data directory (never a torn filesystem copy).

DATA=/app/data
PGROOT=/app/pgdata
PGDATA="${PGROOT}/16"
PG_BIN=/usr/lib/postgresql/16/bin
DUMP="${DATA}/pgdump/cluster.sql.gz"
DB_ENV="${DATA}/.secrets/db.env"
LOG="${DATA}/pgdump/restore.log"

echo "==> [restore] rebuilding PostgreSQL from logical dump"
if [[ ! -s "${DUMP}" ]]; then
  echo "==> [restore] no dump at ${DUMP}; leaving PGDATA empty (start.sh will init a fresh cluster)"
  exit 0
fi

mkdir -p "${PGROOT}"; chown -R cloudron:cloudron "${PGROOT}"; chmod 0700 "${PGROOT}"
if [[ -s "${PGDATA}/PG_VERSION" ]]; then
  echo "==> [restore] PGDATA already populated; not overwriting"
  exit 0
fi

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

gosu cloudron:cloudron "${PG_BIN}/pg_ctl" -D "${PGDATA}" -w -t 60 -m fast stop
echo "==> [restore] PGDATA rebuilt; app will start on the restored cluster"
