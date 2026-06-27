### Windmill is installed 🎉

**First login**

Sign in with the default superadmin and **change the password immediately**:

* Email: `admin@windmill.dev`
* Password: `changeme`

Change it under **Settings → Users**. Then create your first workspace and invite users (or wire up
SSO / OAuth in the instance settings). The default credentials are fixed by Windmill on first boot
and cannot be pre-seeded, so changing them is your first task.

**What this package runs**

A single container with Windmill (standalone: API server + one worker), a **bundled PostgreSQL 16**,
and nginx — all managed by supervisor. Everything durable (the database, dependency caches) lives
under `/app/data` and is included in Cloudron backups.

**Languages**: Python, TypeScript (Deno/Bun), Go, Bash and SQL work out of the box. The first job in
a language may take a little longer while its runtime/dependencies are fetched and cached.

**Security posture — important**

Cloudron runs apps unprivileged with a read-only root filesystem. Therefore Windmill's **nsjail /
PID-namespace sandboxing and Docker-based "container step" jobs are not available**. Native jobs run
within the app's own trust boundary. This is the standard single-tenant, **trusted-author** posture
— **do not** use it to run untrusted or multi-tenant code.

**Email**: outgoing mail is wired to the Cloudron mail addon automatically. You can override SMTP in
Windmill's instance settings if you prefer.

**Webhooks / base URL**: Windmill generates webhook URLs from its base URL, set to this app's origin.
If you change the app's domain, update the base URL in Windmill's instance settings.
