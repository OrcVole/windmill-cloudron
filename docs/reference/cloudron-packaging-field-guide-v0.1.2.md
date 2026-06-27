# Cloudron Packaging: A Field Guide

A practical, lesson-driven guide to packaging applications for Cloudron, written from six real
packaging efforts:

- **TEI** (HuggingFace Text Embeddings Inference): a thin binary copy with a fragile dlopen math runtime.
- **Qdrant** (vector database): HTTP + gRPC hybrid, path-scoped SSO, insecure-by-default upstream.
- **agentgateway** (MCP/LLM gateway): multi-domain data plane, config the UI rewrites, a rich retrospective.
- **Prosody** (XMPP server): the hard case, a multi-port non-HTTP protocol that does not fit the web model.
- **Docling** (document conversion ML API): a multi-gigabyte Python ML stack, two-stage slimming, GHCR publish.
- **Langfuse** (LLM observability platform): the first **stateful, multi-service web app** — four processes
  under Supervisor (web, worker, a bundled ClickHouse, a bundled MinIO), upstream **musl** binaries on the
  **glibc** base, **app-native OIDC SSO** (not `proxyAuth`), and a **data-loss-critical** encryption key.

Field guide **v0.1.2**. Current for **Cloudron 9.x** and **`cloudron/base:5.0.0`** (verified March to June 2026).

The single most important lesson, stated once up front because every effort relearned it:

> **Empirical verification beats documentation, including this document.** Every assumption carried
> from a brief, an upstream README, or a packaging reference and not checked against the running box
> needed correction at least once. Check the binary against the base with the dynamic linker. Validate
> config with the app's own validator. Inspect the running container. Test the real install path end to
> end. The packaging reference itself had an error (an addon name in the wrong case) that only an
> install failure surfaced.

---

## Table of contents

