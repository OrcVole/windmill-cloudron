## 🧭 Windmill on Cloudron — your first 5 minutes (change the password first!)

A companion to the [Windmill package announcement](https://github.com/OrcVole/windmill-cloudron). Windmill is a big app, and the **first screen can feel daunting** — workspaces, resources, variables, instance settings, workers, SMTP, OAuth… It's easy to start clicking through configuration before you've even secured the default admin account.

So here's the short version: **ignore almost all of it at first.** Do the three quick steps below, in order, and you'll be safely logged in with your own password and running your first script in about five minutes. Everything else can wait until you actually need it.

> 🔐 **The golden rule:** the app ships with a *public, well-known* default login (`admin@windmill.dev` / `changeme`). Until you change it, anyone who finds your URL can log in. **Change the password before you do anything else.**

---

### 🚦 Step 1 — Log in, then change the password *immediately*

1. Open your Windmill URL (e.g. `https://windmill.example.com`).
2. The login page shows **email + password only** — this is normal (more on that in the FAQ). Sign in with:
   - **Email:** `admin@windmill.dev`
   - **Password:** `changeme`
3. **Change the password right now.** Two ways — use whichever you see:
   - **If a setup wizard appears** on first login, it will offer to set the superadmin **email and password** — do it there and you're done with this step. ✅
   - **Otherwise**, in the **left sidebar**, click your user at the **bottom-left** (`admin` / `admin@windmill.dev`) → **Account settings** → set a new password → **Save**.
   - **Alternative path:** sidebar → **Superadmin Settings** → **Users** tab → the row for `admin@windmill.dev` → reset its password.

> 💡 Tip: also change the **email** off `admin@windmill.dev` to your own address while you're there, so password resets and notifications reach you. (Last-resort recovery: the superadmin password can be reset from the bundled database via `cloudron exec` — ask in this thread if you ever get locked out.)

---

### 🧑‍🤝‍🧑 Step 2 — Create a second admin (30 seconds, saves you later)

One superadmin = one lost password away from a lockout. Add a backup before you build anything:

- Sidebar → **Superadmin Settings** → **Users** → **Add user** → tick **superadmin**.

Now a single forgotten password isn't a disaster. (Skip this if you're just kicking the tyres, but don't skip it for anything real.)

---

### 🗂️ Step 3 — Create your first workspace, then a "hello" script

Windmill needs a **workspace** before you can do anything — it's the container for your scripts, flows and secrets.

1. You'll be prompted to **create a workspace** (or: workspace switcher, top-left → **Create workspace**). Give it an **ID** (lowercase, e.g. `main`) and a **name**. That's it.
2. Prove it works end to end: **+ → Script → Python**, paste this, **Deploy**, then **Run**:

   ```python
   def main(name: str = "world"):
       return f"hello, {name} 🎉"
   ```

   A green run with your greeting means the language runtime, the job queue, and the worker are all healthy. (The *first* job in any language is a little slower while its runtime/dependency cache warms — that's expected, not a hang.)

You're now set up and secured. Everything below is optional.

---

### 🙈 What you can safely ignore at first

The settings that make Windmill feel overwhelming are almost all **optional and deferrable**:

| You see… | Do you need it now? |
|---|---|
| **Resources / Variables** | Only when a script needs a secret or a connection (DB, API key). Add them on demand. |
| **SMTP / email settings** | **No** — outgoing mail is already wired to the Cloudron mail addon automatically. |
| **OAuth / SSO / OIDC** | No — optional. Configure later if you want IdP login (see FAQ). |
| **Instance settings → Base URL** | Already set to your app's origin. Only revisit it if you change the app's domain (it drives webhook URLs). |
| **Workers / worker groups** | No — the package runs one bundled worker; nothing to configure. |
| **Schedules, Flows, Apps, the AI panel** | These are the *fun* part — explore them whenever you're ready. None are required for setup. |

---

### 🔐 30-second security checklist

- [ ] Default `changeme` password **changed**
- [ ] Superadmin **email** set to a real address
- [ ] A **second superadmin** exists (anti-lockout)
- [ ] You know there's **no public signup** — users are invite-only by default (this is good)

---

### ❓ "Is something broken?" — probably not

A few first-run surprises that are **expected behaviour**, not bugs:

- **"There are no SSO / Google / GitHub buttons on the login page."** Correct — those only appear once *you* configure an OAuth/OIDC provider in instance settings. Out of the box it's email/password only.
- **"There's no sign-up link."** Correct — Windmill is **invite-only** by default. As superadmin, add people via **Superadmin Settings → Users** (or invite them into a workspace). You can optionally enable self-registration / an auto-invite email domain in instance settings.
- **"My first Python/TypeScript job took a while."** First run per language fetches and caches its runtime/deps; subsequent runs are fast.
- **"I opened the bare domain and it asked me to log in."** Expected — the whole app is behind Windmill's own login.

---

### 🔗 More

- 📦 Package repo & issues: <https://github.com/OrcVole/windmill-cloudron>
- 🏠 Windmill docs: <https://www.windmill.dev/docs/intro>
- 📣 Full announcement & feature tour: *(link to the announcement thread)*

Got stuck on the first run? Reply here with what you saw and we'll get you unblocked. 🙌
