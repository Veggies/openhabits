#!/usr/bin/env bash
# Checks that the server image and both apps' sync code work together, over
# real network connections:
#
#   1. builds the server image and starts a throwaway copy of it
#   2. the Swift core (iPhone/iPad/Mac) signs in, pairs a second device and syncs
#   3. the Swift core makes a habit; the Flutter core (Android/Windows/Linux)
#      reads it and edits it; the Swift core reads the edit back
#
# Usage: tool/cross_app_check.sh   (needs Docker, Swift and fvm)
set -euo pipefail
cd "$(dirname "$0")/.."

PORT=18080
NAME="openhabits-check"
export HABITS_TEST_SERVER="http://localhost:$PORT"
export HABITS_TEST_USER=tester HABITS_TEST_PASSWORD=testpass123
export HABITS_CROSS_NAME="Cross-app $(date +%s)"

cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "› Building the server image"
docker build -q -f apps/server/Dockerfile -t openhabits-server:check . >/dev/null
cleanup
docker run -d --name "$NAME" -p "127.0.0.1:$PORT:$PORT" \
  -e PORT="$PORT" -e OWNER_USERNAME="$HABITS_TEST_USER" -e OWNER_PASSWORD="$HABITS_TEST_PASSWORD" \
  openhabits-server:check >/dev/null

printf "› Waiting for the server"
for _ in $(seq 1 40); do
  status=$(docker inspect -f '{{.State.Health.Status}}' "$NAME")
  [ "$status" = healthy ] && break
  printf .; sleep 1
done
echo " $status"
[ "$status" = healthy ] || { docker logs "$NAME"; exit 1; }

swift_test() { (cd apps/apple/Packages/HabitsCore && swift test --filter "$1" 2>&1 | tail -4); }

echo "› Apple: sign in, pair a second device, sync, resolve a conflict"
swift_test WithAServer
echo "› Apple: make a habit and tick it off for today"
HABITS_CROSS_STEP=write swift_test CrossApp
echo "› Android: read the habit, rename it, untick it"
(cd apps/client && fvm flutter test test/cross_app_test.dart 2>&1 | tail -3)
echo "› Apple: see Android's changes"
HABITS_CROSS_STEP=read swift_test CrossApp
echo "✓ The server and both apps agree"
