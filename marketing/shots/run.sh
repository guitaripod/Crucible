#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
MAC=${MAC:-mac}
NAME=${NAME:-CrucibleSim}
REMOTE=${REMOTE:-Dev/ios/$NAME}
PORT=${PORT:-$((32400 + $(printf %s "$NAME" | cksum | cut -d' ' -f1) % 500))}
MODE=${MODE:-dark}
OUT=${OUT:-$ROOT/marketing/shots/out/raw-$MODE}
LOG=$(mktemp "${TMPDIR:-/tmp}/crucible-shots-$NAME.XXXXXX")

rsync -az --delete \
  --exclude .build --exclude .git --exclude .claude --exclude .dd \
  --exclude 'marketing/shots/out' \
  "$ROOT/" "$MAC:$REMOTE/" < /dev/null

set +e
ssh "$MAC" "cd $REMOTE && NAME=$NAME PORT=$PORT UDID=${UDID:-} MODE=$MODE TIMEOUT=${TIMEOUT:-} CLEAN=${CLEAN:-0} MOCK_HIDDEN_SECTIONS=${MOCK_HIDDEN_SECTIONS:-} bash marketing/shots/mac-run.sh" < /dev/null > "$LOG" 2>&1
status=$?
set -e

shots=$(grep -c '^shot ' "$LOG" || true)
grep -v -E '^shot |^Warning: Permanently added' "$LOG" || true
if [ "$status" -ne 0 ]; then
  echo "capture failed (exit $status), full log: $LOG" >&2
  exit "$status"
fi
rm -f "$LOG"
echo "remote captured $shots shots"

mkdir -p "$OUT"
rsync -az --delete "$MAC:$REMOTE/marketing/shots/out/raw-$MODE/" "$OUT/" < /dev/null
echo "captured -> $OUT"
ls "$OUT"
