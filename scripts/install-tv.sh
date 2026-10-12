#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
MAC=${MAC:-mac}
NAME=${NAME:-CrucibleTVDevice}
REMOTE=Dev/ios/$NAME
SSH=(ssh -o BatchMode=yes)
BUILD_NUMBER=${TV_BUILD_NUMBER:-$(date +%Y%m%d%H%M)}
APP=\~/$REMOTE/.dd-tvdevice/Build/Products/Release-appletvos/Crucible.app
DEVICE_LOG=/tmp/crucible-tv-device.log
OUT=$ROOT/tv/out

source "$ROOT/scripts/slot-gate.sh"

usage() {
  cat << 'USAGE'
Build Crucible for a real Apple TV on the Mac, sign it with the development profile, install it and launch it.

  scripts/install-tv.sh [install]   build, sign, install on the paired Apple TV, launch, confirm the installed build
  scripts/install-tv.sh build       build and sign without installing (no Apple TV needed); prints the .app path
  scripts/install-tv.sh check       compile the device variant for tvOS without signing (no Apple TV needed)
  scripts/install-tv.sh logs        copy the app's crucible.log from the Apple TV to tv/out/crucible-device.log and print its tail
  scripts/install-tv.sh devices     list the Apple TVs the Mac knows and whether each is paired
  scripts/install-tv.sh pair        pair the Apple TV with the Mac from the terminal (type the code the Apple TV shows)

TV_DEVICE=<name|identifier|UDID> picks the Apple TV when more than one is paired (for pair: its name, default "Apple TV").
NAME=<id> picks the remote checkout (~/Dev/ios/$NAME, default CrucibleTVDevice). MAC=<ssh host> picks the build Mac.
The Apple TV is paired once with the Mac; tv/README.md lists the steps and how the development profile is made.
USAGE
}

log() {
  printf '[%s] %s\n' "$NAME" "$*" >&2
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
    --exclude .tvlogs --exclude /tv/out --exclude /tv/Generated --exclude /tv/.gen-hash --exclude '.tvdevice.keychain-db' \
    "$ROOT/" "$MAC:$REMOTE/"
}

physical_apple_tvs() {
  remote_raw "xcrun devicectl list devices --json-output - 2> /dev/null" | python3 -c '
import json, sys
for device in json.load(sys.stdin)["result"]["devices"]:
    hardware = device["hardwareProperties"]
    if hardware.get("deviceType") == "appleTV" and hardware.get("reality") != "simulated":
        print(device["connectionProperties"].get("pairingState", "unknown"), device["identifier"], hardware["udid"], hardware["productType"], device["deviceProperties"]["name"], sep="\t")
'
}

explain_pairing() {
  cat >&2 << 'HINT'

The Mac has no paired Apple TV. Pair it once:
  1. Apple TV: Settings > Remotes and Devices > Remote App and Devices, and leave that screen open.
  2. Run scripts/install-tv.sh pair and type the code the Apple TV shows (or pair in Xcode: Window > Devices and Simulators > +).
Then run this again.
HINT
}

resolve_device() {
  local rows matches
  rows=$(physical_apple_tvs)
  matches=$(awk -F'\t' -v want="${TV_DEVICE:-}" '$1 == "paired" && (want == "" || $2 == want || $3 == want || $5 == want)' <<< "$rows")
  if [[ -z $matches ]]; then
    explain_pairing
    [[ -z $rows ]] || { printf 'Seen but not usable:\n%s\n' "$rows" >&2; }
    return 1
  fi
  if [[ $(wc -l <<< "$matches") -gt 1 ]]; then
    printf 'More than one paired Apple TV; set TV_DEVICE to a name, identifier or UDID:\n%s\n' "$matches" >&2
    return 1
  fi
  printf '%s\n' "$matches"
}

build_remote() {
  remote "$(build_gate) TV_BUILD_NUMBER=$BUILD_NUMBER TV_DEVICE_UDID=${1:-} tv/scripts/device-build.sh ${2:?}"
}

bundle_identifier() {
  remote_raw "plutil -extract CFBundleIdentifier raw -o - $APP/Info.plist"
}

deploy() {
  local row identifier udid name bundle installed
  row=$(resolve_device)
  IFS=$'\t' read -r _ identifier udid _ name <<< "$row"
  log "target: $name ($udid)"
  sync_tree
  build_remote "$udid" build
  bundle=$(bundle_identifier)
  remote_raw "xcrun devicectl device install app --device $identifier $APP" | tail -4
  remote_raw "xcrun devicectl device process launch --device $identifier --terminate-existing $bundle" | tail -2
  installed=$(remote_raw "xcrun devicectl device info apps --device $identifier --bundle-id $bundle")
  if grep -q "$BUILD_NUMBER" <<< "$installed"; then
    log "installed and launched $bundle build $BUILD_NUMBER on $name"
  else
    printf '%s\n' "$installed" >&2
    log "the Apple TV does not report build $BUILD_NUMBER for $bundle"
    return 1
  fi
}

device_logs() {
  local row identifier bundle
  row=$(resolve_device)
  IFS=$'\t' read -r _ identifier _ _ _ <<< "$row"
  bundle=$(bundle_identifier)
  mkdir -p "$OUT"
  remote_raw "rm -f $DEVICE_LOG; xcrun devicectl device copy from --device $identifier --domain-type appDataContainer \
    --domain-identifier $bundle --source Library/Caches/Logs/crucible.log --destination $DEVICE_LOG > /dev/null && cat $DEVICE_LOG" \
    > "$OUT/crucible-device.log"
  log "wrote $OUT/crucible-device.log"
  tail -40 "$OUT/crucible-device.log"
}

pair() {
  log "on the Apple TV open Settings > Remotes and Devices > Remote App and Devices and keep it open"
  "${SSH[@]}" -tt "$MAC" "xcrun devicectl manage pair --device '${TV_DEVICE:-Apple TV}'"
}

case "${1:-install}" in
  install) deploy ;;
  build) sync_tree; build_remote "" build ;;
  check) sync_tree; build_remote "" check ;;
  logs) device_logs ;;
  devices) physical_apple_tvs | column -t -s $'\t' ;;
  pair) pair ;;
  *) usage; exit 2 ;;
esac
