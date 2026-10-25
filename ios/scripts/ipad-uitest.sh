#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)

export PATH=/opt/homebrew/bin:$PATH
COPY=${IPAD_COPY:-$HOME/Dev/ios/CrucibleIPadUITest}
SIM_NAME=${IPAD_SIM_NAME:-CrucibleIPadUITest}
SIM_TYPE=${IPAD_SIM_TYPE:-com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB}
SIM_RUNTIME=${IPAD_RUNTIME:-com.apple.CoreSimulator.SimRuntime.iOS-27-0}
SCHEME=CrucibleIOS
PROJECT=ios/CrucibleIOS.xcodeproj
DERIVED=$COPY/.dd-ipad-uitest
LOGS=$COPY/.ioslogs
RESULT=$LOGS/ipad-uitest.xcresult
LOG=$LOGS/ipad-uitest.log
OUT=$ROOT/ios/out/ui-ipad

usage() {
  cat << 'USAGE'
Run the Crucible XCUITests on a local iPad simulator.

  ipad-uitest.sh [-only Class[/test]]

Syncs the repo to ~/Dev/ios/CrucibleIPadUITest (the git-ignored StoreSecrets.swift gets a placeholder there, never in the repo),
runs ios/scripts/generate.sh in the copy, boots the CrucibleIPadUITest simulator (created on first use), runs the CrucibleIOSUITests
bundle and exports the screenshot attachments to ios/out/ui-ipad.

IPAD_SIM_TYPE and IPAD_RUNTIME override the simulator device type (iPad Pro 13-inch M5) and runtime (iOS 27.0; the iOS 27.1 runtime
cannot host iPads), IPAD_SIM_NAME the simulator's name. IPAD_COPY overrides the build copy. Every exported CRUCIBLE_* variable reaches the app as TEST_RUNNER_CRUCIBLE_*.
USAGE
}

log() {
  printf '[ipad-uitest] %s\n' "$*" >&2
}

timed() {
  local label=$1 started rc=0
  shift
  started=$(date +%s)
  log "$label: start"
  "$@" || rc=$?
  log "$label: finished in $(($(date +%s) - started))s (exit $rc)"
  return $rc
}

sync_tree() {
  mkdir -p "$COPY"
  rsync -a --delete \
    --exclude .git --exclude .build --exclude '.build-*' --exclude '.dd*' --exclude .ioslogs \
    --exclude /ios/out --exclude /ios/Generated --exclude '/ios/*.xcodeproj' \
    --exclude /marketing/mock/assets --exclude /marketing/shots/out --exclude /tv/out \
    "$ROOT/" "$COPY/"
}

write_store_secrets() {
  mkdir -p "$COPY/Sources/CrucibleStore"
  printf 'package enum StoreSecrets {\n    package static let revenueCatPublicKey = "appl_placeholder"\n}\n' > "$COPY/Sources/CrucibleStore/StoreSecrets.swift"
}

generate() {
  sync_tree
  write_store_secrets
  "$COPY/ios/scripts/generate.sh"
}

sim_udid() {
  xcrun simctl list devices iOS | sed -nE "s/^ +$SIM_NAME \(([0-9A-F-]{36})\).*/\1/p" | head -1
}

sim_up() {
  local udid
  udid=$(sim_udid)
  if [[ -z $udid ]]; then
    log "creating simulator $SIM_NAME"
    udid=$(xcrun simctl create "$SIM_NAME" "$SIM_TYPE" "$SIM_RUNTIME")
  fi
  xcrun simctl boot "$udid" 2> /dev/null || true
  xcrun simctl bootstatus "$udid" -b > /dev/null
  printf '%s\n' "$udid"
}

print_results() {
  grep -E 'error:|BUILD (SUCCEEDED|FAILED)|TEST (SUCCEEDED|FAILED)|Test Case .*(passed|failed|skipped)|Test Suite .* (passed|failed)|Executed [0-9]+ tests|Fatal error|Crash' "$LOG" \
    | sed -E 's#/Users/[^/]+/Dev/ios/[^/]+/##' | awk '!seen[$0]++' | head -60 || true
}

run_tests() {
  local udid=$1 only=$2 var rc=0
  local -a args=(
    -project "$PROJECT" -scheme "$SCHEME"
    -destination "platform=iOS Simulator,id=$udid"
    -derivedDataPath "$DERIVED" -resultBundlePath "$RESULT"
  )
  [[ -z $only ]] || args+=("-only-testing:CrucibleIOSUITests/$only")
  args+=(test ARCHS=arm64 ONLY_ACTIVE_ARCH=YES)
  for var in $(compgen -e | grep '^CRUCIBLE_' || true); do
    export "TEST_RUNNER_$var=${!var}"
  done
  mkdir -p "$LOGS"
  rm -rf "$RESULT" "$LOGS/attachments"
  (cd "$COPY" && xcodebuild "${args[@]}" > "$LOG" 2>&1) || rc=$?
  print_results
  return $rc
}

export_attachments() {
  local raw=$OUT/_raw
  rm -rf "$OUT"
  mkdir -p "$raw"
  [[ -d $RESULT ]] || { log "no xcresult to export"; return 0; }
  xcrun xcresulttool export attachments --path "$RESULT" --output-path "$raw" > /dev/null
  python3 -I "$ROOT/tv/scripts/arrange_attachments.py" "$raw" "$OUT"
}

main() {
  local only="" udid rc=0
  while (($#)); do
    case $1 in
      -only) only=${2:?-only needs Class[/test]}; shift 2 ;;
      -h|--help) usage; return 0 ;;
      *) usage; return 2 ;;
    esac
  done
  timed generate generate
  udid=$(sim_up)
  log "simulator $SIM_NAME ($udid)"
  timed uitest-run run_tests "$udid" "$only" || rc=$?
  export_attachments || rc=$?
  return $rc
}

main "$@"
