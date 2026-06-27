# Learnings — Windmill for Cloudron

A running log for four audiences, newest first. (a) operators, (b) other packagers,
(c) Cloudron maintainers, (d) Windmill developers.

## 2026-06-27

### (a) For operators
- Windmill here ships its **own bundled PostgreSQL** — you do **not** add the `postgresql` addon. All
  data (database + dependency caches) is under `/app/data` and backed up normally.
- After install, log in with `admin@windmill.dev` / `changeme` and **change the password first**.
- **Security**: native jobs (Python/TS/Go/Bash/SQL) work; Docker "container step" jobs and Windmill's
  nsjail sandbox do **not** (Cloudron is unprivileged). Treat it as single-tenant, trusted-author.
- Memory default is 3 GiB (Postgres + Windmill + a worker). Raise it for heavier workloads.

### (b) For other packagers — backup correctness (1.0.1)
- **A bundled database must NOT rely on Cloudron's filesystem backup.** Cloudron copies `/app/data`
  live and non-atomically; a hot copy of a running Postgres `PGDATA` is consistency-unsafe. Use the
  `persistentDirs` (exclude the live data dir from the file backup) + `backupCommand`/`restoreCommand`
  (`pg_dumpall` a logical dump into `/app/data` at backup time, rebuild on restore) trio — the
  `minBoxVersion 9.1.0` mechanism built for exactly this. The empty persistentDir on restore is itself
  the "this is a restore" signal, so no detection logic is needed.
- **`backupCommand` runs in a separate temp container** (app may be live). Put the Postgres socket
  inside the persistentDir so that temp container can dump the *live* server over the socket
  (MVCC-consistent) instead of risking a second postmaster on the same data dir.
- **Bundling a DB makes you the OOM and `pg_upgrade` owner**: Postgres shares the app's one memory
  limit (set `shared_buffers`/`work_mem` low; document a floor), and a PG major bump needs an explicit
  upgrade — guard `PG_VERSION` and fail loud rather than re-initialising over data.

### (b) For other packagers
- **Bundled PostgreSQL was the unlock.** Windmill needs superuser-grade PG (`CREATE EXTENSION
  uuid-ossp` unguarded, `CREATE ROLE … BYPASSRLS`, runtime `SET ROLE windmill_admin`). The Cloudron
  addon grants none of those. Your only license-clean option (no binary patching) is to bundle PG as
  superuser, data under `/app/data`. This is the field-guide "bundle-localhost-under-/app/data when
  no addon can serve the app" pattern (cf. Langfuse's ClickHouse/MinIO).
- **`MODE=standalone`** is the single-container lever (server + in-process worker). `NUM_WORKERS` is
  capped to 1 in standalone unless you set unsafe flags — don't; scale by memory.
- **Shape A still wins for a multi-runtime image** if the linkage gate is green: COPY the unmodified
  CE binary + self-contained runtimes (deno/bun/uv/go) onto `cloudron/base`, rather than `FROM` the
  3.9 GB CE image. The Windmill binary's deps are all stock glibc libs present on the base.
- **nginx-as-cloudron gotchas** (all three bit us in one session): one `daemon off;` only (conf *or*
  `-g`, not both); use the `error_log stderr` *keyword* (opening the `/dev/stderr` path fails as a
  non-root user under read-only rootfs); put the pid in a chowned dir (`/run/nginx/`, not `/run/`).
- **Liveness ≠ readiness in the smoke gate too**: `/health` (nginx) is 200 before migrations finish;
  poll `/api/version` for real readiness before app-level assertions.
- Image tag is `1.741.0` (no `v`); the git tag `v1.741.0` is not a valid image ref.

### (c) For Cloudron maintainers
- The `postgresql` addon allowlists `uuid-ossp`, but apps that need `BYPASSRLS`/`CREATEROLE` (Windmill
  for its workspace RLS) still cannot use it. A "privileged database" addon option, or an opt-in
  per-app role-with-BYPASSRLS, would let such apps avoid bundling their own PostgreSQL.

### (d) For Windmill developers
- The unguarded `CREATE EXTENSION "uuid-ossp"` and `SET ROLE windmill_admin` make CE hard to run on
  managed/least-privilege Postgres. A documented "non-superuser bootstrap" path (pre-create the
  extension/roles, then run migrations as a plain owner) would help every managed-PG deployment, not
  just Cloudron.
