#!/bin/bash
# Runtime smoke gate — runs the image the way Cloudron does (root entry, read-only rootfs, tmpfs
# /run + /tmp, /app/data volume, runs-as-cloudron) and asserts real behaviour. Exits non-zero on
# any failure. This is the gate that catches the things a build-time linkage check cannot.
#
# Usage: test/smoke.sh [image]   (default: local/windmill-cloudron:dev)
set -euo pipefail

IMAGE="${1:-local/windmill-cloudron:dev}"
ENGINE="$(command -v podman || command -v docker)"
NAME="windmill-smoke-$$"
VOL="windmill-smoke-vol-$$"
PORT=8099
BASE="http://127.0.0.1:${PORT}"
fail() { echo "SMOKE FAIL: $*" >&2; "$ENGINE" logs "$NAME" 2>&1 | tail -40 >&2; cleanup; exit 1; }
cleanup() { "$ENGINE" rm -f "$NAME" >/dev/null 2>&1 || true; "$ENGINE" volume rm "$VOL" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "==> smoke: starting ${IMAGE} Cloudron-style"
"$ENGINE" volume create "$VOL" >/dev/null
"$ENGINE" run -d --name "$NAME" \
  -e CLOUDRON_APP_ORIGIN=https://windmill.smoke.local \
  -e CLOUDRON_APP_DOMAIN=windmill.smoke.local \
  -v "$VOL":/app/data -p ${PORT}:8000 \
  --read-only --tmpfs /run --tmpfs /tmp --shm-size=512m \
  "$IMAGE" >/dev/null

echo "==> smoke: waiting for /health"
ok=
for _ in $(seq 1 60); do
  if [ "$(curl -fsS -o /dev/null -w '%{http_code}' "${BASE}/health" 2>/dev/null)" = "200" ]; then ok=1; break; fi
  sleep 2
done
[ -n "$ok" ] || fail "/health never returned 200"
echo "    /health 200 (no auth) OK  [liveness — served by nginx before the backend is ready]"

echo "==> smoke: waiting for Windmill readiness (/api/version) — migrations run first"
ready=
for _ in $(seq 1 60); do
  if curl -fsS "${BASE}/api/version" 2>/dev/null | grep -q '1.741.0'; then ready=1; break; fi
  sleep 2
done
[ -n "$ready" ] || fail "/api/version never reported 1.741.0 (backend not ready)"
echo "    /api/version reports 1.741.0 OK"

[ "$(curl -fsS -o /dev/null -w '%{http_code}' "${BASE}/" 2>/dev/null)" = "200" ] || fail "/ did not return 200"
echo "    / (frontend) 200 OK"

echo "==> smoke: authenticated operation (default-cred login + whoami)"
TOKEN="$(curl -fsS -X POST "${BASE}/api/auth/login" -H 'Content-Type: application/json' \
  -d '{"email":"admin@windmill.dev","password":"changeme"}' 2>/dev/null || true)"
[ "${#TOKEN}" -ge 16 ] || fail "login did not return a token"
curl -fsS "${BASE}/api/users/whoami" -H "Authorization: Bearer ${TOKEN}" 2>/dev/null \
  | grep -q '"super_admin":true' || fail "whoami did not confirm super_admin"
echo "    login + whoami(super_admin) OK"

echo "==> smoke: runs as cloudron + read-only rootfs"
"$ENGINE" exec "$NAME" sh -c 'id -un windmill >/dev/null 2>&1; ps -o user= -C windmill | grep -qx cloudron' \
  || fail "windmill is not running as cloudron"
"$ENGINE" exec "$NAME" sh -c 'touch /app/code/should_fail 2>/dev/null && echo wrote' | grep -q wrote \
  && fail "/app/code is writable (should be read-only)" || true
echo "    runs-as-cloudron + /app/code read-only OK"

echo "==> smoke: no DB password in logs"
PW="$("$ENGINE" exec "$NAME" sh -c 'cut -d= -f2 /app/data/.secrets/db.env')"
[ -n "$PW" ] && ! "$ENGINE" logs "$NAME" 2>&1 | grep -q "$PW" || fail "DB password leaked into logs"
echo "    no secret in logs OK"

echo "==> SMOKE PASS"
