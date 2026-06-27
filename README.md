# Windmill for Cloudron

A [Cloudron](https://cloudron.io) community package for [Windmill](https://www.windmill.dev) —
the open-source developer platform that turns scripts (Python / TypeScript / Go / Bash / SQL) into
webhooks, scheduled jobs, multi-step flows and auto-generated UIs.

Pinned to Windmill **Community Edition v1.741.0**, run **unmodified**.

## Design in one paragraph

A single container runs Windmill in `MODE=standalone` (API server + one worker), a **bundled
PostgreSQL 16**, and **nginx**, all under supervisor. nginx answers `/health` immediately (so the
app stays healthy while first-boot migrations run) and reverse-proxies everything else to Windmill.
All durable state — the PostgreSQL data directory and the language dependency caches — lives under
`/app/data` and is captured by Cloudron backups.

PostgreSQL is **bundled rather than using the `postgresql` addon** because Windmill requires
superuser-grade privileges the addon cannot grant (`CREATE ROLE … BYPASSRLS`, `CREATE EXTENSION
uuid-ossp`, runtime `SET ROLE`). The only addon-compatible alternative is patching the Windmill
binary, which the Windmill CE license and our packaging rules forbid. See
[`docs/decisions/0003-bundled-postgres.md`](docs/decisions/0003-bundled-postgres.md).

## Repository layout

```
Dockerfile             cloudron/base final stage; COPY the unmodified CE binary + runtimes
start.sh               entrypoint: PG bootstrap, env mapping, supervisor handoff
supervisord.conf       postgres + windmill + nginx
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