1. [The mental model](#1-the-mental-model)
2. [The base image](#2-the-base-image)
3. [Repository shape: the thin packaging layer](#3-repository-shape-the-thin-packaging-layer)
4. [The Dockerfile](#4-the-dockerfile)
5. [CloudronManifest.json, field by field](#5-cloudronmanifestjson-field-by-field)
6. [Auth and topology: the crux](#6-auth-and-topology-the-crux)
7. [Secrets and state](#7-secrets-and-state)
8. [start.sh: the canonical entrypoint](#8-startsh-the-canonical-entrypoint)
9. [Health checks: liveness is not readiness](#9-health-checks-liveness-is-not-readiness)
10. [Releasing and publishing](#10-releasing-and-publishing)
11. [The gates: what to verify before you ship](#11-the-gates-what-to-verify-before-you-ship)
12. [Debugging on the box](#12-debugging-on-the-box)
13. [Decision framework: is this app a good fit](#13-decision-framework-is-this-app-a-good-fit)
14. [Gotcha catalog (quick reference)](#14-gotcha-catalog-quick-reference)
15. [Appendix A: base image inventory](#appendix-a-base-image-inventory-cloudron-913)
16. [Appendix B: copy-paste templates](#appendix-b-copy-paste-templates)

---

## 1. The mental model

A Cloudron package is a **thin adaptation layer**, not a fork. You take an upstream release and adapt
only its runtime environment to Cloudron's contract. You do not patch the application.

Cloudron runs your container with a **read-only root filesystem**. Exactly three paths are writable:

| Path | Persists? | Backed up? | Use |
|------|-----------|-----------|-----|
| `/app/data` | yes | yes (the only backed-up location) | the key, databases, caches, user config, certs |
| `/run` | no | no | PID files, sockets, generated config, scratch |
| `/tmp` | no | no | temporary files |

Everything else (`/app/code`, `/etc`, `/var`, `/usr`) is read-only at runtime. Anything the app tries
to write elsewhere fails with `EROFS`.

The platform terminates TLS at its own reverse proxy and forwards **plain HTTP** to your container on
the manifest's `httpPort`. The app must listen on that port in plain HTTP, never HTTPS, and trust the
forwarded headers from `CLOUDRON_PROXY_IP`. The external origin is in `CLOUDRON_APP_ORIGIN` (it includes
`https://`).

External services (databases, mail, LDAP, SSO) are **addons**: you declare them in the manifest and the
platform provisions them and injects connection details as `CLOUDRON_*` environment variables. Never
bundle a store that has an addon (Postgres, MySQL, Mongo, Redis) — use the addon.

The nuance, learned from Langfuse: some apps need stores Cloudron has **no addon for** (ClickHouse, an
S3/object store). Those you **do** bundle inside the container, run under Supervisor as additional
processes, bind to **localhost only**, and point at a data directory **under `/app/data`** so they ride
the backup. Langfuse runs a bundled ClickHouse (analytics) and MinIO (S3 for trace media) this way, while
using the `postgresql` and `redis` addons for the two stores that do have addons. The rule generalizes to:
**addon if one exists; bundle-localhost-under-`/app/data` if not.** See section 13 for when the process
count makes this a poor fit.

Your process runs as the unprivileged **`cloudron`** user (UID 1000), or `www-data` for PHP. Only the
entrypoint's setup phase runs as root.

Backups and restores operate on `/app/data` only. A restore can reset ownership and file modes, so the
entrypoint must re-assert both on every boot (see [section 8](#8-startsh-the-canonical-entrypoint)).

---

## 2. The base image

```dockerfile
FROM cloudron/base:5.0.0@sha256:04fd70dbd8ad6149c19de39e35718e024417c3e01dc9c6637eaf4a41ec4e596c
```

**Always pin the digest.** Tags are mutable; digests are immutable and reproducible. All five packages
use this exact digest.

Why this base and not Alpine or a slim Debian:

- **Shared layers.** Every Cloudron app derives from this image, so Docker stores the base layers once.
  A different base means a separate layer tree on disk for every app.
- **Platform integration.** It ships the `cloudron` user (UID 1000), `gosu`, an Nginx configured for the
  platform, and database clients matching the addon versions. The file manager, web terminal, and log
  viewer in the dashboard depend on it.
- **Security.** The Cloudron team audits and patches it.

It is Ubuntu 24.04, glibc 2.39, roughly 2.5 GB. A binary built on Debian bookworm (glibc 2.36) runs fine;
glibc is forward compatible. A binary needing a glibc newer than 2.39 will fail at runtime, which is why
the linkage gate (section 4) exists. Full inventory in [Appendix A](#appendix-a-base-image-inventory-cloudron-913).

---

## 3. Repository shape: the thin packaging layer

A package is, at minimum, four files, plus docs that ship with the code:

```
Dockerfile                 the build
start.sh                   the entrypoint
CloudronManifest.json      the package contract
DESCRIPTION.md, logo.png   store metadata
README.md, CHANGELOG.md    human docs
docs/                      ADRs, packaging notes, debugging, integrations
test/smoke.sh              the real runtime gate
test/secret-scan.sh        the anonymity sweep
CloudronVersions.json      the community install channel (generated at release)
```

Conventions that paid off across all five repos:

- **An AGENTS.md / working contract** at the root that states the settled decisions ("golden rules") so
  they are not relitigated each session: conformance first, pin the upstream version in one place, do not
  break the auth topology, persisted state only in `/app/data`, fail loud, code and docs ship together.
- **ADRs** (`docs/decisions/NNNN-title.md`) for each non-obvious decision (why pip-install on base vs
  copy the venv; why bake models; the auth topology). They stop the next person from re-deriving or
  reversing a hard call.
- **A "verified vs assumed" log** (`docs/PACKAGING-NOTES.md`), newest first, recording what was confirmed
  empirically against the box versus carried over by assumption. This is where the empirical-verification
  discipline lives.
- **Local-only docs gitignored.** Files carrying box-specific context (real hostnames, the private
  mirror, internal stack URLs) are listed in `.gitignore` and never published. The anonymized public
  record lives in `docs/PACKAGING-NOTES.md`.

---

## 4. The Dockerfile

### 4.1 Pin everything

- Base image by `@sha256` digest.
- Upstream version in **one** place, a build `ARG` (`DOCLING_SERVE_VERSION`, `TEI_VERSION`,
  `AGENTGATEWAY_VERSION`, `QDRANT_VERSION`, `PROSODY_VERSION`). The manifest mirrors it in
  `upstreamVersion` as read-only metadata; the `ARG` is the source of truth.
- Any tool downloaded in the build (uv, yq) by URL **and SHA256**, verified in the `RUN`. This catches
  network corruption and supply-chain swaps at build time.
- **Never floating tags.** No `latest`, `stable`, `-rc`. The bug this prevents is silent: a CPU-vs-CUDA
  mix-up. TEI's bare `:1.9` tag is the CUDA image; the CPU+MKL build is `cpu-1.9`. Docling installs
  CPU-only torch from the PyTorch CPU index *first* so the app install finds torch already satisfied and
  does not pull the multi-gigabyte CUDA build.

### 4.2 Three build shapes

**Shape A: copy a single upstream binary onto the base (TEI, Qdrant, agentgateway).**
The cleanest case. A multi-stage Dockerfile: stage 1 is the pinned upstream image, stage 2 is
`cloudron/base`, and you `COPY --from` only the binary and the runtime libraries it actually needs. The
base already provides `libstdc++6`, `libssl3`, `libgcc_s`, `libm`, `libc`, so often no `apt-get` is
needed at all.

**Shape B: install a fat stack onto the base (Docling).**
For a Python ML app (torch, OpenCV, OCR, models) a cross-distribution venv copy from a CentOS-based
upstream image is brittle (interpreter, native libs, and dlopened libs all have to line up). Docling
instead installs the pinned release straight onto `cloudron/base` with `uv`, on the same Ubuntu 24.04 /
Python 3.12 the app expects.

**Shape C: run upstream musl (Alpine) binaries on the glibc base (Langfuse).**
Langfuse ships Alpine images: a **musl** Node runtime and musl-linked Prisma engine binaries, while
`cloudron/base` is **glibc**. You cannot relink them, and you do not have to: the **ELF interpreter is
per-binary**, so a musl binary that carries its own loader runs fine next to glibc processes. Copy the
upstream musl Node, the musl loader, and its libraries into an **isolated prefix** (`/opt/musl/lib`,
registered in `/etc/ld-musl-x86_64.path`) and launch the app with that Node — glibc binaries keep using
`/lib64/ld-linux`, the musl ones use `/lib/ld-musl`, and they never collide. The one real catch is
**Prisma**: it sniffs the platform (reads `/etc/os-release`, sees Ubuntu, and reaches for a glibc engine),
so you must override its detection with `PRISMA_QUERY_ENGINE_LIBRARY` and `PRISMA_SCHEMA_ENGINE_BINARY`
pointed at the **musl** engines on **version-agnostic** paths (symlinks like
`/app/code/.engines/query-engine.so.node`, so an upstream bump does not move the target and break the
override). Verified on the box: musl Node + musl Prisma engines resolve and run on `cloudron/base`, DNS to
the Postgres/Redis addons works under musl, and the isolation holds under the full multi-process set. This
is the escape hatch when upstream is musl-only and a from-source glibc rebuild is impractical. Prove it
with the dynamic-linker check (`ldd` reports the musl interpreter, the binary runs `--version`) **and** a
real query through Prisma to an addon, not just a link check.

### 4.3 The two-stage slim, and why it matters more than it looks

Docling's single-stage image was 8.74 GB; the installed tree (`/app/code`) was only 3.3 GB. The other
5.4 GB was **layer accumulation**: `uv`'s multi-gigabyte download cache (in `~/.cache/uv`, not in the
venv) was baked into the `RUN` layers, and a `chmod -R` over 740 MB of models created a copy-up layer.

A two-stage build where the runtime stage does only `COPY --from=builder /app/code/venv` and
`COPY --from=builder /app/code/models` ships **only the installed tree**, dropping the build cache and the
copy-up cruft. Result: **8.74 GB to 6.05 GB, a third smaller, no decision changed.** Because the builder
stage's `RUN` lines were left byte-identical, they hit the existing layer cache and the slim rebuild took
30 seconds.

Lesson: **profile the image before optimizing.** `podman history --no-trunc` and a `du -sh` inside the
container tell you whether the weight is in the runtime tree (irreducible) or in build cruft (free to
drop with a stage split). For Docling, `du` showed `/app/code` was 3.3 GB while the image was 8.74 GB,
which pointed straight at the cache-in-layers problem.

### 4.4 The dlopen trap: a build that links can still fail at runtime

A build-time linkage gate (`ldd <binary>` for "not found", then `<binary> --version`) proves the
**directly linked** dependencies resolve on the base. It does **not** exercise libraries the app
`dlopen`s at runtime:

- TEI's Intel MKL math runtime loads during the first inference, not at startup. A build that links can
  fail at the first `/embed` call.
- Docling's torch, OpenCV, and the layout/OCR models are dlopen-heavy and not touched by an `import` gate.

So the build gate is necessary but not sufficient. **The real gate is a runtime smoke test that performs
a genuine operation** (embed a string, convert a PDF) on the assembled `cloudron/base` image. See
[section 11](#11-the-gates-what-to-verify-before-you-ship).

A subtle dlopen gotcha from TEI: `libiomp5.so` in the upstream image is a symlink whose target's internal
soname differs (`libomp.so.5`). Indexing it with `ldconfig` records it under the wrong name and runtime
resolution fails. The fix is `cp -L` to dereference it into a concrete file and resolve by filename via
`LD_LIBRARY_PATH`, not `ldconfig`.

### 4.5 Bake heavy assets, do not download them on first boot

If the app loads models or other large assets at boot, **bake them into the image** rather than
downloading on first run. TEI learned that a first-boot download races Cloudron's health grace window: a
slow download marks the app unhealthy before it is ready. Docling bakes the layout, TableFormer, picture
classifier, RapidOCR, and EasyOCR models at build time (`docling-tools models download`), so the app is
ready in seconds, offline, deterministic, and locked to the package build. Baked assets live under
`/app/code` (read-only at runtime), not `/app/data`, because they are reproducible from the image and do
not need backing up.

### 4.6 Other Dockerfile rules

- **`CMD`, never `ENTRYPOINT`.** `ENTRYPOINT` breaks Cloudron's debug mode (you cannot get a shell to a
  crash-looping app). Use `CMD ["/app/code/start.sh"]`.
- **`.dockerignore`, not just `.gitignore`.** The Docker build context does not consult `.gitignore`. A
  credential or local-only file can end up in the image. Verify the built image has no secrets:
  `podman run --rm <image> find /app -name '*.key' -o -name '*.env'`.
- **Move the listener to a non-privileged port** in the manifest if upstream defaults to 80 (the
  `cloudron` user cannot bind privileged ports). TEI moved 80 to 8080; Docling's upstream default 5001 is
  already fine.

---

## 5. CloudronManifest.json, field by field

The minimal required set for a custom (non-store) app is `version`, `healthCheckPath`, `httpPort`,
`manifestVersion`, `addons`. Everything else is metadata for display, but the metadata matters for the
community channel (section 10).

```json
{
  "id": "io.github.you.appname",
  "title": "App Name",
  "author": "You",
  "tagline": "One line for the store tile",
  "description": "file://DESCRIPTION.md",
  "changelog": "file://CHANGELOG.md",
  "icon": "file://logo.png",
  "version": "1.0.1",
  "upstreamVersion": "1.25.0",
  "healthCheckPath": "/health",
  "httpPort": 5001,
  "addons": { "localstorage": {}, "proxyAuth": { "path": "/ui" } },
  "memoryLimit": 4294967296,
  "configurePath": "/ui",
  "optionalSso": true,
  "postInstallMessage": "file://POSTINSTALL.md",
  "manifestVersion": 2,
  "minBoxVersion": "9.1.0",
  "iconUrl": "https://raw.githubusercontent.com/you/appname/main/logo.png"
}
```

Field notes, with the lessons:

- **`version` vs `upstreamVersion`.** `version` is your own package semver; it moves on every published
  change even if upstream did not move. `upstreamVersion` mirrors the Dockerfile `ARG`. Keep them
  distinct; operators need to tell a packaging fix from an upstream bump.
- **`manifestVersion: 2`.** The current strict schema. Use it.
- **`minBoxVersion: 9.1.0`.** This is usually **not** a statement about your app; it is the floor of the
  community **versions-url** channel, which requires `iconUrl`, which requires box 9.1.0. The app may run
  fine on 8.3; an on-server build (which uses `file://logo.png` and needs no `iconUrl`) can target lower.
  But there is no versions-url manifest below 9.1.0. Do not write a wishful lower floor; it will fail
  validation.
- **`httpPort`.** The single primary port the platform reverse-proxies on the app's main domain.
- **`httpPorts` (plural).** Declare a **second HTTP surface on its own subdomain**, not behind the SSO
  proxy. agentgateway uses this to expose a programmatic data plane (MCP and LLM API) on a `gw-api`
  subdomain while the admin UI stays behind SSO on the primary domain. Verified on Cloudron 9.1.x:
  `proxyAuth` scopes to the primary domain and does **not** extend to `httpPorts` subdomains, which is
  exactly what you want. Langfuse uses the same mechanism for a different reason: its bundled MinIO mints
  **presigned S3 URLs** for trace media, and those must resolve to a **stable external domain**, so it
  claims an `httpPorts` blob subdomain fronting MinIO. The contract is easy to misread: the manifest
  **key** is the *name of the runtime environment variable* that will hold the subdomain's FQDN (no
  scheme); `containerPort` is the port the app listens on; `defaultValue` is the subdomain prefix. Read the
  FQDN back out of that env var at boot and feed it to the app as its public S3 base URL.
- **`tcpPorts`.** Raw TCP ports for non-HTTP protocols. Cloudron does **not** terminate TLS for these;
  the app handles its own TLS. Prosody declares c2s 5222 (STARTTLS), direct-TLS 5223 (XEP-0368), s2s 5269
  (federation). Qdrant declares gRPC 6334. A raw TCP port does not route through a proxied (orange-cloud)
  Cloudflare record; the host serving it needs a DNS-only (grey-cloud) record.
- **`addons`.** Declare every external service and platform capability you need. Case matters: it is
  **`proxyAuth`** (camelCase), not `proxyauth`. The packaging reference itself had this wrong and it cost
  an install failure on two separate packages. Available addons: `localstorage`, `postgresql`, `mysql`,
  `mongodb`, `redis`, `sendmail`, `recvmail`, `ldap`, `oidc`, `scheduler`, `proxyAuth`, `tls`, `turn`.
  - **`proxyAuth` cannot be added after first install.** Declare it from day one. Retrofitting requires
    uninstall and reinstall.
  - **`proxyAuth` is path-scoped.** `{ "path": "/ui" }` walls only that path with Cloudron SSO. See
    [section 6](#6-auth-and-topology-the-crux); this is the single most important manifest decision.
  - **`localstorage`** mounts `/app/data`. Nearly every app needs it. Its `sqlite` option declares SQLite
    file paths so backups are consistent (the files must exist at backup time).
  - **`tls`** exposes certs at `/etc/certs/` (primary `tls_cert.pem` / `tls_key.pem`, and per-alias
    `<domain>.cert` / `<domain>.key` if the app has alias domains). `/etc/certs` is not backed up; copy
    certs into `/app/data` if they must survive a restore.
  - **`turn`** advertises the platform coturn to clients (Prosody, via XEP-0215).
- **`healthCheckPath`.** See [section 9](#9-health-checks-liveness-is-not-readiness). Must be reachable on
  the primary `httpPort` and return 2xx without auth.
- **`configurePath`.** Where the dashboard "Open" / "Settings" button lands. Point it at the human surface
  (`/ui`, `/docs`, the admin panel).
- **`optionalSso: true`.** Lets operators run without Cloudron SSO.
- **`checklist` and `postInstallMessage`.** Surface the facts an operator needs right after install: how
  to read the API key (`cat /app/data/.secrets/keys.env`), what header to send it as, where the UI is,
  what to expect on first boot. These reduce support load dramatically. The biggest win is a blunt
  "**there is no web page to visit, this is an API**" for headless services, which prevents the
  "I opened the domain and got a blank page" support ticket.
- **`dockerImage`.** Set at publish time to the **registry digest** (`@sha256`), never a tag. See
  [section 10](#10-releasing-and-publishing).

---

## 6. Auth and topology: the crux

This is where packages most often go wrong, and where the design has to be deliberate.

Most of these apps serve **two kinds of traffic on one app**:

- **Human surfaces** (a demo UI, Swagger docs, an admin dashboard) that benefit from Cloudron SSO.
- **Programmatic surfaces** (the convert/embed/query API, MCP, gRPC) that **cannot** complete an
  interactive login.

The rule:

> **Wall only the human surfaces with `proxyAuth`, path-scoped. Leave the programmatic API open at the
> network layer and protect it with the app's own key. Never put the SSO wall in front of the API.**

If you wall the API with `proxyAuth`, every programmatic client gets a `302` redirect to a login page
instead of a `401`, and every integration breaks: the client cannot follow an HTML login form.

How each package split it:

- **Docling:** `proxyAuth` on `/ui` only. `/health` open. `/docs`, `/openapi.json`, `/version` app-open.
  `POST /v1/convert/*` protected by the API key as the **`X-Api-Key`** header (not Bearer). An
  unauthenticated convert returns docling-serve's own `401`, not a login redirect.
- **TEI:** `proxyAuth` on `/docs` only. The embedding API (`/embed`, `/v1/embeddings`, `/rerank`,
  `/info`) is key-protected with an `Authorization: Bearer` token. `/health` open.
- **Qdrant:** `proxyAuth` on `/dashboard` only. REST (`/collections`, `/points`), `/metrics`, and gRPC
  are key-protected. A separate **read-only key** (403 on writes) can be handed to query-only clients.
- **agentgateway:** admin UI on the primary domain behind `proxyAuth`; data plane on a separate `httpPorts`
  subdomain with the app's own API key, no proxy wall.
- **Prosody:** not web auth at all. Users authenticate over XMPP via SASL, bound to the Cloudron user
  directory through the `ldap` addon. Cloudron SSO (a web cookie) is irrelevant to an XMPP client.
- **Langfuse:** a third topology — the app has its **own** login system, so rather than wall it with
  `proxyAuth` you hand the app the **`oidc` addon** and let it run the OIDC dance itself. Cloudron injects
  `CLOUDRON_OIDC_*` (issuer, client id/secret, and the callback URL you declared in the manifest as
  `oidc.loginRedirectUri`); the entrypoint maps those to the app's own names (Langfuse's `AUTH_CUSTOM_*`).
  The public **ingestion** paths (`/api/public/*`, the OTLP trace endpoint) stay **open at the network
  layer** and are protected by per-project API keys — the same rule as any programmatic API, because SDKs
  and OpenTelemetry collectors cannot complete an interactive login either. **Decision rule:** `proxyAuth`
  when the app has no auth of its own; the `oidc` (or `ldap`) addon when it does, and never put either in
  front of the token-authenticated ingestion API.

Two traps:

- **`supportsBearerAuth` on a proxyAuth path weakens the wall.** This flag tells the proxy to forward any
  request carrying an `Authorization: Bearer` header instead of redirecting to login. Verified on the
  box: with it set, **any** bearer header, even a dummy, bypasses the SSO wall. Only set it if the path
  behind the wall genuinely also fronts a Bearer API. For a UI-only wall, leave it off, or it just opens a
  hole. (Qdrant does set it on `/dashboard` deliberately; TEI and Docling deliberately do not.)
- **Know the exact header.** docling-serve wants `X-Api-Key`, TEI wants `Authorization: Bearer`. Setting
  the wrong manifest flag (`supportsBearerAuth` for an `X-Api-Key` app) only weakens the wall and helps
  nothing.

---

## 7. Secrets and state

### 7.1 The generated key

Generate one strong key on first run, store it under `/app/data`, inject it through the environment, and
never log it:

```bash
SECRETS_DIR="${DATA}/.secrets"; KEYS_ENV="${SECRETS_DIR}/keys.env"
mkdir -p "${SECRETS_DIR}"; chmod 0700 "${SECRETS_DIR}"
if [[ ! -f "${KEYS_ENV}" ]]; then
  GEN_KEY="$(openssl rand -hex 32)"
  ( umask 077; printf 'APP_API_KEY=%s\n' "${GEN_KEY}" > "${KEYS_ENV}" )
  unset GEN_KEY
fi
chown cloudron:cloudron "${KEYS_ENV}"; chmod 0600 "${KEYS_ENV}"   # re-assert every boot, see 7.2
set -a; . "${KEYS_ENV}"; set +a
export APP_API_KEY
```

- **First-run-only and idempotent.** Generate only if the file is absent. Restarts and updates must never
  reseed; integrators may have the key configured, and reseeding breaks them.
- **Some keys are data-loss-critical, not just auth.** A reseeded *API* key only breaks integrators until
  they re-copy it. But a key that **encrypts stored data** — Langfuse's 64-hex `ENCRYPTION_KEY` encrypts
  trace payloads and API-key hashes — makes **all existing data permanently unreadable** if it is ever
  regenerated. For those the idempotent-seed rule is the difference between an update and a silent data
  wipe. Guard the format too (Langfuse fails fast unless the key is exactly 64 hex chars), seed once, and
  prove across a real update **and** restore that the key is **byte-identical** (same sha256), not merely
  present.
- **Inject via environment, not a CLI flag.** A flag shows in `ps`; an environment variable does not.
- **`0600` inside a `0700` directory.**

### 7.2 The restore mode-drift lesson (Docling)

A Cloudron **restore returns `keys.env` as `0644`**, not the `0600` it was created with (verified
empirically). The `0700` parent directory still blocks traversal, so it is not exploitable, but the file
mode is looser than intended. The original entrypoint only `chmod 0600`'d the key in the first-run
branch, so the drift was never corrected. **Fix: re-assert ownership and mode on every boot**, outside the
first-run branch, as in the snippet above. This is the general pattern: a restore can reset ownership and
modes across `/app/data`, so assert them every boot, not just at creation.

### 7.3 Everything persistent under /app/data

It is the only backed-up location. What lives there across the five packages:

- the key (`/app/data/.secrets/keys.env`)
- model and dependency caches (`HF_HOME`, the venv cache, npx/uvx caches for stdio backends)
- databases (Qdrant `storage/`, Prosody SQLite, app SQLite)
- operator-editable config (`config.yaml`, `production.yaml`)
- certs that must survive a restore (copied out of `/etc/certs`)

Redirect the app's caches there with environment variables (`HOME`, `HF_HOME`, `XDG_CACHE_HOME`,
`UV_CACHE_DIR`, `npm_config_cache`). agentgateway's stdio MCP backends (`npx`, `uvx`) would otherwise
cache into the read-only rootfs (fail) or `/tmp` (re-download every restart).

### 7.4 Force infrastructure via environment, never bake addon values

Addon connection details change on restart. Translate `CLOUDRON_*` addon variables to the app's expected
names **on every boot** (Prosody re-runs its `cloudron-env` mapping each start). Never write addon values
into a static config baked in the image.

For apps whose UI rewrites their own config file (agentgateway), **re-assert the critical fields on every
boot** (it added `yq` to the image purely to re-assert `adminAddr`, because the UI's save dropped it back
to a localhost default and made the app unreachable). A single first-run seed is not enough when the app
can rewrite the file.

### 7.5 Disable telemetry and lock down insecure defaults

Self-hosted means no phone-home. Docling sets `HF_HUB_DISABLE_TELEMETRY=1` and `DO_NOT_TRACK=1` so
huggingface_hub stops fetching its agent-harness manifest on boot. Qdrant ships insecure-by-default
(open API, telemetry on, SSRF-prone snapshot URL recovery); the package force-sets
`QDRANT__SERVICE__API_KEY`, `telemetry_disabled: true`, `service.enable_snapshot_url_recovery: false` via
environment so the operator cannot accidentally leave it open.

### 7.6 Config that references environment variables is a footgun

agentgateway interpolates `$VAR` from the raw config text **including inside comments**. A commented-out
`$OPENAI_API_KEY` example stopped the app at boot. Ship a default config with **no** environment
references, and have the entrypoint fail fast with a clear message if a referenced variable is unset.

---

## 8. start.sh: the canonical entrypoint

The shape that all five converged on:

```bash
#!/bin/bash
set -euo pipefail                       # fail fast, unset vars fatal, pipe failures propagate

CODE=/app/code; DATA=/app/data
echo "==> [start] app ${VERSION} booting"      # every package line prefixed ==> for greppable logs

# 1. Ownership and layout first. A restore can reset both, so fix before any app logic.
mkdir -p "${DATA}/..."; chown -R cloudron:cloudron "${DATA}"

# 2. First-run-only secret + config seeding (idempotent; never clobber).
#    Re-assert secret ownership/mode every boot (restore drifts them).

# 3. Map CLOUDRON_* addon vars to the app's names (every boot; they change).
# 4. Re-assert any critical config field the app's own UI might have dropped.
# 5. Export package-forced settings (host 0.0.0.0, port, key, cache paths under /app/data).
# 6. Size thread pools to the cgroup CPU allotment, not nproc (see below).

echo "==> [start] http 0.0.0.0:${PORT}  key $( [[ -s "${KEYS_ENV}" ]] && echo present || echo MISSING )"
exec gosu cloudron:cloudron "${BIN}" run     # exec for signal propagation; gosu drops privileges
```

The load-bearing conventions:

- **`set -euo pipefail`** and **`==>` log markers** on every package-emitted line, so an operator can
  `cloudron logs -f | grep '==>'` and see only the setup phases.
- **Run as root for setup, then `exec gosu cloudron:cloudron`.** Root is needed to `chown /app/data`
  (Cloudron mounts it after the container starts and a restore resets ownership). `gosu` is lighter than
  `sudo` and does not spawn a shell. **`exec`** so SIGTERM reaches the app and it shuts down cleanly.
- **`chown -R cloudron:cloudron /app/data` early, every boot.** The most common restore bug is files
  owned by root after a clone.
- **Idempotent seeding.** Seed the key and config only if absent. Never overwrite the operator's config on
  restart or update.
- **Bind explicitly to `0.0.0.0`.** Docker and Cloudron set `HOSTNAME` to the container id. An app that
  binds `$HOSTNAME` by default tries to bind the container id as an interface and fails. Pass
  `--hostname 0.0.0.0` (TEI) or `UVICORN_HOST=0.0.0.0` (Docling).
- **Cgroup-aware concurrency.** Size thread pools to the container's CPU allotment, not the host's
  `nproc`:
  ```bash
  CPUS="$(nproc 2>/dev/null || echo 2)"
  if [[ -r /sys/fs/cgroup/cpu.max ]]; then
    read -r CQ CP < /sys/fs/cgroup/cpu.max || true
    if [[ "${CQ:-max}" != "max" && "${CP:-0}" -gt 0 ]]; then C=$(( CQ / CP )); (( C >= 1 )) && CPUS=$C; fi
  fi
  ```
- **Echo resolved facts, never secrets.** Print the port, cache paths, thread count, and key
  *presence* (`present` / `MISSING`), never the key.
- **Validate config with the app's own validator before exec** (agentgateway runs `--validate-only`, and
  only `migrate`s if validation fails, then fails loud if still broken, so it never silently destroys the
  operator's config).
- **Pass operator-tunable settings conditionally.** Package-forced settings (host, port, key) are always
  set; optional knobs (`APP_REVISION`, thread count) are applied only if the operator provides them.

A note on `set -e` with `cloudron exec`: when you exec into a running app from the CLI, the command needs
a TTY. Wrap it: `script -qefc "cloudron exec --app <app> -- <cmd>" /dev/null`.

---

## 9. Health checks: liveness is not readiness

Cloudron polls `healthCheckPath` on the **primary `httpPort`** and kills and restarts the container if it
persistently returns non-2xx. Two hard rules and one trap:

1. **The path must be reachable on the primary httpPort.** agentgateway's `/healthz/ready` lived on a
   separate listener port Cloudron cannot reach; it had to use `/ui/` (served by the primary listener).
   You cannot health-check a port the reverse proxy does not map.
2. **The path must return 2xx without auth.** Cloudron cannot present your API key or log in. Verify
   empirically that the health path is exempt from the app's auth (every package confirmed this on the
   box).
3. **The restart-loop trap: use liveness, not readiness.** Qdrant's `/readyz` returns 503 while shards
   load; on a large collection that 503 makes Cloudron restart the app mid-load, an infinite loop. Use
   `/healthz`, which returns 200 as soon as the listener binds. Pick the endpoint that means "the process
   is alive and accepting connections", not "every feature is ready".

The **first-boot grace** is finite. If the app downloads a large model or runs long migrations on first
boot, it can blow the grace window and be killed before it is ready. Two fixes: **bake the assets** so
there is no download (section 4.5), or front the slow app with an Nginx location that returns 200
immediately while the backend warms up (the reference pattern in Appendix B).

There is a related platform timeout worth knowing (agentgateway's retrospective): the **reverse proxy cuts
a slow request at about 60 seconds**, and it is not per-app configurable. A cold-model inference call can
hit it. Mitigations: keep the backend warm (`OLLAMA_KEEP_ALIVE=24h`), prefer streaming responses (each
token resets the read window), or call `localhost:<port>` from inside the container to bypass the proxy
for long internal calls.

---

## 10. Releasing and publishing

The community distribution channel is a `CloudronVersions.json` file served at a public raw URL, which a
stranger installs from with `cloudron install --versions-url <url> --location app.example.com`.

### 10.1 Build, push, and the digest

```bash
podman build -t ghcr.io/you/appname:1.0.1 .
podman push ghcr.io/you/appname:1.0.1
# Read the REGISTRY digest, not the local build digest, they differ:
skopeo inspect --format '{{.Digest}}' docker://ghcr.io/you/appname:1.0.1
```

- **Pin `dockerImage` to the registry digest**, in both `CloudronManifest.json` and
  `CloudronVersions.json`. The local `podman build` digest is not what the registry stores; only
  `skopeo inspect` (or the push output / `--digestfile`) gives the canonical digest.
- **Large pushes drop and retry.** Docling's 6 GB push hit repeated `EOF` errors mid-layer; podman
  retried and the blobs landed, but the first tag's manifest write failed (exit 125) while a second tag
  (`:latest`, pushed right after, sharing the now-uploaded blobs) succeeded. The fix is simply to
  **re-push the failed tag**: the blobs are already up, so it only writes the manifest and completes in
  seconds. Use `--digestfile` to capture the digest reliably.
- **A fully-cached rebuild cannot be pushed** (agentgateway): if nothing in the image filesystem changed
  (a manifest-only edit, e.g. icon or description), BuildKit keeps the result in cache only and the push
  reports "image not known". The digest is unchanged, so reuse the existing one rather than rebuilding.

### 10.2 GHCR visibility is a manual, one-time UI action

A freshly pushed GHCR package is **private**, and **there is no REST API to make a user-owned package
public** (a `PATCH .../visibility` returns 404). Flip it once in the web UI: the package's settings,
Danger Zone, Change visibility, Public. Until you do, neither the box nor strangers can pull it.

Detecting public-vs-private correctly is itself a trap: a naked `GET .../manifests/<tag>` returns **401
for both** public and private images, because the registry requires an anonymous token handshake even for
public pulls. Test it properly with the token dance, or with `podman pull` while logged out:

```bash
podman logout ghcr.io
podman manifest inspect ghcr.io/you/appname:1.0.1   # succeeds (returns the manifest) only if public
```

### 10.3 CloudronVersions.json schema

```json
{
  "stable": true,
  "versions": {
    "1.0.1": {
      "manifest": { ...the full manifest, INLINED... , "dockerImage": "ghcr.io/you/appname@sha256:..." },
      "creationDate": "2026-06-26T08:08:04.976Z",
      "ts": 1782418084976,
      "publishState": "published"
    }
  }
}
```

- The manifest is **inlined**, with the `file://` fields (`description`, `changelog`,
  `postInstallMessage`) expanded to their content. `icon` stays `file://logo.png`; `iconUrl` is the
  store-facing icon. Generate this from the repo files with a script so escaping is correct.
- The schema is **stricter** than `CloudronManifest.json`: it requires a valid `contactEmail`, a non-empty
  `iconUrl`, at least one `mediaLinks` entry, and the changelog in **bracket format** (`[1.0.1]` at line
  start, parsed literally) rather than markdown `## 1.0.1`.

### 10.4 Install and update mechanics

- `cloudron install --versions-url <url> --location app.example.com` is the stranger path. The same
  command "installs or updates"; the manifest comes from the versions file.
- `cloudron update --app <app> --image <ref>` updates an existing app to a specific image and **auto-backs
  up first** (the safe path that definitely preserves `/app/data`). It reuses the app's **stored
  manifest** and swaps the image, so the dashboard version label can lag the image unless the manifest is
  also updated through the versions channel.
- A **local build service** (`cloudron build` with `Build service type: local`) builds on the machine and
  references the image as `local/<manifest-id>:<version>-<timestamp>`; the manifest comes from the repo's
  `CloudronManifest.json` at build time, which is why a box installed this way carries a stored manifest
  even though the image filesystem has no manifest in it.

### 10.5 Anonymity sweep before every push

No personal hostname, email, username, internal URL, or token in any tracked file. A mechanical
`test/secret-scan.sh` over the tracked set, run as a release gate. It catches your own slips: while
writing Docling's notes the real box hostname was typed into a doc and the scan caught it before the
public push. Keep box-specific docs gitignored; keep the anonymized record in `docs/PACKAGING-NOTES.md`.

---

## 11. The gates: what to verify before you ship

A change is not done until the relevant gate passes. The ladder, cheapest first:

1. **Build linkage gate** (in the Dockerfile): `ldd <binary>` has no "not found"; `<binary> --version`
   exits 0; or for a Python app, `python -c "import the, modules"`. Proves direct deps resolve on the
   base. **Necessary, not sufficient** (does not exercise dlopen).
2. **Runtime smoke test** (`test/smoke.sh`): build the image, run it the way Cloudron does (root entry,
   `gosu cloudron`), and assert the real behavior on the assembled base:
   - the app drops to the `cloudron` user;
   - the generated key is the expected length;
   - `/health` returns 200 with no key;
   - the API returns 401 without the key and the correct result with it (embed a string, convert a PDF);
   - the key is not in the logs.
   This is the gate that catches dlopen failures. Re-run on every Dockerfile, entrypoint, or version
   change.
3. **Secret scan** (`test/secret-scan.sh`): no personal data in tracked files.
4. **Read-only / runs-as / CPU-build verification** on a real or local run: root is mounted read-only,
   a write to `/app/code` fails, the process runs as `cloudron`, torch is `+cpu` with
   `cuda.is_available()` false.
5. **Update survival**: `cloudron update` the live app and confirm the key is byte-identical (same
   sha256), the caches survive, ownership is correct, and the topology still holds. (Docling: verified the
   key sha256 unchanged and the `0600` re-assert now applied, across a real GHCR-image update.)
6. **Backup/restore survival**: `cloudron backup create` then `cloudron restore` (restoring the
   just-taken backup is net-zero state), and confirm the key, caches, ownership, and topology survive, and
   the entrypoint takes the "existing key found" path rather than regenerating.
7. **Anonymous pull by digest** (after publish): logged out, `podman pull <image>@sha256:...` succeeds,
   proving the package is public.
8. **Stranger install** from the published versions URL on a throwaway subdomain: it reaches healthy, the
   icon shows, the human surface is behind login, and the API serves with the key. Then uninstall.

Two meta-lessons: **update and restore are separate tests** (update preserves a live app's data; restore
recovers a fresh app from a backup, exercising the ownership/mode re-assertion), and **schema migrations
stay unproven until a real schema change ships**, so make the migration a standing gate even when no
schema change is documented.

---

## 12. Debugging on the box

- `cloudron logs -f --app <app>` streams stdout/stderr. Grep `==>` for the package's own phases.
- `cloudron exec --app <app> -- <cmd>` opens a shell in the running container. It needs a TTY; wrap it:
  `script -qefc "cloudron exec --app <app> -- <cmd>" /dev/null`.
- `cloudron debug --app <app>` pauses the container (does not run `CMD`), makes the filesystem read-write,
  and lifts the memory limit. Use it when the app crash-loops and `exec` will not stay connected. Inside,
  `find / -mmin -30` discovers every path the app tried to write, which is how you find the symlinks you
  still need. Disable with `cloudron debug --disable`.
- `cloudron inspect` (no `--app`) dumps the whole installation as JSON; extract your app's record to see
  its stored manifest version, `installationState`, and `dockerImage` (this is how Docling discovered the
  box ran a `local/...` image with a stored 1.0.0 manifest).
- **`cloudron list` shows desired state, not the live container.** Langfuse trap: after a bad config and
  restart, `list` can report `running` while the container is actually crash-looping (`cloudron exec`
  returns `409 container is restarting`). Trust **exec responsiveness and a real request**, not the `list`
  label, when deciding whether a restart took. (The matching fix — `cloudron debug` to restore a known-good
  config in `/app/data` — is the bullet above.)
- **For a silent integration failure, read the *emitter's* own debug log first.** When app A's exports do
  not show up in app B, A's debug log is the shortcut. `RUST_LOG=...,h2=debug` made agentgateway log the
  literal body Langfuse returned — `400 "The plain HTTP request was sent to HTTPS port"` — which beat ~20
  receiver-side reproductions. Diagnose from the sender, not the receiver.

---

## 13. Decision framework: is this app a good fit

1. **Find the real dependency map.** Read the upstream `docker-compose.yml` or multi-service deploy guide,
   not the monolithic all-in-one image. The compose file reveals the true dependencies (which databases,
   caches, brokers, workers).
2. **Map dependencies to addons.** Postgres, MySQL, MongoDB, Redis, SMTP, IMAP, LDAP, OIDC all have
   addons. RabbitMQ/AMQP does **not**: use Redis as the broker if the app supports it, else run a
   lightweight broker (LavinMQ) inside the container under Supervisor. Object storage has no addon (use
   the filesystem or external S3).
3. **Count the processes.** One web server is trivial (`exec` it). Web plus a couple of workers plus a
   scheduler is manageable with Supervisor (each program logging to stdout). More than five or six
   distinct processes suggests a poor fit without real effort.
4. **Start from `cloudron/base`, install the app onto it.** Almost always the right call. Use a multi-stage
   `COPY --from` of compiled artifacts only when the build toolchain is exotic. **Never start from the
   upstream monolithic image and strip it down**; you end up fighting its assumptions about services it
   expects to own (the docassemble lesson).
5. **Ask whether the app even fits the web model.** Prosody (XMPP) needed three TCP ports with different
   TLS modes, SASL-over-LDAP auth that Cloudron SSO cannot touch, per-component certs, and an upstream
   firewall opened for TURN relay. It works, but the packaging is a different shape: most of the effort is
   ports, certs, and addon env mapping, not a web app. Budget for that before committing.

---

## 14. Gotcha catalog (quick reference)

| # | Gotcha | Fix |
|---|--------|-----|
| 1 | Build links but the app fails at first real call (dlopen libs not in `ldd`) | Runtime smoke test that does a genuine operation, not just a build gate |
| 2 | Bare/`latest` tag is the CUDA image, not CPU | Use the `cpu-` tag; install CPU torch from the CPU index first |
| 3 | `libiomp5.so` symlink resolves wrong via ldconfig | `cp -L` to a concrete file, resolve via `LD_LIBRARY_PATH` |
| 4 | `HOSTNAME` is the container id; app binds it and fails | Bind `0.0.0.0` explicitly |
| 5 | First-boot model download blows the health grace | Bake assets into the image |
| 6 | `/readyz` returns 503 mid-load, Cloudron restart-loops | Health-check `/healthz` (liveness), not readiness |
| 7 | Health path on a non-primary port is unreachable | Use a path on the primary `httpPort` |
| 8 | `proxyAuth` in front of the API redirects clients to login | Path-scope `proxyAuth` to human surfaces only |
| 9 | `supportsBearerAuth` opens the SSO wall to any dummy bearer | Only set it if the walled path also fronts a Bearer API |
| 10 | `proxyauth` (lowercase) fails manifest validation | It is `proxyAuth` (camelCase) |
| 11 | `proxyAuth` cannot be added after install | Declare it from day one |
| 12 | Restore returns `keys.env` as `0644` and resets ownership | Re-assert chown + `chmod 0600` every boot, not just first run |
| 13 | The app's UI rewrites config and drops a critical field | Re-assert critical fields every boot (yq) |
| 14 | Config interpolates `$VAR` even in comments; unset var halts boot | Ship a config with no env references; fail fast with a clear message |
| 15 | `.gitignore` does not protect the Docker build context | Use `.dockerignore`; scan the built image for secrets |
| 16 | Secrets visible in `ps` when passed as flags | Inject via environment variable |
| 17 | npx/uvx cache into read-only rootfs or ephemeral /tmp | Point HOME/XDG/UV/npm caches under `/app/data` |
| 18 | Local podman digest != registry digest | Read the digest with `skopeo inspect` after push |
| 19 | Fresh GHCR package is private; no API to make it public | Flip it once in the GitHub Packages UI |
| 20 | Naked manifest GET is 401 for public images too | Test publicness with the token dance or a logged-out pull |
| 21 | 6 GB push drops with EOF and "fails" | Blobs are up; re-push the tag (writes only the manifest) |
| 22 | Manifest-only change cannot be re-pushed (cache only) | Reuse the existing digest |
| 23 | `minBoxVersion` is really gated by `iconUrl` (9.1.0) | Set 9.1.0 honestly for the versions-url channel |
| 24 | versions-url changelog must be `[x.y.z]`, not `## x.y.z` | Use bracket format |
| 25 | `ENTRYPOINT` breaks Cloudron debug mode | Use `CMD` |
| 26 | Image is huge; weight is build cache in layers, not the app | Two-stage; `COPY --from` only the installed tree |
| 27 | gRPC/raw TCP will not pass a proxied Cloudflare record | DNS-only (grey-cloud) record for that host |
| 28 | SASL PLAIN disabled in XMPP clients; login fails silently | Document enabling PLAIN (safe over TLS) for LDAP bind auth |
| 29 | Insecure upstream defaults (open API, telemetry, SSRF) | Force-set secure env on every boot |
| 30 | Reverse proxy cuts slow requests at ~60s, not per-app tunable | Keep backend warm, stream, or call localhost internally |
| 31 | Upstream binaries are musl (Alpine) but the base is glibc | Run them in place via an isolated musl loader (`/opt/musl/lib`, `ld-musl path`); the ELF interpreter is per-binary so they coexist |
| 32 | Prisma re-detects the OS and grabs a glibc engine on Ubuntu | Override with `PRISMA_QUERY_ENGINE_LIBRARY` / `PRISMA_SCHEMA_ENGINE_BINARY` on version-agnostic symlink paths |
| 33 | A required store has no Cloudron addon (ClickHouse, S3/object) | Bundle it under Supervisor, bind localhost, data under `/app/data`; use addons for Postgres/Redis/etc. |
| 34 | App has its own login but you reach for `proxyAuth` | Use the `oidc` (or `ldap`) addon, map `CLOUDRON_OIDC_*` to the app's vars; keep the ingestion API open with its own keys |
| 35 | A data-encryption key reseeded on update wipes all data | Idempotent first-run seed; verify byte-identical (sha256) across update **and** restore; guard the format |
| 36 | `&>` or other bashism under `/bin/sh` (dash) fails silently | Run the script with `bash`, not `sh` |
| 37 | A bundled DB server binds `0.0.0.0` by default | Strip the docker/all-interfaces config; bind localhost (+ `::1`) |
| 38 | A client's OTLP/HTTP exporter sends cleartext to the TLS :443 | nginx returns `400 "plain HTTP sent to HTTPS port"`; force the HTTP-protobuf exporter (not gRPC) and confirm it negotiates TLS |

---

## Appendix A: base image inventory (Cloudron 9.1.3)

`cloudron/base:5.0.0`, Ubuntu 24.04.1 LTS, kernel 6.8. "Batteries included": developer productivity over
disk economy. Verified on a live box.

**On PATH by default:** Node.js 24.13.1 (Node 22.14.0 LTS also at `/usr/local/node-22.14.0`; set PATH to
use it), Python 3.12.3 + pip 24.0, PHP 8.3.6 (apcu, bcmath, curl, gd, gmp, imagick, imap, intl, ldap,
mbstring, mysqli, pdo_*, pgsql, redis, soap, sodium, sqlite3, xml, xsl, zip, zmq, and more).

**Servers and process tools:** Nginx 1.24.0, Apache 2.4.58, Supervisor 4.2.5, gosu 1.17, tini.

**DB clients:** psql 16.6, mysql 8.0.41, redis-cli 7.4.2, mongosh 2.4.0.

**Common tools:** curl 8.5.0, git 2.43.0, jq 1.7, yq 4.45.1, ImageMagick 6.9.12, ffmpeg 6.1.1,
gcc/g++ 13.3.0, make 4.3, cmake 3.28.3.

**NOT installed (add in the Dockerfile if needed):** Ruby, Go, Java, Rust, pandoc, wkhtmltopdf, PM2. No
running services (databases come from addons). The `cloudron_psql` / `cloudron_mysql` convenience aliases
were announced but are not reliably present; do not depend on them.

**Always-available platform env:** `CLOUDRON=1`, `CLOUDRON_APP_DOMAIN`, `CLOUDRON_APP_ORIGIN` (includes
`https://`), `CLOUDRON_API_ORIGIN`, `CLOUDRON_PROXY_IP`. Addon env follows `CLOUDRON_<ADDON>_*`.

Read the real memory limit from cgroups at runtime rather than assuming:
```bash
mem=$(cat /sys/fs/cgroup/memory.max 2>/dev/null || cat /sys/fs/cgroup/memory/memory.limit_in_bytes)
```

---

## Appendix B: copy-paste templates

### B.1 Dockerfile, single-binary copy with linkage gate

```dockerfile
FROM ghcr.io/upstream/app:cpu-1.9@sha256:... AS upstream

FROM cloudron/base:5.0.0@sha256:04fd70dbd8ad6149c19de39e35718e024417c3e01dc9c6637eaf4a41ec4e596c
ARG APP_VERSION=1.9
ENV APP_VERSION=${APP_VERSION}
COPY --from=upstream /usr/local/bin/app /app/code/app
COPY --from=upstream /usr/local/lib/*.so* /usr/local/lib/
ENV LD_LIBRARY_PATH=/usr/local/lib
# Build-time linkage gate: fail the build if the binary does not resolve on the base.
RUN ldd /app/code/app | grep -q 'not found' && { echo 'unresolved libs'; exit 1; } || true
RUN /app/code/app --version
COPY start.sh /app/code/start.sh
RUN chmod 0755 /app/code/start.sh
CMD [ "/app/code/start.sh" ]
```

### B.2 Dockerfile, two-stage slim for a fat stack (the Docling pattern)

```dockerfile
# Builder: install everything; uv's download cache stays in this throwaway stage.
FROM cloudron/base:5.0.0@sha256:04fd70...596c AS builder
ARG APP_VERSION=1.25.0
RUN apt-get update && apt-get install -y --no-install-recommends \
      python3.12 python3.12-venv python3.12-dev ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*
ENV VENV=/app/code/venv PATH=/app/code/venv/bin:$PATH
RUN python3.12 -m venv $VENV && $VENV/bin/pip install --no-cache-dir uv
RUN $VENV/bin/uv pip install --python $VENV/bin/python --index-url https://download.pytorch.org/whl/cpu torch
RUN $VENV/bin/uv pip install --python $VENV/bin/python "app[extras]==${APP_VERSION}"
RUN $VENV/bin/app-tools models download -o /app/code/models && chmod -R a+rX /app/code/models

# Runtime: COPY only the installed tree. Drops the build cache and copy-up layers.
FROM cloudron/base:5.0.0@sha256:04fd70...596c
ARG APP_VERSION=1.25.0
ENV APP_VERSION=${APP_VERSION} VENV=/app/code/venv PATH=/app/code/venv/bin:$PATH
RUN apt-get update && apt-get install -y --no-install-recommends \
      python3.12 python3.12-venv libgl1 libglib2.0-0 libgomp1 ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=builder /app/code/venv  /app/code/venv
COPY --from=builder /app/code/models /app/code/models
COPY start.sh /app/code/start.sh
RUN chmod 0755 /app/code/start.sh \
    && $VENV/bin/python -c "import app, torch; print('ok', torch.__version__)"
CMD [ "/app/code/start.sh" ]
```

### B.3 start.sh skeleton

```bash
#!/bin/bash
set -euo pipefail
CODE=/app/code; DATA=/app/data
SECRETS_DIR="${DATA}/.secrets"; KEYS_ENV="${SECRETS_DIR}/keys.env"
VERSION="${APP_VERSION:-unknown}"
echo "==> [start] app ${VERSION} booting"

mkdir -p "${SECRETS_DIR}" "${DATA}/cache"
chown -R cloudron:cloudron "${DATA}"
chmod 0700 "${SECRETS_DIR}"

if [[ ! -f "${KEYS_ENV}" ]]; then
  echo "==> [start] first run: generating API key"
  GEN_KEY="$(openssl rand -hex 32)"
  ( umask 077; printf 'APP_API_KEY=%s\n' "${GEN_KEY}" > "${KEYS_ENV}" )
  unset GEN_KEY
else
  echo "==> [start] existing API key found"
fi
chown cloudron:cloudron "${KEYS_ENV}"; chmod 0600 "${KEYS_ENV}"   # re-assert every boot

set -a
# shellcheck source=/dev/null
. "${KEYS_ENV}"
set +a
export APP_API_KEY
export HOME="${DATA}" XDG_CACHE_HOME="${DATA}/cache"
export APP_HOST=0.0.0.0 APP_PORT="${APP_PORT:-8000}"

CPUS="$(nproc 2>/dev/null || echo 2)"
if [[ -r /sys/fs/cgroup/cpu.max ]]; then
  read -r CQ CP < /sys/fs/cgroup/cpu.max || true
  if [[ "${CQ:-max}" != "max" && "${CP:-0}" -gt 0 ]]; then C=$(( CQ / CP )); (( C >= 1 )) && CPUS=$C; fi
fi
export APP_THREADS="${APP_THREADS:-${CPUS}}"

echo "==> [start] http 0.0.0.0:${APP_PORT}  threads ${APP_THREADS}  key $( [[ -s "${KEYS_ENV}" ]] && echo present || echo MISSING )"
exec gosu cloudron:cloudron "${CODE}/app" run
```

### B.4 Nginx immediate-health pattern (for slow-starting backends)

```nginx
server {
    listen 8000;
    location = /health { access_log off; return 200 'ok'; add_header Content-Type text/plain; }
    location / {
        proxy_pass http://127.0.0.1:8001;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 86400;
    }
}
```

### B.5 smoke.sh assertions (the real gate)

Build the image, run it Cloudron-style (root entry, `gosu cloudron`), wait for ready, then assert:
`runs as cloudron`; key length is as expected; `/health` is 200 with no key; the API is 401 without the
key and returns the correct result with it (a genuine operation, not a ping); the key is absent from the
logs. Exit non-zero on any failure. This is the gate that catches the dlopen class of bug.

---

*Field guide v0.1.2, synthesized June 2026 from the TEI, Qdrant, agentgateway, Prosody, Docling, and
Langfuse Cloudron packaging efforts. The base-image inventory and runtime contract are carried forward from
the earlier cloudron-packaging reference (verified March 2026); the lessons are from shipping the six
packages. v0.1.2 adds Langfuse — the first stateful multi-service web app: build Shape C (musl-on-glibc),
bundling stores that have no addon, app-native OIDC SSO, the data-loss-critical encryption key, and the
cleartext-to-TLS exporter trap.*
