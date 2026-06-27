## 🚀 Windmill: community package now available

> **TL;DR:** Windmill turns scripts in **Python, TypeScript, Go, Bash and SQL** into webhooks, scheduled jobs, multi-step **flows**, and auto-generated **internal UIs** — a fast, open-source developer platform and job runner (an alternative to Airplane / Retool / n8n / Temporal). Now packaged for Cloudron and ready to install. Built and tested on Cloudron 9.1; unofficial and community-maintained.

### Links

- 🏠 Project homepage: https://www.windmill.dev
- 📦 Upstream repo: https://github.com/windmill-labs/windmill
- 🧱 Cloudron package repo: https://github.com/OrcVole/windmill-cloudron

There's a hosted upstream demo at https://app.windmill.dev. The package you install is the self-hosted **Community Edition** — the full app (editor, workers, scheduler, UIs) on your own box, behind your own login.

---

### 📥 How to install

Community packages aren't in the App Store, so install via the CLI. The published image is on GHCR and the package ships a community versions file:

```bash
# recommended: install the published community build from the versions URL
cloudron install \
  --versions-url https://raw.githubusercontent.com/OrcVole/windmill-cloudron/main/CloudronVersions.json \
  --location windmill.example.com

# or pin the prebuilt image directly
cloudron install --image ghcr.io/orcvole/windmill-cloudron:1.0.1 --location windmill.example.com

# or build it yourself from the repo
git clone https://github.com/OrcVole/windmill-cloudron
cd windmill-cloudron
cloudron build
cloudron install --image [your-registry]/windmill-cloudron:latest --location windmill.example.com
```

**Minimums:** 3 GB RAM recommended (the app bundles its own PostgreSQL alongside the Windmill server and a worker — see below; raise it for heavier workloads). Addons: `localstorage` and `sendmail`. **No `postgresql` addon** — the package bundles Postgres on purpose.

**First run:** log in with `admin@windmill.dev` / `changeme` and **change the password immediately** (Settings → Users). Then create a workspace and start writing scripts. Windmill CE **1.741.0**, package **v1.0.1**.

---

### 👤 For users

**Why try it:** Windmill is the glue for a self-hosted stack. Write a function in the language you already use, and Windmill instantly gives it a webhook, a schedule, a typed input form, and a run history — then lets you compose those functions into flows with retries, approvals and branching, and assemble small internal UIs on top. It's fast (a Rust core, a real job queue in Postgres) and everything stays on your box.

What you get out of the box:

- **Scripts → webhooks/CRON/UIs** in Python (via uv), TypeScript (Deno & Bun), Go, Bash and SQL — all runtimes baked into the image; the first job in a language warms its dependency cache.
- **Flows**: multi-step pipelines with retries, error handlers, approval steps, branches and a visual editor.
- **Secrets, variables and resources** with per-workspace encryption, plus granular roles/permissions.
- **A built-in editor** with an integrated job runner, schedules, and run history.
- **Cloudron-specific wins:** outgoing email is wired to the Cloudron mail addon automatically; `/health` is open for monitoring; all state lives in a bundled PostgreSQL that is captured by Cloudron backups via a consistent logical dump; updates are one click.

Good fit if you want a private automation/back-office platform that sits next to the rest of your self-hosted stack and can call any of it. Probably not for you if you need to run **untrusted, multi-tenant** code (see the security note below) or you rely on Windmill's Docker "container step" jobs (not available under Cloudron's unprivileged container).

---

### 🧰 For packagers: what we learned

**What helped**

- **`MODE=standalone`** is the single-container lever — the API server and a worker in one process. `NUM_WORKERS` is capped to 1 in standalone (raising it needs flags upstream marks unsafe), so scale by memory, not worker count.
- **Shape A still wins for a multi-runtime image** when the linkage gate is green: copy the unmodified CE binary + the self-contained runtimes (Deno, Bun, uv, Go) from the official image onto `cloudron/base`, rather than `FROM` the 3.9 GB CE image. The Windmill binary's only direct deps are stock glibc libs already on the base.
- **All durable state is in Postgres** (including the per-workspace encryption keys and the auto-generated `jwt_secret`), so there's no external data-loss-critical key file to seed — the database backup is the whole backup.

**What was tricky and how we solved it**

