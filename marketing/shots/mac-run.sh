#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../.."
ROOT=$PWD
NAME=${NAME:-CrucibleSim}
PORT=${PORT:-$((32400 + $(printf %s "$NAME" | cksum | cut -d' ' -f1) % 500))}
MODE=${MODE:-dark}
SIGNALS=/tmp/crucible-shots-$NAME
RAW=${RAW:-$ROOT/marketing/shots/out/raw-$MODE}
DEVICE_TYPE=${DEVICE_TYPE:-iPhone 17 Pro Max}
DUO_STATE=${DUO_STATE:-}
APP_ID=com.guitaripod.crucible.shots
DEVICE_NAME=CrucibleShots-$NAME
PIDFILE=/tmp/crucible-mock-$PORT.pid
MOCK_LOG=/tmp/crucible-mock-$PORT.log
XCODE_LOG=/tmp/crucible-xcodebuild-$NAME.log
PACKAGE_NAME=$(basename "$ROOT" | tr 'A-Z-' 'a-z_')
OWN_DEVICE=0
BOOTED_HERE=0

stop_mock() {
  if [ -f "$PIDFILE" ]; then
    kill "$(cat "$PIDFILE")" 2>/dev/null || true
    rm -f "$PIDFILE"
  fi
}

cleanup() {
  stop_mock
  if [ "$OWN_DEVICE" = 1 ] && [ "${CLEAN:-0}" = 1 ]; then
    xcrun simctl shutdown "$UDID" 2>/dev/null || true
    xcrun simctl delete "$UDID" 2>/dev/null || true
  elif [ "$OWN_DEVICE" = 1 ] && [ "$BOOTED_HERE" = 1 ]; then
    xcrun simctl shutdown "$UDID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

find_device() {
  xcrun simctl list devices | grep -F "    $DEVICE_NAME (" \
    | grep -oE '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}' | head -1 || true
}

create_device() {
  local devtype runtime udid
  devtype=$(xcrun simctl list devicetypes | grep -F "$DEVICE_TYPE (" \
    | grep -oE 'com\.apple\.CoreSimulator\.SimDeviceType\.[^)]+' | head -1)
  for runtime in $(xcrun simctl list runtimes | grep -E '^iOS [0-9]' | grep -v unavailable \
    | awk '{print $2, $0}' | sort -rV | grep -oE 'com\.apple\.CoreSimulator\.SimRuntime\.iOS-[0-9-]+'); do
    udid=$(xcrun simctl create "$DEVICE_NAME" "$devtype" "$runtime" 2>/dev/null) || continue
    echo "$udid"
    return 0
  done
  echo "no installed iOS runtime can host $devtype" >&2
  return 1
}

if [ -z "${UDID:-}" ]; then
  UDID=$(find_device)
  if [ -z "$UDID" ]; then UDID=$(create_device); fi
  OWN_DEVICE=1
fi

stop_mock
mkdir -p "$RAW" "$SIGNALS"
rm -f "$RAW"/*.png "$SIGNALS"/*

PORT=$PORT nohup python3 "$ROOT/marketing/mock/server.py" > "$MOCK_LOG" 2>&1 < /dev/null &
echo $! > "$PIDFILE"
mock_up=0
for _ in $(seq 1 150); do
  if curl -fs -H 'Accept: application/json' "http://127.0.0.1:$PORT/identity" > /dev/null; then mock_up=1; break; fi
  sleep 0.2
done
sleep 0.5
if [ "$mock_up" != 1 ] || ! kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
  echo "mock server did not start on port $PORT (port taken?), see $MOCK_LOG" >&2
  exit 1
fi

if [ "$OWN_DEVICE" = 1 ] && ! xcrun simctl list devices | grep -F "$UDID" | grep -q Booted; then BOOTED_HERE=1; fi
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b > /dev/null
xcrun simctl ui "$UDID" appearance "$MODE"
xcrun simctl ui "$UDID" content_size large
xcrun simctl status_bar "$UDID" override --time 9:41 --batteryState charged --batteryLevel 100 --cellularMode active --cellularBars 4 --wifiBars 3 --operatorName ""

APP=$ROOT/.dd/Build/Products/Debug-iphonesimulator/CrucibleShots.app
if [ "${SKIP_BUILD:-0}" = 1 ] && [ -d "$APP" ]; then
  echo "reusing the built harness"
else
  perl -0pi -e 's/let iosStamp: \[LinkerSetting\] = \[.*?\n\]\n/let iosStamp: [LinkerSetting] = []\n/s' Package.swift
  sed -i '' 's/^@main$//' Sources/Crucible/App/CrucibleApp.swift
  sed -i '' '/requestAuthorization/d' Sources/Crucible/App/AppDelegate.swift

  cp Localization/Localizable.xcstrings marketing/shots/Sources/Localizable.xcstrings
  rm -rf .dd/Build/Intermediates.noindex/Crucible.build .dd/Build/Intermediates.noindex/CrucibleShots.build
  xcodebuild -project marketing/shots/CrucibleShots.xcodeproj -scheme CrucibleShots \
    CRUCIBLE_PACKAGE_NAME="$PACKAGE_NAME" -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath "$ROOT/.dd" \
    build > "$XCODE_LOG" 2>&1 || { tail -40 "$XCODE_LOG"; exit 1; }
fi
pose_duo() {
  case "$DUO_STATE" in
    outer-*) duoctl -d "$UDID" close > /dev/null ;;
    inner-*) duoctl -d "$UDID" open > /dev/null ;;
    *) echo "unknown DUO_STATE $DUO_STATE (inner-landscape, inner-portrait, outer-portrait, outer-landscape)" >&2; exit 1 ;;
  esac
  sleep 2
  duoctl -d "$UDID" rotate "${DUO_STATE#*-}" > /dev/null
  sleep 2
}

shoot() {
  if [ -n "$DUO_STATE" ]; then
    duoctl -d "$UDID" screenshot "$1" > /dev/null 2>&1
  else
    xcrun simctl io "$UDID" screenshot --type=png "$1" > /dev/null 2>&1
  fi
}

# A tap in the middle of the screen, which the harness asks for (a signal named tap-center…) where only a real touch
# will do: the system player shows its controls for one. The middle is the same point however the device is turned.
tap_center() {
  local size
  if [ -n "$DUO_STATE" ]; then
    size=$(duoctl -d "$UDID" state | python3 -c 'import json,sys
width,height=json.load(sys.stdin)["sizePoints"]
print(width/2, height/2)') || return 0
    duoctl -d "$UDID" tap ${size% *} ${size#* } > /dev/null 2>&1 || true
    return 0
  fi
  size=$(axe describe-ui --udid "$UDID" 2>/dev/null | python3 -c 'import json,sys
node=json.load(sys.stdin)
node=node[0] if isinstance(node,list) else node
frame=node["frame"]
print(frame["width"]/2, frame["height"]/2)' 2>/dev/null) || return 0
  axe tap -x "${size% *}" -y "${size#* }" --udid "$UDID" > /dev/null 2>&1 || true
}

# A finger put down on the system player's scrubber and held (press-scrubber), then lifted (release-scrubber), for the
# harness: only a real touch brings up the player's scrubbing state. The scrubber is the widest slider on screen, and
# the finger goes down on its thumb, so nothing moves. Not on an iPhone Duo: its simulator takes taps through duoctl but
# no touch that is held, so the Duo set keeps the player without the scrubbing state.
touch_scrubber() {
  local attempt
  [ -z "$DUO_STATE" ] || return 0
  if [ "$1" = release-scrubber ]; then
    [ -z "${SCRUB_POINT:-}" ] || axe touch -x "${SCRUB_POINT% *}" -y "${SCRUB_POINT#* }" --up --udid "$UDID" > /dev/null 2>&1 || true
    return 0
  fi
  if [ -n "${SCRUB_POINT:-}" ]; then
    axe touch -x "${SCRUB_POINT% *}" -y "${SCRUB_POINT#* }" --down --udid "$UDID" > /dev/null 2>&1 || true
    return 0
  fi
  for attempt in 1 2 3 4; do
    SCRUB_POINT=$(axe describe-ui --udid "$UDID" 2>/dev/null | python3 -c 'import json,sys
best=None
def walk(node):
    global best
    if isinstance(node,list):
        for child in node: walk(child)
        return
    frame=node.get("frame") or {}
    if node.get("type")=="Slider" and frame.get("width",0)>200 and (best is None or frame["width"]>best[0]["width"]):
        best=(frame, node.get("AXValue"))
    for child in node.get("children",[]): walk(child)
walk(json.load(sys.stdin))
frame,value=best
try: place=float(value)
except Exception: place=0.62
print(frame["x"]+frame["width"]*place, frame["y"]+frame["height"]/2)' 2>/dev/null) || SCRUB_POINT=
    if [ -n "$SCRUB_POINT" ]; then
      axe touch -x "${SCRUB_POINT% *}" -y "${SCRUB_POINT#* }" --down --udid "$UDID" > /dev/null 2>&1 || true
      echo "finger on the scrubber at $SCRUB_POINT"
      return 0
    fi
    tap_center
    sleep 0.3
  done
  echo "the scrubber never showed" >&2
}

xcrun simctl terminate "$UDID" "$APP_ID" 2>/dev/null || true
[ -z "$DUO_STATE" ] || pose_duo
[ "${KEEP_INSTALL:-0}" = 1 ] || xcrun simctl uninstall "$UDID" "$APP_ID" 2>/dev/null || true
xcrun simctl install "$UDID" "$APP"

LIGHT=0
[ "$MODE" = light ] && LIGHT=1
SIMCTL_CHILD_CRUCIBLE_MOCK="http://127.0.0.1:$PORT" \
SIMCTL_CHILD_CRUCIBLE_SIGNAL_DIR="$SIGNALS" \
SIMCTL_CHILD_CRUCIBLE_LIGHT="$LIGHT" \
SIMCTL_CHILD_CRUCIBLE_SHOT_SCRIPT="${SHOT_SCRIPT:-}" \
SIMCTL_CHILD_CRUCIBLE_COMPANION_CODE="${CRUCIBLE_COMPANION_CODE:-}" \
SIMCTL_CHILD_CRUCIBLE_COMPANION_HOST="${CRUCIBLE_COMPANION_HOST:-}" \
  env $(for pair in ${LAUNCH_ENV:-}; do printf 'SIMCTL_CHILD_%s ' "$pair"; done) \
  xcrun simctl launch "$UDID" "$APP_ID" -AppleLanguages "(${APP_LANGUAGE:-en})" -AppleLocale "${APP_LOCALE:-en_US}" > /dev/null

deadline=$((SECONDS + ${TIMEOUT:-420}))
tick=0
while [ $SECONDS -lt $deadline ]; do
  tick=$((tick + 1))
  if [ $((tick % 40)) -eq 0 ] && ! (xcrun simctl spawn "$UDID" launchctl list 2>/dev/null | grep "UIKitApplication:$APP_ID" > /dev/null || true; xcrun simctl spawn "$UDID" launchctl list 2>/dev/null | grep -c "UIKitApplication:$APP_ID" | grep -qv '^0$'); then
    echo "app is no longer running (crashed?)" >&2
    ls -t "$HOME"/Library/Logs/DiagnosticReports/CrucibleShots* 2>/dev/null | head -1 >&2
    exit 2
  fi
  for ready in $(ls -tr "$SIGNALS"/*.ready 2>/dev/null); do
    name=$(basename "$ready" .ready)
    if [ "$name" = done ]; then
      rm -f "$ready"
      cp "$SIGNALS"/*.png "$SIGNALS"/*.txt "$RAW"/ 2>/dev/null || true
      xcrun simctl status_bar "$UDID" clear
      exit 0
    fi
    if [ "$name" = press-scrubber ] || [ "$name" = release-scrubber ]; then
      touch_scrubber "$name"
      rm -f "$ready"
      touch "$SIGNALS/$name.ack"
      continue
    fi
    if [ "${name#tap-center}" != "$name" ]; then
      tap_center
      rm -f "$ready"
      touch "$SIGNALS/$name.ack"
      continue
    fi
    sleep 0.6
    shoot "$RAW/$name.png"
    rm -f "$ready"
    touch "$SIGNALS/$name.ack"
    echo "shot $name"
  done
  sleep 0.2
done
echo "timed out waiting for the app" >&2
exit 1
