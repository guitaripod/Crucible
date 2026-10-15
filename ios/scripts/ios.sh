#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)

source "$ROOT/scripts/slot-gate.sh"
MAC=${MAC:-mac}
NAME=${NAME:-CrucibleIOS}
REMOTE=Dev/ios/$NAME
SIM_NAME=CrucibleIOS-$NAME
SIM_RUNTIME=${IOS_RUNTIME:-com.apple.CoreSimulator.SimRuntime.iOS-26-5}
SIM_TYPE=${IOS_SIM_TYPE:-com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max}
BUNDLE_ID=com.guitaripod.crucible
SCHEME=CrucibleIOS
PROJECT=ios/CrucibleIOS.xcodeproj
DERIVED=.dd-iosapp
DERIVED_DEVICE=.dd-iosdevice
ARCHIVE=.ioslogs/Crucible.xcarchive
OUT=$ROOT/ios/out
SSH=(ssh -o BatchMode=yes)

usage() {
  cat << 'USAGE'
Build, run and screenshot the Crucible iPhone app (the Xcode project in ios/) on the Mac.

  ios.sh generate                sync the tree and run xcodegen (skipped when project.yml and the source file lists are unchanged)
  ios.sh build                   generate, then build the CrucibleIOS scheme (app and widget extension) for the NAME simulator
  ios.sh device-build            generate, then build for generic/platform=iOS with signing off, proving the device slice compiles
  ios.sh run [VAR=value ...]     build, install, launch and screenshot to ios/out/run.png; VAR=value arguments and every exported
                                 CRUCIBLE_* variable reach the app as SIMCTL_CHILD_VAR
  ios.sh shot <name>             screenshot the simulator to ios/out/<name>.png
  ios.sh test [-only Class[/test]]   generate, then run the CrucibleIOSUITests XCUITest bundle on the NAME simulator; every exported
                                 CRUCIBLE_* variable reaches the app as TEST_RUNNER_CRUCIBLE_*, and screenshot attachments land in ios/out/ui
  ios.sh archive-check           generate, then xcodebuild archive unsigned and verify the .app, the widget and the privacy manifest
  ios.sh sim-down [--delete]     shut the simulator down, optionally delete it

IOS_CONFIGURATION=Release runs `ios.sh test` against the optimised build (CRUCIBLE_FRESH and the scripted store are DEBUG-only then).
NAME=<id> isolates the remote checkout (~/Dev/ios/$NAME), DerivedData and the simulator CrucibleIOS-$NAME
(iPhone 17 Pro Max, iOS 26.5; IOS_RUNTIME and IOS_SIM_TYPE override). MAC=<ssh host> picks the build Mac (default: mac).
USAGE
}

