#!/usr/bin/env bash
# Contract for the SearXNG companion image.
#
# Odysseus talks to SearXNG over its JSON API, and JSON is NOT enabled in
# SearXNG's default settings. Upstream's compose bind-mounts a settings file to
# turn it on; Railway cannot mount files, so the file is baked into this image
# instead. If that bake regresses, Deep Research and every web search in the
# app fail with an HTML page where JSON was expected, which is exactly the
# failure mode that looks like an app bug rather than a config one.
#
# Usage: ./test/searxng_test.sh [image-tag]
set -uo pipefail

IMG="${1:-odysseus-railway-searxng:test}"
NAME="searxng-contract-test-$$"
PORT=18080
SECRET="contract-test-secret-$$"
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

printf '\nSearXNG image contract: %s\n\n' "$IMG"

docker run -d --name "$NAME" \
  -p "127.0.0.1:${PORT}:8080" \
  -e SEARXNG_SECRET="$SECRET" \
  -e SEARXNG_BASE_URL="http://127.0.0.1:${PORT}/" \
  "$IMG" >/dev/null 2>&1 || { fail "container failed to start"; exit 1; }

for _ in $(seq 1 45); do
  code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/" 2>/dev/null)"
  [ "$code" = "200" ] && break
  docker inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null | grep -q true || break
  sleep 2
done

# 1. it serves at all
if [ "$code" = "200" ]; then
  pass "search UI responds on /"
else
  fail "search UI did not come up (last status ${code:-none})" "$(docker logs "$NAME" 2>&1 | tail -25)"
fi

# 2. the placeholder secret was replaced, not shipped
if docker exec "$NAME" grep -q '__SEARXNG_SECRET__' /etc/searxng/settings.yml 2>/dev/null; then
  fail "settings.yml still contains the __SEARXNG_SECRET__ placeholder"
else
  pass "secret key substituted at boot"
fi

# 3. the whole reason this image exists: JSON output
resp="$(curl -s -w '\n%{http_code}' "http://127.0.0.1:${PORT}/search?q=railway&format=json" 2>/dev/null)"
status="$(echo "$resp" | tail -1)"
payload="$(echo "$resp" | sed '$d')"
if [ "$status" = "200" ] && echo "$payload" | python3 -c 'import sys,json; json.load(sys.stdin)["results"]' 2>/dev/null; then
  pass "/search?format=json returns a parseable results payload"
else
  fail "JSON search API is not enabled (status ${status})" "$(echo "$payload" | head -c 300)"
fi

printf '\n'
[ "$FAILED" = "0" ] && { printf 'all contract checks passed\n\n'; exit 0; }
printf 'contract FAILED\n\n'
exit 1
