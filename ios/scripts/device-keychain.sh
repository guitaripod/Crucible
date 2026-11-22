#!/usr/bin/env bash
set -euo pipefail

export PATH=/usr/bin:/bin:/usr/sbin:/sbin
cd "$(dirname "$0")/../.."

SIGN=${IOS_SIGNING_DIR:-$HOME/.config/midgar/signing}
P12=${IOS_P12:-$SIGN/midgar_distribution.p12}
P12_PASSWORD_FILE=${IOS_P12_PASSWORD_FILE:-$P12.password}
KEYCHAIN=$PWD/.iosdevice.keychain-db

usage() {
  cat << 'USAGE'
Runs on the Mac, inside the synced checkout. Started by `ios.sh test` when IOS_DEVICE names a connected device: codesign over
SSH cannot reach the locked login keychain (errSecInternalComponent), so the Apple Development identity is imported from
the vault's p12 into a keychain of its own, first in the search list, for the length of the run.

  device-keychain.sh enter   create the keychain, import the identity, put it first in the search list
  device-keychain.sh leave   take it out of the search list and delete it

IOS_P12 and IOS_P12_PASSWORD_FILE (default midgar_distribution.p12, which holds the Apple Development identity) override the input.
USAGE
}

keychains_without_ours() {
  security list-keychains -d user | tr -d '"' | xargs -n1 | { grep -vxF "$KEYCHAIN" || true; } | xargs
}

leave() {
  local remaining
  remaining=$(keychains_without_ours)
  [[ -z $remaining ]] || security list-keychains -d user -s $remaining
  security delete-keychain "$KEYCHAIN" 2> /dev/null || true
  rm -f "$KEYCHAIN"
}

enter() {
  local password
  leave
  password=$(uuidgen)
  security create-keychain -p "$password" "$KEYCHAIN"
  security set-keychain-settings -lut 21600 "$KEYCHAIN"
  security unlock-keychain -p "$password" "$KEYCHAIN"
  security import "$P12" -k "$KEYCHAIN" -P "$(cat "$P12_PASSWORD_FILE")" -T /usr/bin/codesign -T /usr/bin/security > /dev/null
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$password" "$KEYCHAIN" > /dev/null 2>&1
  security list-keychains -d user -s "$KEYCHAIN" $(keychains_without_ours)
  security find-identity -v -p codesigning "$KEYCHAIN" | grep -q "Apple Development" \
    || { echo "device-keychain: no Apple Development identity in $P12" >&2; leave; return 1; }
}

case "${1:-}" in
  enter) enter ;;
  leave) leave ;;
  *) usage; exit 2 ;;
esac
