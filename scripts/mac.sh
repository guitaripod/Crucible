#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
MAC=${MAC:-mac}
NAME=${NAME:-CrucibleTV}
REMOTE=Dev/ios/$NAME

source "$ROOT/scripts/slot-gate.sh"

usage() {
  cat << 'USAGE'
Build and test Crucible on the Mac (the only host with the Apple SDKs).

  scripts/mac.sh sync        rsync the working tree to the Mac
  scripts/mac.sh ios         sync, then build the iOS package scheme (Crucible) for the iPhone simulator
  scripts/mac.sh tvlib       sync, then build the CrucibleTV package scheme for the Apple TV simulator
  scripts/mac.sh store       sync, then build the CrucibleStore package scheme (RevenueCat) for the iPhone and Apple TV simulators
  scripts/mac.sh core-test   sync, then run CrucibleCoreTests on the macOS host (CRUCIBLE_CORE_ONLY=1)
  scripts/mac.sh sh <cmd>    sync, then run <cmd> inside the remote checkout

NAME=<dir> keeps parallel work apart: it picks the remote checkout (~/Dev/ios/$NAME) and its build products.
USAGE
}

remote() {
  ssh -o BatchMode=yes "$MAC" "cd ~/$REMOTE && export PATH=/opt/homebrew/bin:\$PATH && $*" < /dev/null
}

sync_tree() {
  ssh -o BatchMode=yes "$MAC" "mkdir -p ~/$REMOTE" < /dev/null
  rsync -az --delete \
    --exclude .build --exclude '.build-*' --exclude .git --exclude .claude --exclude '.dd*' \
    --exclude xtool --exclude marketing --exclude screenshots.png --exclude .bsp --exclude '*.xcodeproj' \
    --exclude .tvlogs --exclude /tv/out --exclude /tv/Generated --exclude /tv/.gen-hash \
    "$ROOT/" "$MAC:$REMOTE/"
}

summarize() {
  grep -E "error:|BUILD (SUCCEEDED|FAILED)|Test run with|Test .* failed|✘" \
    | sed -E 's#/Users/[^/]+/Dev/ios/[^/]+/##' \
    | awk '!seen[$0]++' \
    | head -${LINES_MAX:-60}
}

xcode_build() {
  local scheme=$1 destination=$2 derived=$3
  remote "$(build_gate) xcodebuild -scheme $scheme -destination '$destination' -derivedDataPath $derived ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build 2>&1" | summarize
}

case "${1:-}" in
  sync) sync_tree ;;
  ios) sync_tree; xcode_build Crucible "generic/platform=iOS Simulator" .dd-ios ;;
  tvlib) sync_tree; xcode_build CrucibleTV "generic/platform=tvOS Simulator" .dd-tv ;;
  store) sync_tree; xcode_build CrucibleStore "generic/platform=iOS Simulator" .dd-store; xcode_build CrucibleStore "generic/platform=tvOS Simulator" .dd-store-tv ;;
  core-test) sync_tree; remote "$(build_gate) CRUCIBLE_CORE_ONLY=1 swift test --scratch-path .build-core 2>&1" | summarize ;;
  sh) shift; sync_tree; remote "$*" ;;
  *) usage; exit 2 ;;
esac
