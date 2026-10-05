#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

fail() {
  printf '\n%s\n\n' "$1" >&2
  exit 1
}

require_swift() {
  command -v swift > /dev/null && return
  case "$(uname)" in
    Darwin) fail "Swift is missing. Install Xcode 26 or newer from the App Store, open it once, then run this again." ;;
    *) fail "Swift is missing. Install the Swift 6.4 toolchain from https://swift.org/install/linux, then run this again." ;;
  esac
}

require_xtool() {
  command -v xtool > /dev/null && return
  case "$(uname)" in
    Darwin) fail "xtool is missing. Install it with: brew install xtool-org/tap/xtool" ;;
    *) fail "xtool is missing. Follow https://xtool.sh/documentation/xtooldocs/installation-linux, then run this again." ;;
  esac
}

require_ios_sdk() {
  [ "$(uname)" = "Darwin" ] && return
  swift sdk list 2> /dev/null | grep -qx darwin && return
  fail "xtool has no iOS SDK yet. Run: xtool setup (it asks for your Apple ID and the path to Xcode's .xip)."
}

require_device() {
  local devices
  devices=$(xtool devices 2> /dev/null || true)
  [ -n "$devices" ] && { printf 'Found: %s\n' "$devices"; return; }
  fail "No iPhone found. Plug it in with a cable, unlock it, tap Trust on the phone, then run this again."
}

require_swift
require_xtool
require_ios_sdk
require_device

if [ "$CHECK_ONLY" = 1 ]; then
  echo "Everything is ready. Run ./scripts/install-ios.sh to build and install Crucible."
  exit 0
fi

echo "Building Crucible and installing it on your iPhone. The first build takes several minutes."
echo "If xtool asks for Developer Mode, turn it on in Settings > Privacy & Security, restart the phone, and run this again."
xtool dev run -c release --usb

cat << 'DONE'

Installed. On the phone, open Settings > General > VPN & Device Management, tap your Apple ID, tap Trust,
then open Crucible and sign in with Plex.

A free Apple ID's build stops opening after 7 days. Run this script again to renew it.
DONE
