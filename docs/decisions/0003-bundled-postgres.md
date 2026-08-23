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

## Backup strategy (added 1.0.1) — a bundled Postgres needs a logical dump, not a file copy

Cloudron's filesystem backup copies `/app/data` **live and non-atomically** (tgz/rsync; the app is
not quiesced). File-copying a **running** Postgres data directory is exactly what PostgreSQL's docs
call unsafe — torn pages and WAL/data-file skew can make the copy unrecoverable. So the original 1.0.0
design (PGDATA under `/app/data`, relying on the file copy) was **not** a safe backup.

Fixed with Cloudron's purpose-built trio (all require `minBoxVersion 9.1.0`):

- **`persistentDirs: ["/app/pgdata"]`** — PGDATA lives here. persistentDirs survive updates but are
  **excluded from the filesystem backup**, so the running data dir is never torn-copied.
- **`backupCommand: /app/code/backup.sh`** — Cloudron runs it (in a temp container with `/app/data` +
  the persistentDir mounted) **at backup time**. It produces a consistent `pg_dumpall` (roles + all
  DBs) into `/app/data/pgdump/cluster.sql.gz` (atomic rename), so the dump is fresh — **no staleness
  window**. The main app may be live during backup; `backup.sh` prefers dumping the live server over
  the socket in the (shared) persistentDir, and only starts a transient server if none is reachable.
- **`restoreCommand: /app/code/restore.sh`** — on restore-into-fresh, `/app/data` (with the dump) is
  restored while the persistentDir starts **empty**; `restore.sh` rebuilds PGDATA from the dump before
  the app starts. No "is this a restore?" detection is needed — the empty persistentDir *is* the
  signal.

**Verified locally** (temp-container simulation of Cloudron's exact lifecycle): a workspace + a
variable survived backup → restore onto a **fresh** PGDATA volume, Postgres came up clean. The
on-box throwaway gate (install → state → `cloudron backup create` → restore-into-fresh, repeated)
is the remaining confirmation.

**Migration**: existing 1.0.0 installs had PGDATA at `/app/data/postgresql/16`. `start.sh` moves it
to `/app/pgdata/16` once, on first boot of 1.0.1, so no data is lost and no fresh cluster is created.

## Postgres major-version lifecycle (added 1.0.1)

Bundling Postgres means we own `pg_upgrade`. `start.sh` reads `PGDATA/PG_VERSION`; if it does not
match the bundled server major (16), it **fails loud and refuses to start** with operator guidance —
never silently initialising a new cluster over old data. A future 16→17 bump must ship a `pg_upgrade`
step (or restore-from-dump, which is version-portable because it's logical). Documented for operators.

## Memory (added 1.0.1)

Postgres, the Windmill server, and the worker processes share one Cloudron `memoryLimit`; an OOM can
take the DB down with the app. `shared_buffers` is set conservatively (192 MB) and `work_mem` low
(8 MB) relative to the 3 GiB default, and the worker count (ADR 0001) is derived from the memory limit
so PG always keeps headroom; `POSTINSTALL.md` documents a 2 GB floor / 3 GB recommended.
