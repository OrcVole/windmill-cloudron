# 0005 — Security & sandboxing posture (headline)

**Status:** accepted (2026-06-27) — verified on boot

## The constraint

Cloudron runs the container **unprivileged**, read-only rootfs, no `CAP_SYS_ADMIN`, no new
user/mount/PID namespaces, no host Docker socket. Windmill's job isolation depends on exactly those:

- **nsjail** (filesystem/syscall sandbox) — Windmill CE defaults `DISABLE_NSJAIL=true` anyway, and
  nsjail needs user namespaces + an unmasked `/proc`. Off.
- **PID-namespace isolation** (`ENABLE_UNSHARE_PID`/`FAVOR_UNSHARE_PID`) — needs `unshare
  --mount-proc`, i.e. privileged. **Verified off**: each worker process logs
  `unshare: mount /proc failed: Permission denied … Unshare isolation will NOT be available` — the
  expected, benign result of our unprivileged container. We therefore do **not** set
  `FAVOR_UNSHARE_PID=true`, even though upstream's docker-compose worker does — here it cannot work and
  would only emit this warning. (As of v1.1.0 workers are separate processes; this posture is per
  worker — see [0001](0001-topology.md).)
- **Docker "container step" / `# sandbox <image>` jobs** — need a Docker socket / dind. Unavailable.

## Decision

Accept the platform constraints. Leave nsjail and unshare-PID **off** (the CE defaults). Do **not**
request the `docker` addon (it would also force superadmin-only installs). Document loudly.

## What this means

- ✅ **Native jobs run**: Python, TypeScript (Deno/Bun), Go, Bash, SQL execute normally.
- ❌ **Docker/container-step jobs do not run** (no daemon, no nsjail).
- ⚠️ Native jobs execute **within the app container's trust boundary** — they share it with the
  Windmill process. This is the standard single-tenant **trusted-author** self-host posture. It is
  **not** safe for running untrusted or multi-tenant code. If a workspace author is hostile, they can
  reach anything the container can.

Cloudron's own per-app container isolation (separate container, no host access, egress controllable)
is the security boundary here — not Windmill's in-process sandbox.

## Where this is documented

`DESCRIPTION.md`, `POSTINSTALL.md`, `README.md`, and `docs/LEARNINGS.md` all state the posture so an
operator cannot miss it.
