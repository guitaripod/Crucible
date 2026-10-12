#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)

source "$ROOT/scripts/slot-gate.sh"
MAC=${MAC:-mac}
NAME=${NAME:-CrucibleTV}
REMOTE=Dev/ios/$NAME
MOCK_REMOTE=Dev/ios/$NAME-mock
SHARED_ASSETS=Dev/ios/_mock-assets
SIM_NAME=CrucibleTV-$NAME
SIM_TYPE=com.apple.CoreSimulator.SimDeviceType.Apple-TV-4K-3rd-generation-1080p
SIM_RUNTIME=${TV_RUNTIME:-com.apple.CoreSimulator.SimRuntime.tvOS-26-5}
BUNDLE_ID=com.guitaripod.crucible
SCHEME=CrucibleTV
DERIVED=.dd-tvapp
OUT=$ROOT/tv/out
SSH=(ssh -o BatchMode=yes)

if [[ -z ${MOCK_PORT:-} ]]; then
  MOCK_PORT=$((32400 + $(printf '%s' "$NAME" | cksum | cut -d' ' -f1) % 500))
fi

usage() {
  cat << 'USAGE'
Build, run, drive and screenshot the Crucible tvOS app on the Mac's Apple TV simulator.

  tv.sh generate                 sync the tree and run xcodegen (skipped when project.yml and the tv/ file list are unchanged)
  tv.sh build                    generate, then xcodebuild the CrucibleTV scheme for the NAME simulator
  tv.sh sim-up                   create (if needed) and boot the CrucibleTV-$NAME simulator, print its UDID
  tv.sh sim-down [--delete]      shut the simulator down, optionally delete it
  tv.sh mock-up                  start the mock Plex server on the Mac for NAME, print its URL
  tv.sh mock-down                stop that mock server
  tv.sh run [VAR=value ...]      build, install, launch with CRUCIBLE_MOCK (when the mock is up); extra VAR=value become SIMCTL_CHILD_VAR
  tv.sh shot <name>              screenshot the simulator to tv/out/<name>.png
  tv.sh uitest [-only Class[/test]]   run the XCUITest bundle, export screenshot attachments to tv/out/ui/<Class>/<name>.png
  tv.sh logs                     copy the app's crucible.log to tv/out/crucible.log and print its tail
  tv.sh reset                    uninstall the app and wipe its data container, keep the simulator

NAME=<id> isolates the remote checkout (~/Dev/ios/$NAME), DerivedData, the simulator device and the mock port
(32400 + cksum(NAME) % 500, override with MOCK_PORT). MAC=<ssh host> picks the build Mac (default: mac).
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
    "$ROOT/" "$MAC:$REMOTE/"
}

generate() {
  sync_tree
  remote 'cd tv && want=$( { cat project.yml; find App TopShelf UITests Resources -type f | sort; } | shasum | cut -d" " -f1 )
    if [ -d CrucibleTV.xcodeproj ] && [ "$(cat .gen-hash 2>/dev/null)" = "$want" ]; then
      echo "xcodegen: project up to date"
    else
      xcodegen generate --spec project.yml --quiet && echo "$want" > .gen-hash && echo "xcodegen: generated tv/CrucibleTV.xcodeproj"
    fi'
}

sim_udid() {
  remote_raw "xcrun simctl list devices tvOS" | sed -nE "s/^ +$SIM_NAME \(([0-9A-F-]{36})\).*/\1/p" | head -1
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
  local udid=$1 action=$2 logfile=$3 extra=${4:-} env_prefix=${5:-} gate
  if [[ $action == test ]]; then gate=$(uitest_gate); else gate=$(build_gate); fi
  remote "$gate mkdir -p .tvlogs && set +e && $env_prefix xcodebuild -project tv/CrucibleTV.xcodeproj -scheme $SCHEME \
    -destination 'platform=tvOS Simulator,id=$udid' -derivedDataPath $DERIVED ARCHS=arm64 ONLY_ACTIVE_ARCH=YES $extra $action \
    > .tvlogs/$logfile 2>&1; rc=\$?; \
    grep -E 'error:|BUILD (SUCCEEDED|FAILED)|TEST (SUCCEEDED|FAILED)|Test Case .*(passed|failed)|Test Suite .* (passed|failed)|Executed [0-9]+ tests' .tvlogs/$logfile \
      | sed -E 's#/Users/[^/]+/Dev/ios/[^/]+/##' | head -60; exit \$rc"
}

