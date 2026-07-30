# Windmill for Cloudron

A [Cloudron](https://cloudron.io) community package for [Windmill](https://www.windmill.dev) —
the open-source developer platform that turns scripts (Python / TypeScript / Go / Bash / SQL) into
webhooks, scheduled jobs, multi-step flows and auto-generated UIs.

Pinned to Windmill **Community Edition v1.741.0**, run **unmodified**.

> **Unofficial community package.** Maintained by its packager — **not affiliated with, endorsed by,
> or supported by [Windmill Labs](https://www.windmill.dev)**. It orchestrates the official Windmill
> Community Edition binary **unmodified**; report *packaging* issues here and Windmill product issues
> upstream.
>
> **Scope: single-node, small-team.** It runs Windmill's supported **server + worker** split
> co-located in one Cloudron container, scaling workers by the memory you allocate — it is **not** a
> substitute for a horizontally-scaled, multi-node Windmill deployment for high availability or heavy
> throughput.

## Design in one paragraph

A single container runs Windmill as a dedicated API/UI **server** process plus one or more dedicated
**worker** processes — the same server/worker split Windmill ships in its docker-compose, co-located
here rather than the dev-only `MODE=standalone` — alongside a **bundled PostgreSQL 16** and **nginx**,
all under supervisor. The worker count scales with the memory limit you give the app. nginx answers
`/health` immediately (so the app stays healthy while first-boot migrations run) and reverse-proxies
everything else to the server. All durable state — the PostgreSQL data directory and the language
dependency caches — lives under `/app/data` and is captured by Cloudron backups.

PostgreSQL is **bundled rather than using the `postgresql` addon** because Windmill requires
superuser-grade privileges the addon cannot grant (`CREATE ROLE … BYPASSRLS`, `CREATE EXTENSION
uuid-ossp`, runtime `SET ROLE`). The only addon-compatible alternative is patching the Windmill
binary, which the Windmill CE license and our packaging rules forbid. See
[`docs/decisions/0003-bundled-postgres.md`](docs/decisions/0003-bundled-postgres.md).

## Repository layout

```
Dockerfile             cloudron/base final stage; COPY the unmodified CE binary + runtimes
start.sh               entrypoint: PG bootstrap, env mapping, supervisor handoff
supervisord.conf       postgres + windmill-server + nginx (worker units generated per-boot)
nginx.conf             /health 200 + reverse proxy with websockets
CloudronManifest.json  the package contract
logo.png               canonical Windmill mark (256×256)
DESCRIPTION.md CHANGELOG POSTINSTALL.md NOTICE   store + legal metadata
docs/                  ADRs, PLAN.md, PACKAGING-NOTES.md, LEARNINGS.md, reference/
test/                  smoke.sh (runtime gate), secret-scan.sh (anonymity gate)
```

## Building and testing locally

```bash
podman build -t local/windmill-cloudron:dev .
test/smoke.sh local/windmill-cloudron:dev     # builds nothing; runs the image Cloudron-style and asserts
test/secret-scan.sh                            # no box hostnames / tokens / internal URLs in tracked files
```

## Releasing (community store channel)

The install/update channel is `CloudronVersions.json` at this repo's raw URL, listed on
[ca.cloudron.io](https://ca.cloudron.io). It is maintained with the **cloudron CLI**
(`npm i -g cloudron`), not by hand or by a custom script:

```bash
# 1. Bump "version" in CloudronManifest.json and add a matching [x.y.z] entry to CHANGELOG.
# 2. Build and push the image; note the registry digest.
# 3. We build with podman (not `cloudron build`), so record the digest-pinned image where the
#    CLI expects it: in ~/.cloudron.json under apps."<absolute repo path>".dockerImage =
#    "ghcr.io/orcvole/windmill-cloudron@sha256:…".
cloudron versions add --state published   # 4. appends the release to CloudronVersions.json
# 5. Verify, commit, push. ca.cloudron.io re-syncs the raw URL periodically.
```

Notes learned the hard way:

- The store **requires `tags`** in the manifest (also `iconUrl`, `packagerName`, `packagerUrl`,
  `contactEmail`, `mediaLinks`). A missing field doesn't error at submission — the store's sync
  silently skips the app (`Skipping community app …: tags is missing in manifest`) and the listing
  never goes public. `cloudron versions add` validates these before writing; a hand-rolled
  generator won't.
- To fix metadata on an already-published version in place, use
  `cloudron versions update --state published`. It targets the manifest's current version — do
  **not** pass `--version x.y.z`; in cloudron CLI 7.0.5 that flag is swallowed by the CLI's global
  `--version` and the command silently does nothing.
- A **new** version key in the file auto-deploys to every existing install. Test with
  `cloudron install --image` before publishing; metadata-only in-place edits don't trigger updates.

## Security posture

Cloudron runs the container unprivileged with a read-only root filesystem, so Windmill's nsjail /
PID-namespace isolation and Docker "container step" jobs are unavailable. Native jobs run within the
app's trust boundary — a single-tenant, **trusted-author** posture. Do not run untrusted or
multi-tenant code. See [`docs/decisions/0005-security-sandboxing.md`](docs/decisions/0005-security-sandboxing.md).

## License

The packaging layer is licensed under **AGPL-3.0**, matching Windmill's open-source license. Windmill
itself is © Windmill Labs, Inc. and distributed here unmodified under its own terms. See `NOTICE`.

## Credits

Thanks to the prior Windmill-on-Cloudron packagers whose work informed this one — `halecraft`
(Duane Johnson) and `timconsidine` — and the Cloudron community.
