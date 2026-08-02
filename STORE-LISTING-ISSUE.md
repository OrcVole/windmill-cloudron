# ca.cloudron.io listing never goes public — RESOLVED (2026-07-30)

> **Second chapter added 2026-08-02**: the `ts` field regressed to a string, introduced by the very command used to fix the problem below. See the foot of this file.

> **Resolution:** the forum escalation worked. The store's sync log (posted by fbartels) showed
> `Skipping community app Windmill …: tags is missing in manifest`. The manifest lacked the
> required `tags` field — the one manifest-level difference from the nine accepted packages, which
> the audit below missed because it compared *entry* key sets, not manifest key sets. Fixed by
> adding `tags` to `CloudronManifest.json` and regenerating the 1.1.1 entry in place with
> `cloudron versions update` (the CLI now replaces `scripts/make-cloudron-versions.py`; see
> README "Releasing" and `docs/PACKAGING-NOTES.md` 2026-07-30). The store re-syncs the raw URL
> periodically; check `https://ca.cloudron.io/api/apps/windmill` for it going public.
> The "server-side bug" conclusion below was wrong. Kept for the audit-method lessons.

## Symptom

The Windmill listing exists in the owner's logged-in view at `ca.cloudron.io/app/windmill`,
but is invisible to the public: the "view public listing" (eye) button says the app does
not exist, `https://ca.cloudron.io/api/apps/windmill` returns
`{"status":"Not Found","message":"App not found"}`, and the public index
(`/api/apps`, 55 apps) has no windmill entry. Anonymous page fetches 404.

Tried twice on 2026-07-30: deleted the old listing, re-submitted
`https://raw.githubusercontent.com/OrcVole/windmill-cloudron/main/CloudronVersions.json`;
deleted and re-added a second time. Polled the public API every 2 minutes for an hour
after re-submission — never appeared. For comparison, the prosody-cloudron submission
went public within ~30 minutes the day before, and the other 8 OrcVole packages are all
publicly listed, so this is specific to Windmill, not the account.

## Everything client-side was verified good (nothing in this repo needs changing)

- `CloudronVersions.json` (1.1.1, last touched 2026-06-28) passes the full pre-flight:
  `ts` is a number, `creationDate` + `publishState: "published"` present; top-level and
  per-entry key sets are byte-for-byte the same shape as prosody's accepted file.
- Manifest fields complete: `packagerName=OrcVole`, `packagerUrl`, `upstreamVersion=1.741.0`,
  `iconUrl` returns 200. Extra keys (`persistentDirs`, `backupCommand`, `restoreCommand`,
  `optionalSso`, `configurePath`, `checklist`) are all legitimate and shared with the
  publicly-listed laminar package.
- Image `ghcr.io/orcvole/windmill-cloudron@sha256:da3384d1…` pulls anonymously by digest.
- The repo is public; the raw URL serves anonymously.
- Not a name collision: the official Cloudron store (api.cloudron.io, 194 apps) has no
  Windmill, and no other community app uses the name/slug.

## Conclusion & next steps

The blocker is server-side in the store's listing record — most likely a bug (or an
undocumented hold state) in ca.cloudron.io itself. When picking this up:

1. Re-check first — it may have healed:
   `curl -s https://ca.cloudron.io/api/apps/windmill` (public when it stops 404ing).
2. If still hidden, post on forum.cloudron.io (App Packaging & Development category or
   the App Wishlist thread): staff add versions URLs manually, and the report doubles as
   a bug report. Include: self-service listing visible to owner, never public, deleted
   and re-submitted twice, public API 404s, versions file passes the same validation as
   nine other published packages from the same account (prosody-xmpp went public in
   ~30 min the previous day).
3. Audit trap that started this: **check store presence via the public API or logged
   out** — the logged-in view shows your own hidden submissions, which produced a false
   "confirmed live" in the 2026-07-28 package-coverage audit.

Related: the maintainer's fleet-maintenance chore notes and the package-coverage audit of
2026-07-28 (both since corrected). Those live in the maintainer's private notes, not in this
repository.

---

## Second chapter, 2026-08-02: the `ts` regressed, and the CLI did it

Found during the first update round, while publishing 1.1.2.

**What was found.** `windmill-cloudron`'s published feed carried `"ts": "Thu, 30 Jul 2026 15:36:00 GMT"`
for version 1.1.1 — a date **string**, where ca.cloudron.io wants epoch milliseconds. Of the six
packages in that round, windmill was the only one still carrying it; the other five were numeric.

**Why that is notable here.** The audit above, on 2026-07-30, explicitly recorded `ts` as *a number*
and correct. So it was numeric, and then it was not. The regression came from the fix itself: the
resolution above used `cloudron versions update` to regenerate the 1.1.1 entry in place, and **that
command writes `ts` as a date string**. The tool used to repair the listing reintroduced a different
defect into the same entry.

This is not windmill-specific. `cloudron versions add` and `cloudron versions update` both write the
wrong type, on every package, on every release. A feed corrected by hand this release is re-broken
by the next one. Recorded as gotcha **#181** in the packaging field guide.

**What it did NOT cause.** The public listing was serving 1.1.1 correctly throughout, so this is not
a second cause of the invisibility problem documented above, and the resolution above stands. The
store had already ingested the entry while it was well-formed; the string only threatened the *next*
sync. Stated plainly because the tempting conclusion — "the listing was broken again" — is wrong,
and the evidence (a live, correct listing) says so.

**Fixed and verified.** 1.1.1's `ts` was corrected to `1785425760000` and 1.1.2 published alongside
it with `1785700093000`. Both numeric in the live feed. The public listing subsequently synced to
1.1.2 / upstream 1.776.0, confirming the feed is accepted.

**The durable fix is mechanical, not vigilance.** `tools/check-versions-file.py <pkg> --fix` in the
packaging-notes repo now converts every string `ts` to epoch ms as a surgical text edit, and in the
same pass fails the release if any `dockerImage` is not digest-pinned, if a changelog came out
empty, or if a version present at git HEAD has vanished from the working tree (the append-only rule,
field guide #171). Run it after every `cloudron versions add`, before committing. It found this
defect on its first real use.

## Lasting lessons from both chapters

1. **Check store presence via the public API or logged out.** The logged-in view shows your own
   hidden submissions. This produced a false "confirmed live" in the 2026-07-28 audit.
2. **Compare manifest key sets, not entry key sets.** The original audit compared the wrong level
   and therefore missed the missing `tags` field, which was the actual cause.
3. **A tool that repairs one field can break another.** Re-validate the whole artifact after using
   `cloudron versions update`, not just the field you meant to change.
4. **A correct listing is not evidence of a well-formed feed.** The store serves what it last
   ingested successfully; the feed can have gone bad since. Validate the feed itself before each
   publish.