app_path() {
  printf '~/%s/%s/Build/Products/Debug-appletvsimulator/Crucible.app\n' "$REMOTE" "$DERIVED"
}

build() {
  local udid
  timed generate generate
  udid=$(sim_ensure)
  timed xcodebuild xcodebuild_remote "$udid" build build.log
  remote_raw "cd $(app_path) && pwd"
}

mock_pidfile() {
  printf '~/%s/server-%s.pid' "$MOCK_REMOTE" "$MOCK_PORT"
}

mock_assets_source() {
  if [[ -d $ROOT/marketing/mock/assets ]]; then
    printf '%s\n' "$ROOT/marketing/mock/assets"
    return
  fi
  local common
  common=$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir)
  printf '%s\n' "$(dirname "$common")/marketing/mock/assets"
}

mock_env() {
  local var out="PORT=$MOCK_PORT"
  for var in $(compgen -e | grep '^MOCK_' | grep -vE '^MOCK_(PORT|REMOTE)$'); do
    out+=$(printf ' %s=%q' "$var" "${!var}")
  done
  printf '%s' "$out"
}

mock_up() {
  local assets
  assets=$(mock_assets_source)
  [[ -d $assets ]] || { log "mock assets not found at $assets"; return 1; }
  mock_down quiet
  "${SSH[@]}" "$MAC" "mkdir -p ~/$MOCK_REMOTE ~/$SHARED_ASSETS" < /dev/null
  rsync -a --update -e "${SSH[*]}" "$assets/" "$MAC:$SHARED_ASSETS/"
  rsync -a --delete --exclude assets --exclude '*.pid' --exclude server.log --exclude __pycache__ -e "${SSH[*]}" \
    "$ROOT/marketing/mock/" "$MAC:$MOCK_REMOTE/"
  remote_raw "cd ~/$MOCK_REMOTE && ln -sfn ~/$SHARED_ASSETS assets && \
    ( env $(mock_env) nohup python3 server.py > server.log 2>&1 < /dev/null & echo \$! > $(mock_pidfile) )"
  local tries=0
  until remote_raw "curl -fsS -m 2 http://127.0.0.1:$MOCK_PORT/identity > /dev/null"; do
    tries=$((tries + 1))
    if ((tries > 30)); then
      log "mock did not answer on :$MOCK_PORT; server.log:"
      remote_raw "tail -20 ~/$MOCK_REMOTE/server.log" >&2 || true
      return 1
    fi
    sleep 1
  done
  printf 'http://127.0.0.1:%s\n' "$MOCK_PORT"
}

mock_down() {
  local quiet=${1:-} result
  result=$(remote_raw "pid=\$(cat $(mock_pidfile) 2>/dev/null); \
    if [ -n \"\$pid\" ] && ps -E -p \$pid -o command= 2>/dev/null | tr ' ' '\\n' | grep -qx 'PORT=$MOCK_PORT'; then kill \$pid && echo stopped; else echo none; fi; \
    rm -f $(mock_pidfile)")
  [[ -n $quiet ]] || log "mock :$MOCK_PORT $result"
}

mock_alive() {
  remote_raw "curl -fsS -m 2 http://127.0.0.1:$MOCK_PORT/identity > /dev/null 2>&1"
}

run_app() {
  local udid child_env="" pair
  for pair in "$@"; do
    [[ $pair == *=* ]] || { log "run: expected VAR=value, got '$pair'"; return 2; }
    child_env+=" SIMCTL_CHILD_${pair%%=*}='${pair#*=}'"
  done
  timed generate generate
  udid=$(sim_up)
  timed xcodebuild xcodebuild_remote "$udid" build build.log
  if mock_alive; then
    child_env+=" SIMCTL_CHILD_CRUCIBLE_MOCK=http://127.0.0.1:$MOCK_PORT"
  else
    log "mock not running on :$MOCK_PORT (tv.sh mock-up); launching without CRUCIBLE_MOCK"
  fi
  remote "xcrun simctl terminate $udid $BUNDLE_ID 2>/dev/null; xcrun simctl install $udid $(app_path) && env$child_env xcrun simctl launch $udid $BUNDLE_ID"
}

