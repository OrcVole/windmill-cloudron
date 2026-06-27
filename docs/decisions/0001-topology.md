# 0001 — Topology: single container, MODE=standalone, nginx-fronted, supervisor-managed

**Status:** accepted (2026-06-27)

## Decision

One Cloudron container running three processes under **supervisor**:

1. **PostgreSQL 16** (bundled, localhost only) — see [0003](0003-bundled-postgres.md).
2. **Windmill** with `MODE=standalone` — the API server **and** the worker(s) in a single OS process
   (the lever that makes a one-container package viable). Listens on `127.0.0.1:8001`.
3. **nginx** on the manifest `httpPort` (8000) — answers `/health` with an immediate `200`
   (liveness, stays green during first-boot migrations) and reverse-proxies everything else to
   Windmill with websocket upgrade and long read timeouts.

`NUM_WORKERS=1`. Upstream caps standalone to one in-process worker unless `NATIVE_MODE=true` /
`I_ACK_NUM_WORKERS_IS_UNSAFE=true` (both flagged unsafe), so we keep the safe default and scale by
memory instead. The separate `windmill-extra` image (LSP/multiplayer/debugger) is **not** included in
v1 — it is a second container in upstream's compose and not required for the core platform.

## Why not server + N×worker split

Standalone is upstream-supported, removes inter-process `BASE_INTERNAL_URL` plumbing, and fits the
single-tenant Cloudron posture. A split buys parallelism we cannot safely use in one process anyway.

## Consequences

- First-boot migrations run before the Windmill listener binds (~seconds to ~30 s). nginx's immediate
  `/health` keeps Cloudron from killing the container during that window (field guide §9).
- The ~60 s Cloudron proxy cut still applies to long synchronous HTTP job calls; nginx sets long
  proxy timeouts and Windmill jobs should be invoked async/streamed for long runs.
