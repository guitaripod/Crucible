#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
MAC=${MAC:-mac}
REMOTE=${REMOTE:-Dev/ios/CrucibleSim}
UDID=${UDID:-B63090D4-6D6F-467D-B504-672EA3E95500}
MODE=${MODE:-dark}
OUT=${OUT:-$ROOT/marketing/shots/out/raw-$MODE}

rsync -az --delete \
  --exclude .build --exclude .git --exclude .claude --exclude .dd \
  --exclude 'marketing/shots/out' \
  "$ROOT/" "$MAC:$REMOTE/"

ssh "$MAC" "cd $REMOTE && UDID=$UDID MODE=$MODE MOCK_HIDDEN_SECTIONS=${MOCK_HIDDEN_SECTIONS:-} bash marketing/shots/mac-run.sh"

mkdir -p "$OUT"
rsync -az --delete "$MAC:$REMOTE/marketing/shots/out/raw-$MODE/" "$OUT/"
echo "captured -> $OUT"
ls "$OUT"
