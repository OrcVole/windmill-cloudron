### Windmill is installed 🎉

**First login**

Sign in with the default superadmin and **change the password immediately**:

- Email: `admin@windmill.dev`
- Password: `changeme`

Change it under **Settings → Users**. Then create your first workspace and invite users (or wire up
SSO / OAuth in the instance settings). The default credentials are fixed by Windmill on first boot
and cannot be pre-seeded, so changing them is your first task.

**What this package runs**

A single container with Windmill running as a dedicated API/UI server process plus one or more worker
processes (the same server/worker split Windmill runs in production, co-located here), a **bundled
PostgreSQL 16**, and nginx — all managed by supervisor. The number of worker processes scales with the
memory you allocate to the app. Everything durable (the database, dependency caches) lives under
`/app/data` and is included in Cloudron backups.

**Languages**: Python, TypeScript (Deno/Bun), Go, Bash and SQL work out of the box. The first job in
a language may take a little longer while its runtime/dependencies are fetched and cached.

### Backups and restores — please read once

Your workflows, scripts, jobs and settings all live in the bundled PostgreSQL, and they are fully
backed up: at backup time the app writes a consistent logical dump of the database into the backed-up
folder, rather than file-copying a live data directory (which would risk a torn copy).

**One consequence is worth knowing before you need it. An in-place restore does not roll the database
back.** Restoring this app in place brings back the backed-up files, but the live PostgreSQL data
directory is deliberately preserved as it is — the restore step refuses to overwrite a populated
database, because a half-replaced database is worse than either version.

So, to undo a bad update or recover a deleted workflow:

- **Clone the app from the backup** (Cloudron's clone, not restore). A clone starts from an empty
  data directory, so the dump is replayed in full and you get a true point-in-time copy — verified
  2026-08-03: a clone taken from a pre-update backup came back with the exact pre-update schema and
  job history.
- Then move the domain over, or copy what you need out of the clone.

An in-place restore is still the right tool for rolling back a *configuration* change, or for
recovering an app whose database is intact.

**Security posture — important**

Cloudron runs apps unprivileged with a read-only root filesystem. Therefore Windmill's **nsjail /
PID-namespace sandboxing and Docker-based "container step" jobs are not available**. Native jobs run
within the app's own trust boundary. This is the standard single-tenant, **trusted-author** posture
— **do not** use it to run untrusted or multi-tenant code.

**Email**: outgoing mail is wired to the Cloudron mail addon automatically. You can override SMTP in
Windmill's instance settings if you prefer.

**Users, login and SSO**

The login page shows **email/password only** by design — there are no SSO buttons until you configure
an OAuth/OIDC provider, and there is no public self-signup because Windmill is **invite-only** by
default. This is expected, not a fault.

- **Add users**: as the superadmin, go to the instance settings → Users (or add members inside a
  workspace). Optionally enable self-registration / an auto-invite email domain in the instance
  settings.
- **Enable SSO**: configure an OAuth/OIDC provider in Windmill's instance settings (Settings → SSO/
  OAuth). Windmill works with Keycloak, Authelia, Google, GitHub, etc. — create a client in your IdP
  and paste the client id/secret/issuer. (Automatic wiring of the Cloudron `oidc` addon is a planned
  follow-up; for now configure the provider directly.)
- **Avoid lockout**: create a **second superadmin** so a single lost password isn't a lockout. As a
  last resort, the superadmin password can be reset from the database via `cloudron exec`.

**Memory**: this app bundles its own PostgreSQL alongside the Windmill server and its worker
processes, all under one memory limit. Keep it at **3 GB or more** (2 GB floor); an out-of-memory
event would take the database down with the app. **Raising the memory limit in the dashboard
(Resources) automatically adds worker processes** (more memory → more parallel jobs), leaving the
database its headroom — so it's the single knob for capacity. Advanced operators can pin the count
with the `WINDMILL_WORKER_COUNT` environment variable.

**Webhooks / base URL**: Windmill generates webhook URLs from its base URL, set to this app's origin.
If you change the app's domain, update the base URL in Windmill's instance settings.
