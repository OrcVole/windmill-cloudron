#!/bin/bash
# gate2.sh — data-level differential assertions for a Windmill version bump.
# Usage: test/gate2.sh <host> before|after [expected_version]
#   WM_EMAIL/WM_PASSWORD override the fixture defaults (admin@windmill.dev/changeme).
#   Against production (no credentials), it runs the unauthenticated subset only.
#
# Written for 1.776.0 -> 1.777.1 (2026-08-03); version-specific assertions marked. Both legs must
# run: the before leg is the after leg's fail-observation (#183). Schema/migration-count checks
# live in the round's gate-3 evidence block (they need psql via cloudron exec, not the API).
set -uo pipefail
H="https://${1:?host required}"; LEG="${2:?before|after}"; WANT="${3:-}"
EMAIL="${WM_EMAIL:-admin@windmill.dev}"; PASS="${WM_PASSWORD:-changeme}"
fails=0; ok(){ echo "PASS: $*"; }; bad(){ echo "FAIL: $*"; fails=$((fails+1)); }; note(){ echo "  ~ $*"; }

# A. identity: the version actually serving
V=$(curl -sf "$H/api/version")
note "serving ${V}"
if [ -n "$WANT" ]; then echo "$V" | grep -q "$WANT" && ok "version contains ${WANT}" || bad "version '${V}' lacks expected ${WANT}"; fi

# authenticated subset
TOKEN=$(curl -sf -X POST "$H/api/auth/login" -H 'Content-Type: application/json' \
  -d "{\"email\":\"${EMAIL}\",\"password\":\"${PASS}\"}" 2>/dev/null || true)
if [ -z "$TOKEN" ]; then
  note "no credentials accepted — unauthenticated subset only (expected on production)"
  echo "=== gate2(windmill) leg=${LEG} result: ${fails} failure(s) ==="; exit $fails
fi
A=(-H "Authorization: Bearer ${TOKEN}")

# B. data preservation: seeded corpus intact (workspace 'gate': 1 script, >=6 completed jobs)
SC=$(curl -sf "${A[@]}" "$H/api/w/gate/scripts/list?per_page=50" | jq 'length')
JC=$(curl -sf "${A[@]}" "$H/api/w/gate/jobs/completed/list?per_page=100" | jq 'length')
note "scripts=${SC} completed_jobs=${JC}"
[ "${SC:-0}" -ge 1 ] && ok "seeded script present" || bad "seeded script missing"
if [ "$LEG" = after ]; then
  BASE=$(cat /tmp/gate2-wm-jobs-before 2>/dev/null || echo "")
  if [ -z "$BASE" ]; then bad "no before-leg job baseline — comparison never ran (not a pass)"
  elif [ "${JC:-0}" -ge "$BASE" ]; then ok "completed jobs preserved (${JC} >= baseline ${BASE})"
  else bad "completed jobs LOST: ${JC} < baseline ${BASE}"; fi
else
  echo "${JC:-0}" > /tmp/gate2-wm-jobs-before
fi

# C. end-to-end: run the seeded probe ON THIS VERSION and demand a real computed result.
#    This is the strongest single assertion: scheduler, worker, and result path all exercised.
R=$(curl -sf -X POST "$H/api/w/gate/jobs/run_wait_result/p/u/admin/gate_probe" "${A[@]}" \
    -H 'Content-Type: application/json' -d '{"n": 12}' --max-time 180 || true)
echo "$R" | jq -e '.squared == 144' >/dev/null 2>&1 \
  && ok "probe job executed end-to-end (12^2=144) on the ${LEG}-leg version" \
  || bad "probe job failed or wrong result: $(echo "$R" | head -c 120)"

echo "=== gate2(windmill) leg=${LEG} result: ${fails} failure(s) ==="
exit $fails