shot() {
  local name=${1:?usage: tv.sh shot <name>} udid
  udid=$(sim_udid)
  [[ -n $udid ]] || { log "no simulator; run sim-up"; return 1; }
  mkdir -p "$OUT"
  remote "mkdir -p .tvshots && xcrun simctl io $udid screenshot .tvshots/$name.png" > /dev/null 2>&1
  scp -q -o BatchMode=yes "$MAC:$REMOTE/.tvshots/$name.png" "$OUT/$name.png" < /dev/null
  printf '%s\n' "$OUT/$name.png"
}

uitest() {
  local only="" udid mock_env=""
  while (($#)); do
    case $1 in
      -only) only=$2; shift 2 ;;
      *) log "uitest: unknown argument $1"; return 2 ;;
    esac
  done
  forbid_blocking_loads_in_tests || return 1
  timed generate generate
  udid=$(sim_up)
  if mock_alive; then
    mock_env="TEST_RUNNER_CRUCIBLE_MOCK=http://127.0.0.1:$MOCK_PORT"
  fi
  local var
  for var in $(compgen -e | grep '^CRUCIBLE_' | grep -vx 'CRUCIBLE_MOCK'); do
    mock_env+=$(printf ' TEST_RUNNER_%s=%q' "$var" "${!var}")
  done
  local extra="-resultBundlePath .tvlogs/uitest.xcresult"
  [[ -z $only ]] || extra+=" -only-testing:CrucibleTVUITests/$only"
  remote "rm -rf .tvlogs/uitest.xcresult .tvlogs/attachments"
  local rc=0
  timed uitest-run xcodebuild_remote "$udid" test uitest.log "$extra" "$mock_env" || rc=$?
  export_attachments || rc=$?
  return $rc
}

export_attachments() {
  local raw=$OUT/ui/_raw
  rm -rf "$raw"
  mkdir -p "$raw"
  remote "test -d .tvlogs/uitest.xcresult && xcrun xcresulttool export attachments --path .tvlogs/uitest.xcresult --output-path .tvlogs/attachments" > /dev/null || { log "no xcresult to export"; return 0; }
  rsync -a -e "${SSH[*]}" "$MAC:$REMOTE/.tvlogs/attachments/" "$raw/"
  python3 -I "$ROOT/tv/scripts/arrange_attachments.py" "$raw" "$OUT/ui"
}

forbid_blocking_loads_in_tests() {
  if grep -n 'Data(contentsOf:\|String(contentsOf:' "$ROOT"/tv/UITests/*.swift; then
    log "UI tests must not load URLs synchronously (a runtime issue on the main thread); use a dataTask"
    return 1
  fi
}

logs() {
  local udid container
  udid=$(sim_udid)
  [[ -n $udid ]] || { log "no simulator"; return 1; }
  container=$(remote_raw "xcrun simctl get_app_container $udid $BUNDLE_ID data")
  mkdir -p "$OUT"
  remote_raw "for f in $container/Library/Logs/crucible.log $container/Library/Caches/Logs/crucible.log; do [ -f \$f ] && { cat \$f; exit 0; }; done; exit 3" > "$OUT/crucible.log" \
    || { log "no crucible.log in the data container yet"; return 1; }
  log "wrote $OUT/crucible.log"
  tail -40 "$OUT/crucible.log"
}

reset_app() {
  local udid
  udid=$(sim_udid)
  [[ -n $udid ]] || { log "no simulator"; return 0; }
  remote_raw "xcrun simctl terminate $udid $BUNDLE_ID 2>/dev/null; xcrun simctl uninstall $udid $BUNDLE_ID 2>/dev/null; true"
  log "uninstalled $BUNDLE_ID from $SIM_NAME"
}

case "${1:-}" in
  generate) timed generate generate ;;
  build) build ;;
  sim-up) timed sim-up sim_up ;;
  sim-down) shift; sim_down "$@" ;;
  mock-up) timed mock-up mock_up ;;
  mock-down) mock_down ;;
  run) shift; run_app "$@" ;;
  shot) shift; shot "$@" ;;
  uitest) shift; uitest "$@" ;;
  logs) logs ;;
  reset) reset_app ;;
  *) usage; exit 2 ;;
esac