- **The Cloudron `postgresql` addon can't host Windmill.** Windmill's unmodified binary needs superuser-grade Postgres: an unguarded `CREATE EXTENSION "uuid-ossp"`, a `CREATE ROLE … WITH BYPASSRLS` for workspace row-level-security, and a runtime `SET ROLE`. The addon grants a single non-superuser owner — none of that. The only addon-compatible workaround is **patching the Windmill binary**, which the CE license forbids ("distribute as is, do not modify or wrap"). So the package **bundles PostgreSQL 16** as superuser instead — the field-guide "bundle-localhost-under-`/app/data` when no addon can serve the app" pattern.
- **A hot file-copy of a running Postgres data dir is unsafe** (torn pages). Cloudron's filesystem backup copies `/app/data` live, so we put `PGDATA` in a **`persistentDir`** (excluded from the filesystem backup) and use **`backupCommand`/`restoreCommand`** (`minBoxVersion 9.1.0`) to `pg_dumpall` a consistent logical dump into `/app/data` at backup time and rebuild the cluster from it on restore. Verified: a workspace + variable survive a backup → restore onto a fresh data volume.
- **Windmill probes `/usr/bin/deno` by default** — copy Deno/Bun there (and set `DENO_PATH`/`BUN_PATH`), or TypeScript jobs fail with "Executable /usr/bin/deno not found". Go needs `GO_PATH`.
- **nginx as the `cloudron` user, read-only rootfs:** use the `error_log stderr` keyword (opening the `/dev/stderr` path fails as non-root), put the pid in a chowned dir, and don't double-declare `daemon off`.
- **Liveness ≠ readiness, even in the smoke gate:** `/health` (served by nginx) is 200 before first-boot migrations finish, so poll `/api/version` for real readiness before asserting app behavior.

**Still rough / open questions**

- A cold install from the versions URL on a fresh subdomain is the gate we'd most welcome other eyes on.
- The bundled-Postgres memory budget is shared with the Windmill worker — an OOM takes the DB down with the app. Conservative `shared_buffers`/`work_mem` plus a documented memory floor mitigate it; real-world tuning feedback is welcome.

---

### 🛠️ For the Cloudron team

**Maintenance burden:** upstream Windmill ships very frequently. The package is a thin layer (a pinned version build-arg + the manifest), so a rebump is a version bump, a rebuild, and a re-run of the language smoke + the backup/restore gate.

**Why it would suit the App Store:** it's the automation/orchestration tier the self-hosted catalogue is missing, and it ties the rest of the stack together (it can drive any HTTP service on the box). The package honours upstream's license — the CE binary is used **unmodified**, with **no** capped/enterprise features re-enabled.

**Friction worth knowing about:** an app that needs a **`BYPASSRLS`/`CREATEROLE`** Postgres role still can't use the `postgresql` addon (the `uuid-ossp` allowlist isn't enough), which is what forces bundling a private Postgres — a "privileged database" addon option would let apps like this avoid that. The `persistentDirs` + `backupCommand`/`restoreCommand` trio (9.1.0) is exactly the right tool for a bundled DB and worked well.

---

### 💻 For Windmill's developers and contributors

A few low-effort things that help packagers a lot:

- **A documented non-superuser bootstrap.** The unguarded `CREATE EXTENSION "uuid-ossp"` and `SET ROLE windmill_admin` make CE hard to run on managed/least-privilege Postgres. A supported "pre-create the extension + roles, then run migrations as a plain owner" path would help every managed-PG deployment, not just Cloudron.
- **Read SMTP from the environment as a first-class option** (it already falls back to env when the DB setting is absent) and document it, so platform mail addons map cleanly.
- **Publish a glibc/Postgres-version floor per release**, so a slim base copy of the binary knows its target.

Package source and PRs welcome here: https://github.com/OrcVole/windmill-cloudron. Happy to co-maintain.

---

### 🔓 Unlocks

Once it's running, you can:

- Turn any Python/TS/Go/Bash function into a webhook, a CRON job, or a small internal UI in minutes — no boilerplate service to write or deploy.
- Build flows that orchestrate the rest of your box: call your other self-hosted APIs, gate steps on human approval, retry and branch.
- Schedule and observe back-office automation (reports, syncs, ETL) with a real run history and per-workspace secrets, all on your server.

### 🔗 Synergies

Pairs nicely with other Cloudron apps — Windmill is the orchestrator that calls them:

- **Windmill + Docling + TEI + Qdrant:** a flow that converts a document (Docling), embeds the text (TEI), and upserts vectors (Qdrant) — a private RAG ingestion pipeline, scheduled or webhook-triggered.
- **Windmill + a reranker (e.g. bge-reranker):** rerank Qdrant hits for higher-quality retrieval inside the same flow.
- **Windmill + Ollama / OpenWebUI / agentgateway:** point Windmill AI at an OpenAI-compatible endpoint on your box for code generation and LLM steps.
- **Windmill + anything with a webhook:** it's the glue — schedule it, trigger it, and wire the outputs onward.

---

Feedback, bug reports, and "works on my install" confirmations all welcome below. 🙏
