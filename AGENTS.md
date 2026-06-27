# AGENTS.md — Working contract for the Windmill Cloudron package

These are the settled "golden rules" for this repo. Do not relitigate them each session.
When ground truth contradicts a rule, change the rule here in a commit, with the evidence.

## Golden rules

1. **Empirical verification beats documentation — including this file, the foundation brief, and the
   field guide.** Every assumption is checked against the running box and logged in
   `docs/PACKAGING-NOTES.md` (newest first) as *verified* or *assumed*.
2. **Conformance first; thin layer; never fork or modify upstream.** We orchestrate the official
   Windmill **Community Edition** image/binary **unmodified**. We do **not** patch the binary, and we
   do **not** re-enable capped/EE features. (Windmill CE license: "distribute as is, do not modify or
   wrap" — and one prior packager flagged this exact concern.)
3. **One source of truth for the version.** Dockerfile `ARG WINDMILL_VERSION` (+ pinned image
   `@sha256` digest). `upstreamVersion` in the manifest mirrors it; `version` is our package semver.
4. **Persisted state only under `/app/data`.** Re-assert ownership/modes every boot (a restore drifts
   them). Secrets seeded **once**, idempotently, never reseeded on update.
5. **Fail loud, log clean.** `set -euo pipefail`; prefix package log lines with `==>`; echo resolved
   facts (port, worker count, key *presence*) but **never** secrets.
6. **Document as you go.** `docs/LEARNINGS.md` (four audiences, newest first) maintained throughout.
7. **Anonymity + secrets discipline on every commit/push.** No box hostname, token, email, Forgejo
   URL, or internal stack URL in any tracked file. `test/secret-scan.sh` is a release gate.
8. **No `Co-Authored-By` trailers** on commits. Repo `LICENSE` matches upstream (AGPL-3.0).
9. **Canonical upstream icon only** (the real Windmill pinwheel mark), 256×256 transparent `logo.png`.

## Settled architecture decisions (see docs/decisions/ for full ADRs)

- **Topology:** single container, `MODE=standalone` (server + in-process workers), fronted by nginx
  for an immediate `/health 200` during first-boot migrations. Bundled **PostgreSQL 16** + Windmill
  under **supervisor**.
- **Postgres is bundled, not the addon.** The Cloudron `postgresql` addon cannot create Windmill's
  `windmill_admin WITH BYPASSRLS` role or let the app `SET ROLE` to it; the only addon-compatible
  workaround is patching the binary, which rule #2 forbids. So we bundle PG as superuser, data under
  `/app/data/postgresql`, backed up via `localstorage`. (ADR 0003.)
- **Security posture:** nsjail off, PID-namespace isolation off (Cloudron is unprivileged, read-only
  rootfs). Container-step/`# sandbox` jobs are unavailable; native jobs (Python/TS/Go/Bash/SQL/…) run
  in the app's trust boundary — single-tenant, trusted-author posture. **Not** safe for untrusted
  multi-tenant code. (ADR 0005.)
- **Auth:** app-native (Windmill's own login). `optionalSso: true`. No `proxyAuth` in front of the
  app (webhooks/API must not get a login redirect).
- **State/secrets:** all durable state (incl. workspace encryption keys + auto-generated `jwt_secret`)
  lives in the bundled Postgres → backed up with `/app/data`. No external key file is data-critical.

## The gates (a change is not done until the relevant gate passes)

Build linkage → runtime smoke (`test/smoke.sh`) → secret scan (`test/secret-scan.sh`) → read-only/
runs-as-cloudron → update survival → backup/restore survival → stranger install. See field guide §11.
