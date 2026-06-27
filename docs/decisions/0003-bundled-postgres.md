# 0003 — Bundle PostgreSQL instead of using the `postgresql` addon

**Status:** accepted (2026-06-27) — **empirically verified**

## Context

The foundation brief assumed the Cloudron `postgresql` addon with a privilege workaround. Research +
an empirical boot test overturned that assumption.

Windmill v1.741.0's unmodified CE binary requires **superuser-grade** PostgreSQL:

1. The first migration runs an **un-guarded** `CREATE EXTENSION "uuid-ossp" WITH SCHEMA extensions`
   (plus `CREATE SCHEMA extensions`). The addon *does* allowlist `uuid-ossp`, so this alone is
   solvable — but see (2).
2. Migrations create `windmill_admin WITH BYPASSRLS` and `windmill_user`, and the running app does
   `SET LOCAL ROLE windmill_admin` to enforce per-workspace Row-Level-Security. The Cloudron
   `postgresql` addon grants the app a single non-superuser database owner with **no `CREATEROLE`
   and no `BYPASSRLS`**, so those roles cannot exist and runtime `SET ROLE` fails.

The only two prior-art ways to use the addon are:
- **Embed PostgreSQL as superuser** (halecraft) — what we do, minus their EE-unlock fork.
- **Byte-patch the Windmill binary** to neutralise the role/RLS SQL (timconsidine) — which violates
  the Windmill CE license ("distribute as is, do not modify or wrap") **and** our rule #2
  ("never modify the binary"). Rejected.

## Decision

Bundle **PostgreSQL 16** inside the container:

- Installed from Ubuntu (`postgresql-16`, 16.14) on `cloudron/base`.
- Data directory `/app/data/postgresql/16`; socket in `/run/postgresql`; listens on `127.0.0.1` only.
- `start.sh` runs `initdb` once (idempotent), then transiently starts PG to create a **superuser
  role `windmill`** (generated password kept in `/app/data/.secrets/db.env`, 0600) and the
  `windmill` database, then stops it. Supervisor runs PG for real alongside Windmill.
- `DATABASE_URL=postgres://windmill:****@127.0.0.1:5432/windmill?sslmode=disable`.

## Verification (this is not theoretical)

A Cloudron-style local run (read-only rootfs, tmpfs `/run`+`/tmp`, `/app/data` volume) showed **all
~hundreds of migrations applying cleanly**, including `uuid-ossp`, the `BYPASSRLS` roles, and the
final live migration, followed by `server started on port=8001`. Default-credential login returned a
superadmin token. The second boot took the idempotent path (no reseed).

## Consequences

- **Backups**: all Windmill state (incl. workspace encryption keys and the auto-generated
  `jwt_secret`, both stored in Postgres) rides Cloudron's `/app/data` backup. We rely on PostgreSQL's
  crash recovery for snapshot consistency (the standard pattern for a bundled DB, as field guide §1
  sanctions when no addon can serve the app).
- **Size/memory**: a PostgreSQL server adds to the image and RAM footprint; `memoryLimit` default is
  3 GiB. Documented for operators.
- **No `postgresql` addon** is declared in the manifest. If a future Windmill release relaxes its
  privilege needs, revisit (the addon would be the lighter option).
