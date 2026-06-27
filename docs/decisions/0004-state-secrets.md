# 0004 — State and secrets

**Status:** accepted (2026-06-27) — verified against source + boot

## Where state lives

Windmill keeps **all durable state in PostgreSQL** (job queue, scripts, flows, schedules, run
history, variables/secrets). Two security-sensitive keys are also **in the database**, not in files
or env:

- **Per-workspace secret-encryption keys** — `workspace_key` table; encrypt workspace
  variables/secrets.
- **`jwt_secret`** — auto-generated and saved to `global_settings` on first boot if absent; signs
  auth JWTs/sessions.

**Implication:** there is **no external, data-loss-critical key file** to seed. Because both keys
live in the bundled Postgres, the `/app/data` backup (which contains the PG data dir) captures them.
A restore is byte-complete by construction — no separate `sha256`-must-match key file to manage
(contrast Langfuse's external `ENCRYPTION_KEY`). The only generated secret we manage is the **DB
password** (`/app/data/.secrets/db.env`), seeded once and never reseeded; it is internal to the
bundled PG and also lives under `/app/data`.

## `/app/data` layout

```
/app/data/postgresql/16/      bundled PostgreSQL data directory (all Windmill state)
/app/data/.secrets/db.env     generated DB superuser password (0600 in a 0700 dir)
/app/data/cache/uv            uv cache
/app/data/cache/py_runtime    uv-managed Python interpreters
/app/data/cache/go            GOCACHE
/app/data/cache/gopath        GOPATH
/app/data/cache/deno          DENO_DIR
/app/data/cache/bun           Bun install cache
/app/data/cache/{rustup,cargo,npm}
```

The runtime caches are regenerable but kept under `/app/data` so dependency installs survive
restarts/updates and do not re-download (field guide §7.3). They do inflate backup size — documented.

## Every-boot discipline

`start.sh` re-asserts ownership (`chown -R cloudron:cloudron /app/data`) and the `0700/0600` modes on
every boot, because a restore can reset ownership/modes (field guide §7.2). Secrets are seeded only
when absent (idempotent); addon-derived values (SMTP) are mapped fresh every boot.
