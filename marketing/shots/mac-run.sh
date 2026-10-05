#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../.."
ROOT=$PWD
UDID=${UDID:?}
MODE=${MODE:-dark}
SIGNALS=/tmp/crucible-shots
RAW=$ROOT/marketing/shots/out/raw-$MODE
APP_ID=com.guitaripod.crucible.shots
PORT=32400

mkdir -p "$RAW" "$SIGNALS"
rm -f "$RAW"/*.png "$SIGNALS"/*

pkill -f "marketing/mock/server.py" 2>/dev/null || true
(cd marketing/mock && PORT=$PORT nohup python3 server.py > /tmp/crucible-mock.log 2>&1 &)
for _ in $(seq 1 50); do
  if curl -fs -H 'Accept: application/json' "http://127.0.0.1:$PORT/identity" > /dev/null; then break; fi
  sleep 0.2
done

xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b > /dev/null
xcrun simctl ui "$UDID" appearance "$MODE"
xcrun simctl status_bar "$UDID" override --time 9:41 --batteryState charged --batteryLevel 100 --cellularMode active --cellularBars 4 --wifiBars 3 --operatorName ""

perl -0pi -e 's/let iosStamp: \[LinkerSetting\] = \[.*?\n\]\n/let iosStamp: [LinkerSetting] = []\n/s' Package.swift
sed -i '' 's/^@main$//' Sources/Crucible/App/CrucibleApp.swift
sed -i '' '/requestAuthorization/d' Sources/Crucible/App/AppDelegate.swift

rm -rf .dd/Build/Intermediates.noindex/Crucible.build .dd/Build/Intermediates.noindex/CrucibleShots.build
xcodebuild -project marketing/shots/CrucibleShots.xcodeproj -scheme CrucibleShots \
  -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath "$ROOT/.dd" \
  build > /tmp/crucible-xcodebuild.log 2>&1 || { tail -40 /tmp/crucible-xcodebuild.log; exit 1; }

APP=$ROOT/.dd/Build/Products/Debug-iphonesimulator/CrucibleShots.app
xcrun simctl terminate "$UDID" "$APP_ID" 2>/dev/null || true
xcrun simctl uninstall "$UDID" "$APP_ID" 2>/dev/null || true
xcrun simctl install "$UDID" "$APP"

LIGHT=0
[ "$MODE" = light ] && LIGHT=1
SIMCTL_CHILD_CRUCIBLE_MOCK="http://127.0.0.1:$PORT" \
SIMCTL_CHILD_CRUCIBLE_SIGNAL_DIR="$SIGNALS" \
SIMCTL_CHILD_CRUCIBLE_LIGHT="$LIGHT" \
  xcrun simctl launch "$UDID" "$APP_ID" > /dev/null

deadline=$((SECONDS + ${TIMEOUT:-420}))
tick=0
while [ $SECONDS -lt $deadline ]; do
  tick=$((tick + 1))
  if [ $((tick % 40)) -eq 0 ] && ! xcrun simctl spawn "$UDID" launchctl list 2>/dev/null | grep -q "UIKitApplication:$APP_ID"; then
    echo "app is no longer running (crashed?)" >&2
    ls -t "$HOME"/Library/Logs/DiagnosticReports/CrucibleShots* 2>/dev/null | head -1 >&2
    exit 2
  fi
  for ready in $(ls -tr "$SIGNALS"/*.ready 2>/dev/null); do
    name=$(basename "$ready" .ready)
    if [ "$name" = done ]; then
      rm -f "$ready"
      pkill -f "marketing/mock/server.py" 2>/dev/null || true
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
