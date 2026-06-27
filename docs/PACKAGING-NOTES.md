# Packaging notes — verified vs assumed (newest first)

The empirical log. Every assumption carried from a brief/README/reference is recorded here as
**VERIFIED** (checked against a real build/run) or **ASSUMED** (still to confirm on the live box).

## 2026-06-27 — Live deploy + functional validation on the box

All VERIFIED on the live Cloudron (anonymized; box hostname omitted per the secret-scan gate):

- **Install + health**: `cloudron install --image ...@sha256:...` reached healthy within the grace
  window; public `/health` 200, `/api/version` → CE v1.741.0. First boot migrations ran on the box's
  bundled Postgres.
- **Auth**: default-cred superadmin login worked; then **changed the default password** (new password
  works, `changeme` rejected 400) and set the `base_url` instance setting to the app origin.
- **Languages run on the box**: **Python** (uv installed managed CPython 3.12.13), **TypeScript/Deno**,
  **Go**, **Bash** — all returned correct results via `jobs/run/preview`. (SQL needs a user-configured
  DB resource — standard Windmill, not a packaging concern.)
- **deno path gotcha (fixed)**: Windmill probes **`/usr/bin/deno`** by default; copying deno/bun to
  `/usr/local/bin` made TS jobs fail `Executable /usr/bin/deno not found`. Fix: place deno/bun at
  `/usr/bin` **and** set `DENO_PATH`/`BUN_PATH`. (Go worked because `GO_PATH` was already set.)
- **Webhook**: a saved script fired via `run_wait_result` against the **public origin** returned the
  result — `BASE_URL` + routing correct end to end.
- **Email**: `is_smtp_configured` → true; `test_smtp` → "Sent test email" through the Cloudron
  `sendmail` relay (`mail:2525`, `disable_tls`). Note: Windmill runs **user jobs with a sanitized env**,
  so `SMTP_*`/`DATABASE_URL` are intentionally NOT visible inside job code (checking `os.environ` in a
  job is the wrong test — check the server/supervisord env).
- **Integration (wired up)**: from a Windmill job, outbound HTTPS to every sibling (tei, qdrant,
  docling, **bge reranker**) returned 200; a **real rerank** call to the bge reranker
  (`BAAI/bge-reranker-v2-m3`, `/rerank`, Bearer key) ranked the relevant passage top (0.9999).
- **Update path (Phase 7)**: `cloudron update` to a new image digest **auto-backed-up first** (the
  snapshot included `data/postgresql/16/...` — confirming the bundled PG rides Cloudron backups),
  applied cleanly, and the `demo` workspace + data **persisted** across the update.

## 2026-06-27 — Local build + Cloudron-style run

- **VERIFIED** — Image builds on `cloudron/base:5.0.0`; linkage gate green. Windmill v1.741.0 binary's
  only direct deps (`libstdc++`, `libssl3`, `libcrypto`, `libgcc_s`, `libm`, `libc`) all resolve on
  the base. `deno 2.2.1`, `bun`, `uv 0.11.24`, `go 1.26.0`, `postgres 16.14` all `--version` on the
  assembled image. Final image ≈ 3.82 GB.
- **VERIFIED** — Windmill image tag is **`1.741.0`** (no `v`); registry digest
  `sha256:18c7114977783a2f6632387b6255e7c51849b8e338e3daf36438033cf867da91`. (The git *tag* is
  `v1.741.0`; the brief's `ghcr.io/...:v1.741.0` would 404.)
- **VERIFIED** — **Bundled-Postgres architecture works.** Run with read-only rootfs + tmpfs
  `/run`+`/tmp` + `/app/data` volume: all migrations apply (incl. `uuid-ossp`, `windmill_admin
  BYPASSRLS`, the final live migration), then `server started on port=8001`. Default-cred login
  (`admin@windmill.dev`/`changeme`) returns a 32-char superadmin token. Second boot takes the
  idempotent path (no reseed). This retires the brief's "#1 risk" (Postgres privileges) — solved by
  bundling, **not** by the addon. (ADR 0003.)
- **VERIFIED** — `/health` returns 200 (nginx) immediately, before the backend is ready: liveness ≠
  readiness. The smoke gate must poll `/api/version` for readiness, not assume `/health` implies it.
- **VERIFIED** — Runs as `cloudron`; `/app/code` write fails (`Read-only file system`); DB password
  absent from logs.
- **VERIFIED** — PID-namespace isolation unavailable: worker logs
  `unshare: mount /proc failed: Permission denied`. Expected/benign under Cloudron's unprivileged
  container. (ADR 0005.)
- **VERIFIED** — The Cloudron `postgresql` addon allowlists `uuid-ossp` (addons-ref), but cannot grant
  `BYPASSRLS`/`CREATEROLE`, so it still can't host Windmill with an unmodified binary. (ADR 0003.)
- **VERIFIED** — `cloudron/base` already ships `nginx`, `gosu`, `supervisord`, `pg_dump`; Ubuntu 24.04
  provides `postgresql-16` (16.14) in main.
- **VERIFIED (config gotchas)** — nginx: duplicate `daemon` directive (conf + `-g`) → use only one;
  `/dev/stderr` open fails as `cloudron` → use the `stderr` keyword; pid must live in the chowned
  `/run/nginx/` not `/run/`.
- **ASSUMED (to verify on box)** — On the live Cloudron: install reaches healthy within the grace
  window; `sendmail` addon → Windmill SMTP actually delivers; `BASE_URL=CLOUDRON_APP_ORIGIN` yields
  correct webhook URLs (Windmill may need the base URL set in instance settings too); backup→restore
  and update preserve all state; outbound reach to sibling apps.
- **ASSUMED** — First-boot migration window fits Cloudron's health grace (nginx immediate `/health`
  should cover it, but confirm on box).

## Conventions
- One source of version truth: Dockerfile `ARG WINDMILL_VERSION` + pinned `@sha256`. Manifest
  `upstreamVersion` mirrors it; `version` is our package semver.
- Box-specific facts (real hostnames, private mirror, internal URLs) are **gitignored**; this file
  stays anonymized. `test/secret-scan.sh` enforces it.
