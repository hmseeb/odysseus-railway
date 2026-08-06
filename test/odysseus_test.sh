#!/usr/bin/env bash
# Contract for the Odysseus Railway image.
#
# Four things have to hold before this image is allowed near the marketplace,
# and all four have burned a previous template:
#
#   1. The trimmed dependency set actually imports. Upstream's image carries
#      build-essential, cmake, chromium, tmux, ssh and a Docker client for
#      local-model serving and host-Docker control, none of which can work on
#      Railway. Dropping them is only safe if the app still boots.
#   2. The listener answers on IPv4 *and* IPv6. Railway dials containers over
#      IPv6 while its health checker speaks IPv4, and Python's asyncio makes a
#      "::" socket v6-only by default, so the naive fix fails one of the two.
#   3. The admin account seeds from the environment. A published template has
#      no terminal to print a password into, so the deployer's generated
#      password has to be the one that works.
#   4. State lands under /app/data, which is the only path Railway persists.
#
# Usage: ./test/odysseus_test.sh [image-tag]
set -uo pipefail

IMG="${1:-odysseus-railway:test}"
NAME="odysseus-contract-test-$$"
PORT=17000
ADMIN_PW="contract-test-pw-$$"
FAILED=0

pass() { printf '  ok    %s\n' "$1"; }
fail() {
  printf '  FAIL  %s\n' "$1"
  [ -n "${2:-}" ] && printf '        %s\n' "$2"
  FAILED=1
}

cleanup() {
  docker rm -f "$NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

printf '\nOdysseus image contract: %s\n\n' "$IMG"

docker run -d --name "$NAME" \
  -p "127.0.0.1:${PORT}:7000" \
  -e ODYSSEUS_ADMIN_USER=admin \
  -e ODYSSEUS_ADMIN_PASSWORD="$ADMIN_PW" \
  -e AUTH_ENABLED=true \
  -e ALLOWED_ORIGINS="http://127.0.0.1:${PORT}" \
  "$IMG" >/dev/null 2>&1 || { fail "container failed to start"; exit 1; }

# First boot runs setup.py (dirs, sqlite schema, admin seed) before uvicorn.
for _ in $(seq 1 90); do
  code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/api/health" 2>/dev/null)"
  [ "$code" = "200" ] && break
  docker inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null | grep -q true || break
  sleep 2
done

# 1. liveness
body="$(curl -s "http://127.0.0.1:${PORT}/api/health" 2>/dev/null)"
if echo "$body" | grep -q '"status"\s*:\s*"healthy"'; then
  pass "/api/health reports healthy"
else
  fail "/api/health did not report healthy" "$(docker logs "$NAME" 2>&1 | tail -25)"
fi

# 2. dual-stack listener, probed from inside the container so the host's own
#    port publishing cannot mask a v6-only or v4-only bind.
probe='
import sys, urllib.request
for host in ("127.0.0.1", "[::1]"):
    try:
        r = urllib.request.urlopen("http://%s:7000/api/health" % host, timeout=5)
        if r.status != 200:
            print("FAIL %s status %s" % (host, r.status)); sys.exit(1)
    except Exception as e:
        print("FAIL %s %s" % (host, e)); sys.exit(1)
print("OK")
'
out="$(docker exec "$NAME" python -c "$probe" 2>&1)"
if [ "$out" = "OK" ]; then
  pass "listener answers on both 127.0.0.1 and [::1]"
else
  fail "listener is not dual-stack" "$out"
fi

# 3. the seeded admin password is the one that works
login="$(curl -s -c /dev/null -w '\n%{http_code}' \
  -H 'Content-Type: application/json' \
  -d "{\"username\":\"admin\",\"password\":\"${ADMIN_PW}\"}" \
  "http://127.0.0.1:${PORT}/api/auth/login" 2>/dev/null)"
if [ "$(echo "$login" | tail -1)" = "200" ] && echo "$login" | grep -q '"ok"\s*:\s*true'; then
  pass "admin login succeeds with the seeded password"
else
  fail "admin login with the seeded password failed" "$login"
fi

# a session cookie has to come back, or the browser can never stay logged in
cookie="$(curl -s -i -H 'Content-Type: application/json' \
  -d "{\"username\":\"admin\",\"password\":\"${ADMIN_PW}\"}" \
  "http://127.0.0.1:${PORT}/api/auth/login" 2>/dev/null | grep -i '^set-cookie:')"
if echo "$cookie" | grep -q 'odysseus_session='; then
  pass "login sets the odysseus_session cookie"
else
  fail "login did not set a session cookie" "$cookie"
fi

# 4. state landed on the only path Railway persists
if docker exec "$NAME" test -f /app/data/auth.json; then
  pass "credentials persisted to /app/data"
else
  fail "/app/data/auth.json missing" "$(docker exec "$NAME" ls -la /app/data 2>&1 | head)"
fi

# 5. the login page is reachable without a session, or a fresh deployer is
#    locked out of their own instance
code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/login" 2>/dev/null)"
if [ "$code" = "200" ]; then
  pass "/login is served without auth"
else
  fail "/login returned $code"
fi

printf '\n'
[ "$FAILED" = "0" ] && { printf 'all contract checks passed\n\n'; exit 0; }
printf 'contract FAILED\n\n'
exit 1
