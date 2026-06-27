# 0002 — Base image: cloudron/base final stage, COPY the unmodified CE binary + runtimes

**Status:** accepted (2026-06-27)

## Decision

Final stage is **`cloudron/base:5.0.0`** (pinned by digest). The Windmill binary and the language
runtimes it needs are `COPY --from` the official CE image
`ghcr.io/windmill-labs/windmill:1.741.0` (pinned by digest), **unmodified**:

| Copied | From → To |
|---|---|
| Windmill binary | `/usr/src/app/windmill` → `/app/code/windmill` |
| Deno | `/usr/bin/deno` → `/usr/local/bin/deno` |
| Bun | `/usr/bin/bun` → `/usr/local/bin/bun` |
| uv (manages Python at runtime) | `/usr/local/bin/uv` → `/usr/local/bin/uv` |
| Go toolchain | `/usr/local/go` → `/usr/local/go` |
| wmill CLI | `/usr/bin/wmill` → `/usr/local/bin/wmill` |

## Why Shape A (copy) and not `FROM` the CE image

Verified empirically: the Windmill binary's only direct deps are `libstdc++`, `libssl3`,
`libcrypto`, `libgcc_s`, `libm`, `libc` — **all present on `cloudron/base`** (glibc 2.39 is forward
compatible with the binary's bookworm glibc 2.36). Deno/Bun are self-contained; Go is a relocatable
toolchain. So Shape A is clean here, and it satisfies the hard Cloudron requirement that the **final
stage be `cloudron/base`** (the dashboard file-manager / web-terminal / log-viewer depend on it). The
foundation brief blessed `FROM` the CE image as a fallback, but Shape A is strictly better when the
linkage gate is green — smaller image, platform tooling intact, and consistent with the operator's
other `io.github.orcvole.*` packages.

## Licensing

We redistribute the **unmodified** CE binary (Windmill's "distribute as is" grant). We do **not**
modify or patch it, and do **not** re-enable capped/EE features. See [0006](0006-auth.md) and `NOTICE`.

## Runtimes intentionally NOT bundled in v1

PHP (the base already ships 8.3), Ruby, C#/.NET, Rust, Nushell. Core languages for the
definition-of-done — **Python (uv), TypeScript (Deno/Bun), Go, Bash, SQL** — are covered. Python and
JS/Go dependency runtimes are fetched on first use and cached under `/app/data` (see [0004](0004-state-secrets.md)).

## Gate

Dockerfile build fails unless `ldd` shows no "not found" and `windmill version`, `deno/bun/uv
--version`, `go version`, and `postgres --version` all succeed on the assembled base.
