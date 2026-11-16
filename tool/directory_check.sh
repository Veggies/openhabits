#!/bin/bash
# Checks the directory end to end on a real network: the directory's own
# code (run locally), a throwaway server that opens a port on your real
# router, and the Swift app engine finding the server through the directory
# after every address it knew stops working.
#
# Needs a router with UPnP, and the server run natively (not Docker Desktop).
# Cleans up after itself: remote access is turned off (removing the router
# port and the directory entry) and both processes are stopped.
set -euo pipefail
cd "$(dirname "$0")/.."

# ROUTER_PORT is the outside port asked of the router. It's kept away from
# 8443 so a real OpenHabits server on this network keeps its own forward.
PORT=18091 HTTPS_PORT=18454 DIR_PORT=8787 ROUTER_PORT=18443
WORK=$(mktemp -d)
if lsof -ti "tcp:$PORT,$HTTPS_PORT,$DIR_PORT" -sTCP:LISTEN >/dev/null; then
  echo "Something is already using port $PORT, $HTTPS_PORT or $DIR_PORT. Stop it and try again." >&2
  exit 1
fi
cleanup() {
  if [[ -n "${TOKEN:-}" ]]; then
    curl -s -X POST "http://127.0.0.1:$PORT/admin/remote" -H "authorization: Bearer $TOKEN" \
      -H 'content-type: application/json' -d '{"action":"disable"}' >/dev/null || true
  fi
  # By port: `fvm dart run` starts the real server as a child process.
  for p in $(lsof -ti "tcp:$PORT,$HTTPS_PORT,$DIR_PORT" -sTCP:LISTEN); do kill "$p" 2>/dev/null || true; done
  [[ "${KEEP:-}" ]] && echo "logs: $WORK" || rm -rf "$WORK"
}
trap cleanup EXIT

echo "→ Directory on :$DIR_PORT"
node services/directory/local.mjs $DIR_PORT >"$WORK/directory.log" 2>&1 &

echo "→ Throwaway server on :$PORT"
(cd apps/server && PORT=$PORT HTTPS_PORT=$HTTPS_PORT DB_PATH="$WORK/data.sqlite" \
  OWNER_USERNAME=tester OWNER_PASSWORD=testpass123 \
  DIRECTORY_URL="http://127.0.0.1:$DIR_PORT" \
  fvm dart run bin/server.dart >"$WORK/server.log" 2>&1) &
for _ in $(seq 60); do curl -sf "http://127.0.0.1:$PORT/health" >/dev/null && break; sleep 1; done

TOKEN=$(curl -sf "http://127.0.0.1:$PORT/auth/login" -H 'content-type: application/json' \
  -d '{"username":"tester","password":"testpass123","device":"check"}' |
  python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])')

echo "→ Turning on remote access (asks your router for port $ROUTER_PORT)"
curl -sf -X PUT "http://127.0.0.1:$PORT/admin/remote" -H "authorization: Bearer $TOKEN" \
  -H 'content-type: application/json' -d "{\"port\":$ROUTER_PORT}" >/dev/null
STATUS=$(curl -sf -X POST "http://127.0.0.1:$PORT/admin/remote" -H "authorization: Bearer $TOKEN" \
  -H 'content-type: application/json' -d '{"action":"enable"}')
echo "$STATUS" | python3 -c 'import json,sys; s=json.load(sys.stdin)["status"]; print("  ", s["state"], s.get("url") or s["message"]); sys.exit(s["state"]!="on")'

echo "→ The directory has it:"
grep -E "PUT /v1/servers" "$WORK/directory.log" | sed 's/^/   /'

echo "→ Swift engine: all known addresses dead, find it through the directory"
(cd apps/apple/Packages/HabitsCore && HABITS_DIRECTORY_TEST=1 \
  HABITS_TEST_SERVER="http://127.0.0.1:$PORT" swift test --filter DirectoryFallback 2>&1 |
  grep -E "✔|✘|passed|failed|error:" | sed 's/^/   /')
grep -E "GET /v1/servers" "$WORK/directory.log" | sed 's/^/   looked up: /'
grep -qE "GET /v1/servers.* 200" "$WORK/directory.log"
echo "✓ The app found the server through the directory"
