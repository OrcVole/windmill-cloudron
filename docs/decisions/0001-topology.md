# 0001 — Topology: single container, server + N workers, nginx-fronted, supervisor-managed

**Status:** accepted (2026-06-27); **revised 2026-06-28 (v1.1.0)** — replaced `MODE=standalone`
with the real server/worker split after upstream maintainer feedback (see below).

## Decision

One Cloudron container running, under **supervisor**:

1. **PostgreSQL 16** (bundled, localhost only) — see [0003](0003-bundled-postgres.md).
2. **Windmill API/UI server** — one process with `MODE=server`. Runs first-boot migrations, serves
   HTTP on `127.0.0.1:8001`, and does **not** process jobs.
3. **Windmill workers** — `N` separate processes with `MODE=worker`, `WORKER_GROUP=default`. They
   process the job queue. This is the same server/worker split upstream ships in `docker-compose`,
   co-located in the single container instead of spread across replicas/hosts.
4. **nginx** on the manifest `httpPort` (8000) — answers `/health` with an immediate `200`
   (liveness, stays green during first-boot migrations) and reverse-proxies everything else to the
   **server** with websocket upgrade and long read timeouts. Workers serve no HTTP.

`MODE` and `PORT` are set **per process** in the supervisor units, never globally — a global `PORT`
would make every worker try to bind 8001. `start.sh` generates the worker units into
`/run/windmill/supervisor.d/*.conf` (a writable tmpfs include dir) so the count can vary per boot;
the server unit is static in `supervisord.conf`.

### Worker count scales with memory

`N` is derived from the app's memory limit (`CLOUDRON_MEMORY_LIMIT`, else the cgroup `memory.max`,
else the 3 GiB default): reserve ~1 GiB for PostgreSQL + the server + nginx + headroom, then ~768 MiB
per worker, clamped to `[1, 6]`. So an operator raises throughput by raising memory (Cloudron →
Resources) — "scale by memory," exactly as the maintainer advised. `WINDMILL_WORKER_COUNT` overrides
the math for tuning. At the 2 GiB floor this is 1 server + 1 worker; at the 3 GiB default, 1 + 2.

## Why not MODE=standalone (the prior decision, reversed)

v1.0.0 used `MODE=standalone` (server + one in-process worker). The Windmill maintainer
([discussion #9833](https://github.com/windmill-labs/windmill/discussions/9833)) confirmed standalone
is **development-only**: it pins `NUM_WORKERS` to 1 (raising it needs flags upstream marks unsafe) and
is "absolutely not meant for production." Co-locating the *real* server + worker processes — each a
normal Windmill process, scaled by count — is the supported single-node shape (the docker-compose
topology) and is what we now ship. The cost is a little inter-process plumbing
(`BASE_INTERNAL_URL=http://127.0.0.1:8001`, already set) and a generated supervisor include; the gain
is a configuration upstream actually supports.

## Consequences

- First-boot migrations run in the **server** process before its listener binds (~seconds to ~30 s).
  nginx's immediate `/health` keeps Cloudron from killing the container during that window
  (field guide §9). Workers poll/retry until the schema exists — upstream-expected, and supervisor
  `autorestart` covers any early exit.
- All Windmill processes share one container memory limit with PostgreSQL; an OOM can take the DB down
  with the app. The worker-count math leaves PG headroom; `POSTINSTALL.md` documents a 2 GiB floor /
  3 GiB recommended. See [0003 §Memory](0003-bundled-postgres.md).
- Security posture is unchanged by the split: each worker runs with the same (no-nsjail, no-unshare)
  posture the in-process worker did — [0005](0005-security-sandboxing.md) still holds per process.
- The separate `windmill-extra` image (LSP/multiplayer/debugger) is still **not** included in v1 — a
  second container in upstream's compose, not required for the core platform.
- The ~60 s Cloudron proxy cut still applies to long synchronous HTTP job calls; nginx sets long
  proxy timeouts and Windmill jobs should be invoked async/streamed for long runs.
