---
* **Title**: Windmill on Cloudron — turn scripts into workflows, APIs and internal UIs
---

* **Main Page**: https://www.windmill.dev
* **Git**: https://github.com/windmill-labs/windmill
* **Licence**: AGPL-3.0 (Community Edition; client libraries Apache-2.0)
* **Dockerfile**: Yes — community package at https://github.com/OrcVole/windmill-cloudron (installable now via `--versions-url https://raw.githubusercontent.com/OrcVole/windmill-cloudron/main/CloudronVersions.json`)
* **Demo**: https://app.windmill.dev
---
* **Summary**: Windmill is an open-source developer platform and job runner. Scripts in Python, TypeScript, Go, Bash and SQL become webhooks, scheduled jobs, multi-step flows (with retries, approvals and branching) and auto-generated internal UIs, backed by a Rust core and a Postgres-based job queue. It's a self-hostable alternative to Airplane, Retool, n8n and Temporal, and a natural orchestration tier for a private self-hosted stack.
---
* **Notes**: A working community package already exists (CE 1.741.0, package v1.0.1), tested on Cloudron 9.1: install, language execution (Python/TS/Go/Bash), webhooks, email via the sendmail addon, and a consistent backup/restore of the bundled database. Two things a maintainer should know. (1) It bundles its own PostgreSQL rather than using the `postgresql` addon, because Windmill requires superuser-grade DB privileges (`CREATE EXTENSION uuid-ossp`, `CREATE ROLE … WITH BYPASSRLS`, runtime `SET ROLE`) that the addon doesn't grant, and the only addon-compatible alternative — patching the binary — is disallowed by the CE license. (2) Under Cloudron's unprivileged, read-only container, Windmill's nsjail/PID-namespace sandbox and Docker "container step" jobs are unavailable, so it's a single-tenant, trusted-author deployment (native jobs run in the app's trust boundary) — not for executing untrusted, multi-tenant code. The CE binary is used unmodified, with no enterprise-capped features re-enabled.
---
* **Alternative to**: Airplane, Retool, n8n, Temporal, Superblocks — https://www.libhunt.com/r/windmill
* **Screenshots / brand logo**: https://raw.githubusercontent.com/OrcVole/windmill-cloudron/main/logo.png and screenshots at https://www.windmill.dev
