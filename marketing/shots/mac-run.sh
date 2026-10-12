#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../.."
ROOT=$PWD
NAME=${NAME:-CrucibleSim}
PORT=${PORT:-$((32400 + $(printf %s "$NAME" | cksum | cut -d' ' -f1) % 500))}
MODE=${MODE:-dark}
SIGNALS=/tmp/crucible-shots-$NAME
RAW=$ROOT/marketing/shots/out/raw-$MODE
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
  devtype=$(xcrun simctl list devicetypes | grep -F 'iPhone 17 Pro Max (' \
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
for _ in $(seq 1 50); do
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

perl -0pi -e 's/let iosStamp: \[LinkerSetting\] = \[.*?\n\]\n/let iosStamp: [LinkerSetting] = []\n/s' Package.swift
sed -i '' 's/^@main$//' Sources/Crucible/App/CrucibleApp.swift
sed -i '' '/requestAuthorization/d' Sources/Crucible/App/AppDelegate.swift

rm -rf .dd/Build/Intermediates.noindex/Crucible.build .dd/Build/Intermediates.noindex/CrucibleShots.build
xcodebuild -project marketing/shots/CrucibleShots.xcodeproj -scheme CrucibleShots \
  CRUCIBLE_PACKAGE_NAME="$PACKAGE_NAME" -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath "$ROOT/.dd" \
  build > "$XCODE_LOG" 2>&1 || { tail -40 "$XCODE_LOG"; exit 1; }

APP=$ROOT/.dd/Build/Products/Debug-iphonesimulator/CrucibleShots.app
xcrun simctl terminate "$UDID" "$APP_ID" 2>/dev/null || true
[ "${KEEP_INSTALL:-0}" = 1 ] || xcrun simctl uninstall "$UDID" "$APP_ID" 2>/dev/null || true
xcrun simctl install "$UDID" "$APP"

LIGHT=0
[ "$MODE" = light ] && LIGHT=1
SIMCTL_CHILD_CRUCIBLE_MOCK="http://127.0.0.1:$PORT" \
SIMCTL_CHILD_CRUCIBLE_SIGNAL_DIR="$SIGNALS" \
SIMCTL_CHILD_CRUCIBLE_LIGHT="$LIGHT" \
SIMCTL_CHILD_CRUCIBLE_SHOT_SCRIPT="${SHOT_SCRIPT:-}" \
  env $(for pair in ${LAUNCH_ENV:-}; do printf 'SIMCTL_CHILD_%s ' "$pair"; done) \
  xcrun simctl launch "$UDID" "$APP_ID" > /dev/null

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
    sleep 0.6
    xcrun simctl io "$UDID" screenshot --type=png "$RAW/$name.png" > /dev/null 2>&1
    rm -f "$ready"
    touch "$SIGNALS/$name.ack"
    echo "shot $name"
  done
  sleep 0.2
done
echo "timed out waiting for the app" >&2
exit 1