log() {
  printf '[%s] %s\n' "$NAME" "$*" >&2
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

remote() {
  "${SSH[@]}" "$MAC" "cd ~/$REMOTE && export PATH=/opt/homebrew/bin:\$PATH && $*" < /dev/null
}

remote_raw() {
  "${SSH[@]}" "$MAC" "export PATH=/opt/homebrew/bin:\$PATH && $*" < /dev/null
}

sync_tree() {
  "${SSH[@]}" "$MAC" "mkdir -p ~/$REMOTE" < /dev/null
  rsync -az --delete -e "${SSH[*]}" \
    --exclude .build --exclude '.build-*' --exclude .git --exclude .claude --exclude '.dd*' \
    --exclude xtool --exclude marketing --exclude screenshots.png --exclude .bsp --exclude '*.xcodeproj' \
    --exclude .tvlogs --exclude /tv/out --exclude /tv/Generated --exclude /tv/.gen-hash \
    --exclude .ioslogs --exclude /ios/out --exclude /ios/Generated --exclude /ios/.gen-hash \
    "$ROOT/" "$MAC:$REMOTE/"
}

generate() {
  sync_tree
  remote 'cd ios && want=$( { pwd; cat project.yml scripts/generate.sh; find App Resources UITests ../Sources/Crucible ../Sources/CrucibleWidgets -type f | sort; } | shasum | cut -d" " -f1 )
    if [ -d CrucibleIOS.xcodeproj ] && [ -d Generated ] && [ "$(cat .gen-hash 2>/dev/null)" = "$want" ]; then
      echo "xcodegen: project up to date"
    else
      scripts/generate.sh && echo "$want" > .gen-hash
    fi'
}

sim_udid() {
  remote_raw "xcrun simctl list devices iOS" | sed -nE "s/^ +$SIM_NAME \(([0-9A-F-]{36})\).*/\1/p" | head -1
}

sim_ensure() {
  local udid
  udid=$(sim_udid)
  if [[ -z $udid ]]; then
    log "creating simulator $SIM_NAME"
    udid=$(remote_raw "xcrun simctl create '$SIM_NAME' $SIM_TYPE $SIM_RUNTIME")
  fi
  printf '%s\n' "$udid"
}

sim_up() {
  local udid
  udid=$(sim_ensure)
  remote_raw "xcrun simctl bootstatus $udid -b" > /dev/null
  printf '%s\n' "$udid"
}

sim_down() {
  local udid
  udid=$(sim_udid)
  [[ -n $udid ]] || { log "no simulator $SIM_NAME"; return 0; }
  remote_raw "xcrun simctl shutdown $udid 2>/dev/null || true"
  if [[ ${1:-} == --delete ]]; then
    remote_raw "xcrun simctl delete $udid"
    log "deleted $SIM_NAME ($udid)"
  else
    log "shut down $SIM_NAME ($udid)"
  fi
}

xcodebuild_remote() {
  local logfile=$1 derived=$2 destination=$3 action=$4 extra=${5:-} env_prefix=${6:-} gate
  if [[ $action == test ]]; then gate=$(uitest_gate); else gate=$(build_gate); fi
  remote "$gate mkdir -p .ioslogs && set +e && $env_prefix xcodebuild -project $PROJECT -scheme $SCHEME \
    -destination '$destination' -derivedDataPath $derived $extra $action \
    > .ioslogs/$logfile 2>&1; rc=\$?; \
    grep -E 'error:|BUILD (SUCCEEDED|FAILED)|ARCHIVE (SUCCEEDED|FAILED)|TEST (SUCCEEDED|FAILED)|Test Case .*(passed|failed)|Test Suite .* (passed|failed)|Executed [0-9]+ tests|Fatal error|Crash' .ioslogs/$logfile \
      | sed -E 's#/Users/[^/]+/Dev/ios/[^/]+/##' | awk '!seen[\$0]++' | head -60; exit \$rc"
}

app_path() {
  printf '~/%s/%s/Build/Products/Debug-iphonesimulator/Crucible.app\n' "$REMOTE" "$DERIVED"
}

build() {
  local udid
  timed generate generate
  udid=$(sim_ensure)
  timed xcodebuild xcodebuild_remote build.log "$DERIVED" "platform=iOS Simulator,id=$udid" build "ARCHS=arm64 ONLY_ACTIVE_ARCH=YES"
  remote_raw "ls $(app_path)/PlugIns && echo $(app_path)"
}

device_build() {
  timed generate generate
  timed xcodebuild xcodebuild_remote device-build.log "$DERIVED_DEVICE" "generic/platform=iOS" build "-configuration Release CODE_SIGNING_ALLOWED=NO"
  remote_raw "ls ~/$REMOTE/$DERIVED_DEVICE/Build/Products/Release-iphoneos/Crucible.app/PlugIns"
}

archive_check() {
  timed generate generate
  remote "rm -rf $ARCHIVE"
  timed xcodebuild xcodebuild_remote archive.log "$DERIVED_DEVICE" "generic/platform=iOS" archive "-archivePath $ARCHIVE CODE_SIGNING_ALLOWED=NO"
  remote "app=$ARCHIVE/Products/Applications/Crucible.app && ls \$app/PlugIns/CrucibleWidgets.appex > /dev/null && ls \$app/PrivacyInfo.xcprivacy && ls \$app/Assets.car && plutil -extract CFBundleShortVersionString raw \$app/Info.plist"
}

run_app() {
  local udid child_env="" pair var
  for pair in "$@"; do
    [[ $pair == *=* ]] || { log "run: expected VAR=value, got '$pair'"; return 2; }
    child_env+=" SIMCTL_CHILD_${pair%%=*}='${pair#*=}'"
  done
  for var in $(compgen -e | grep '^CRUCIBLE_'); do
    [[ " $* " == *" $var="* ]] || child_env+=$(printf " SIMCTL_CHILD_%s=%q" "$var" "${!var}")
  done
  timed generate generate
  udid=$(sim_up)
  timed xcodebuild xcodebuild_remote build.log "$DERIVED" "platform=iOS Simulator,id=$udid" build "ARCHS=arm64 ONLY_ACTIVE_ARCH=YES"
  remote "xcrun simctl terminate $udid $BUNDLE_ID 2>/dev/null; xcrun simctl install $udid $(app_path) && env$child_env xcrun simctl launch $udid $BUNDLE_ID"
  sleep "${RUN_SETTLE_SECONDS:-6}"
  shot run
}

shot() {
  local name=${1:?usage: ios.sh shot <name>} udid
  udid=$(sim_udid)
  [[ -n $udid ]] || { log "no simulator; run build or run first"; return 1; }
  mkdir -p "$OUT"
  remote "mkdir -p .ioslogs/shots && xcrun simctl io $udid screenshot .ioslogs/shots/$name.png" > /dev/null 2>&1
  scp -q -o BatchMode=yes "$MAC:$REMOTE/.ioslogs/shots/$name.png" "$OUT/$name.png" < /dev/null
  printf '%s\n' "$OUT/$name.png"
}

uitest() {
  local only="" udid test_env="" var
  while (($#)); do
    case $1 in
      -only) only=$2; shift 2 ;;
      *) log "test: unknown argument $1"; return 2 ;;
    esac
  done
  timed generate generate
  udid=$(sim_up)
  for var in $(compgen -e | grep '^CRUCIBLE_'); do
    test_env+=$(printf ' TEST_RUNNER_%s=%q' "$var" "${!var}")
  done
  local extra="-resultBundlePath .ioslogs/uitest.xcresult -configuration ${IOS_CONFIGURATION:-Debug}"
  [[ -z $only ]] || extra+=" -only-testing:CrucibleIOSUITests/$only"
  remote "rm -rf .ioslogs/uitest.xcresult .ioslogs/attachments"
  local rc=0
  timed uitest-run xcodebuild_remote uitest.log "$DERIVED" "platform=iOS Simulator,id=$udid" test "$extra ARCHS=arm64 ONLY_ACTIVE_ARCH=YES" "$test_env" || rc=$?
  export_attachments || rc=$?
  return $rc
}

export_attachments() {
  local raw=$OUT/ui/_raw
  rm -rf "$raw"
  mkdir -p "$raw"
  remote "test -d .ioslogs/uitest.xcresult && xcrun xcresulttool export attachments --path .ioslogs/uitest.xcresult --output-path .ioslogs/attachments" > /dev/null || { log "no xcresult to export"; return 0; }
  rsync -a -e "${SSH[*]}" "$MAC:$REMOTE/.ioslogs/attachments/" "$raw/"
  python3 -I "$ROOT/tv/scripts/arrange_attachments.py" "$raw" "$OUT/ui"
}

case "${1:-}" in
  generate) timed generate generate ;;
  build) build ;;
  device-build) device_build ;;
  archive-check) archive_check ;;
  run) shift; run_app "$@" ;;
  shot) shift; shot "$@" ;;
  test|uitest) shift; uitest "$@" ;;
  sim-down) shift; sim_down "$@" ;;
  *) usage; exit 2 ;;
esac
