<upstream>1.792.2</upstream>

## Windmill

Windmill is an open-source developer platform and workflow engine. Turn scripts in
**Python, TypeScript, Go, Bash and SQL** into shareable webhooks, scheduled jobs, multi-step
flows, and auto-generated internal UIs — with a fast editor, a job queue, secrets/variables,
approval steps and granular permissions, all backed by PostgreSQL.

**Unofficial community package** — maintained by its packager, **not affiliated with, endorsed by, or
supported by Windmill Labs**. It runs the official Windmill Community Edition binary, unmodified, and
is scoped as a **single-node, small-team** deployment (the server and worker processes co-located in
one container, workers scaled by memory) — not a replacement for a horizontally-scaled, multi-node
Windmill.

This package runs the official **Windmill Community Edition** binary, unmodified, in a single
Cloudron container:

- **Server + workers** — a dedicated API/UI server process plus one or more worker processes (the same split Windmill runs in production), co-located in the one container and fronted by nginx. The worker count scales with the memory you give the app.
- **Bundled PostgreSQL** — Windmill needs superuser-grade database privileges (it creates roles
  with `BYPASSRLS` and the `uuid-ossp` extension), so the package ships its own PostgreSQL 16 with
  all data under `/app/data`, captured by Cloudron's backups. (The shared `postgresql` addon cannot
  grant those privileges.)
- **Outgoing email** via the Cloudron mail addon.
- **App-native login** (Windmill's own users), optional Cloudron SSO not required.

### Languages and runtimes included

Python (via uv), TypeScript (Deno and Bun), Go, Bash and SQL run out of the box. Dependency caches
persist under `/app/data`.

### Security posture (read this)

Cloudron runs the container **unprivileged with a read-only root filesystem**, so Windmill's
nsjail / PID-namespace sandboxing and Docker-in-Docker container steps are **not** available.
Native jobs (Python/TS/Go/Bash/SQL) run within the app's own trust boundary. This is the normal
single-tenant, **trusted-author** self-host posture — it is **not** suitable for executing
untrusted or multi-tenant code.

Enterprise-only features of Windmill are not enabled.
