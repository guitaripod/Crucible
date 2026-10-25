#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SIM_NAME=CrucibleIPadStore
SIM_TYPE=com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB
SIM_RUNTIME=com.apple.CoreSimulator.SimRuntime.iOS-27-0
OUT=$ROOT/marketing/shots/out/raw-ipad
CAPTURES=$ROOT/ios/out/ui-ipad/IPadStoreShots.testCapturesTheStoreScreens

usage() {
  cat << 'USAGE'
Capture the 13-inch iPad App Store screens (2752x2064 landscape) into marketing/shots/out/raw-ipad.

  marketing/store/shoot-ipad.sh

Prepares a dedicated simulator (CrucibleIPadStore: US English, dark, 9:41 status bar), then runs the IPadStoreShots UI test through
ios/scripts/ipad-uitest.sh with CRUCIBLE_STORE_SHOTS=1. Compose the store images afterwards with marketing/store/compose.py.
USAGE
}

[[ ${1:-} != -h && ${1:-} != --help ]] || { usage; exit 0; }

udid=$(xcrun simctl list devices iOS | sed -nE "s/^ +$SIM_NAME \(([0-9A-F-]{36})\).*/\1/p" | head -1)
if [[ -z $udid ]]; then
  udid=$(xcrun simctl create "$SIM_NAME" "$SIM_TYPE" "$SIM_RUNTIME")
  xcrun simctl boot "$udid"
  xcrun simctl bootstatus "$udid" -b > /dev/null
  xcrun simctl spawn "$udid" defaults write -g AppleLanguages -array en-US
  xcrun simctl spawn "$udid" defaults write -g AppleLocale -string en_US
  xcrun simctl shutdown "$udid"
fi
xcrun simctl boot "$udid" 2> /dev/null || true
xcrun simctl bootstatus "$udid" -b > /dev/null
xcrun simctl ui "$udid" appearance dark
xcrun simctl status_bar "$udid" override --time "2022-01-09T09:41:00.000+02:00" --batteryState charged --batteryLevel 100 --wifiBars 3 --cellularMode notSupported

CRUCIBLE_STORE_SHOTS=1 IPAD_SIM_NAME=$SIM_NAME "$ROOT/ios/scripts/ipad-uitest.sh" -only IPadStoreShots

rm -rf "$OUT"
mkdir -p "$OUT"
cp "$CAPTURES"/*.png "$OUT"/
ls "$OUT"
