# Gate data: how to put real records in, and count them

Gate 3 means the update is proven over real data: records the application stores, counted before the
update, after it, and after a restore. A health check, a sign-in page or a directory existing is not
data. Use at least three records of each kind you count; a count may grow across the update (the app
or a suite can add records), but a count that falls is data loss.

Every command names the Cloudron you are gating. `CLOUDRON_SERVER` is that Cloudron's API host (for
example `my.example.com`); `APP` is the install's location. Never rely on the CLI's default profile.

## windmill

`test/gate2.sh <host> before|after` asserts against a workspace `gate`; it does not create one. Seed it
through the API on a fresh install, signed in with the fixture account the suite documents:

```bash
TOKEN=$(curl -sf -X POST "https://$APP/api/auth/login" -H 'Content-Type: application/json' -d '{"email":"admin@windmill.dev","password":"changeme"}')
A=(-H "Authorization: Bearer $TOKEN")
USER=$(curl -sf "${A[@]}" "https://$APP/api/users/whoami" | jq -r .username)
curl -sf "${A[@]}" -X POST "https://$APP/api/workspaces/create" -H 'Content-Type: application/json' -d '{"id":"gate","name":"gate"}'
for n in 1 2 3; do
  curl -sf "${A[@]}" -X POST "https://$APP/api/w/gate/scripts/create" -H 'Content-Type: application/json' \
    -d "{\"path\":\"u/$USER/probe$n\",\"summary\":\"probe$n\",\"description\":\"\",\"content\":\"echo probe$n\",\"language\":\"bash\"}"
  curl -sf "${A[@]}" -X POST "https://$APP/api/w/gate/jobs/run/p/u/$USER/probe$n" -H 'Content-Type: application/json' -d '{}'
done
curl -sf "${A[@]}" "https://$APP/api/w/gate/scripts/list?per_page=50" | jq length
curl -sf "${A[@]}" "https://$APP/api/w/gate/jobs/completed/list?per_page=100" | jq length
```

Script paths must sit under the signed-in user's own name. The completed-jobs count grows on its own;
only a fall is loss. windmill's in-place restore keeps the live database, so prove the restore by
cloning into a second location and counting there.
