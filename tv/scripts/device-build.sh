#!/usr/bin/env bash
set -euo pipefail

export PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:$HOME/.local/bin
cd "$(dirname "$0")/../.."

SIGN=${TV_SIGNING_DIR:-$HOME/.config/midgar/signing}
PROFILE=${TV_PROFILE:-$SIGN/crucible-tvos-dev-2026.mobileprovision}
P12=${TV_P12:-$SIGN/midgar_distribution.p12}
P12_PASSWORD_FILE=${TV_P12_PASSWORD_FILE:-$P12.password}
BUILD_NUMBER=${TV_BUILD_NUMBER:-}
PYTHON=${PYTHON:-/opt/homebrew/bin/python3}
PROJECT=tv/CrucibleTVDevice.xcodeproj
SCHEME=CrucibleTVDevice
DERIVED=.dd-tvdevice
PRODUCTS=$DERIVED/Build/Products/Release-appletvos
KEYCHAIN=$PWD/.tvdevice.keychain-db
LOGS=.tvlogs
PROFILES_DIR="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"

usage() {
  cat << 'USAGE'
Runs on the Mac, inside the synced checkout. Normally started by scripts/install-tv.sh.

  device-build.sh check    generate the device project and compile it for tvOS without signing
  device-build.sh build    the same, signed with the development profile; prints the .app path

TV_PROFILE (default ~/.config/midgar/signing/crucible-tvos-dev-2026.mobileprovision), TV_P12 and TV_P12_PASSWORD_FILE
(default midgar_distribution.p12, which holds the Apple Development identity) and TV_BUILD_NUMBER override the inputs.
USAGE
}

log() {
  printf '[device-build] %s\n' "$*" >&2
}

profile_field() {
  "$PYTHON" tv/scripts/device-spec.py --spec tv/project.yml --profile "$PROFILE" --summary | plutil -extract "$1" "${2:-raw}" -o - -
}

generate_project() {
  mkdir -p tv/Generated/Device
  "$PYTHON" tv/scripts/device-spec.py --spec tv/project.yml --profile "$PROFILE" --output tv/Generated/project.device.yml \
    ${BUILD_NUMBER:+--build-number "$BUILD_NUMBER"}
  xcodegen generate --spec tv/Generated/project.device.yml --project-root tv --project tv --quiet
  log "generated $PROJECT for $(profile_field bundleId)"
}

require_device_in_profile() {
  [[ -z ${TV_DEVICE_UDID:-} ]] && return 0
  profile_field udids json | grep -qi "$TV_DEVICE_UDID" \
    || { log "the Apple TV $TV_DEVICE_UDID is not in $PROFILE; register its UDID and mint the profile again (tv/README.md)"; return 1; }
}

install_profile() {
  mkdir -p "$PROFILES_DIR"
  cp "$PROFILE" "$PROFILES_DIR/$(profile_field uuid).mobileprovision"
}

keychains_without_ours() {
  security list-keychains -d user | tr -d '"' | xargs -n1 | { grep -vxF "$KEYCHAIN" || true; } | xargs
}

leave_keychain() {
  local remaining
  remaining=$(keychains_without_ours)
  [[ -z $remaining ]] || security list-keychains -d user -s $remaining
  security delete-keychain "$KEYCHAIN" 2> /dev/null || true
  rm -f "$KEYCHAIN"
}

enter_keychain() {
  local password identities
  leave_keychain
  trap leave_keychain EXIT
  password=$(uuidgen)
  security create-keychain -p "$password" "$KEYCHAIN"
  security set-keychain-settings -lut 21600 "$KEYCHAIN"
  security unlock-keychain -p "$password" "$KEYCHAIN"
  security import "$P12" -k "$KEYCHAIN" -P "$(cat "$P12_PASSWORD_FILE")" -T /usr/bin/codesign -T /usr/bin/security > /dev/null
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$password" "$KEYCHAIN" > /dev/null 2>&1
  security list-keychains -d user -s "$KEYCHAIN" $(keychains_without_ours)
  identities=$(security find-identity -v -p codesigning "$KEYCHAIN")
  grep -q "$(profile_field identity)" <<< "$identities" \
    || { log "the identity $(profile_field identity) named by the profile is not in $P12"; return 1; }
}

compile() {
  local rc=0
  mkdir -p "$LOGS"
  xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release -destination generic/platform=tvOS \
    -derivedDataPath "$DERIVED" "$@" build > "$LOGS/device-build.log" 2>&1 || rc=$?
  grep -E 'error:|BUILD (SUCCEEDED|FAILED)' "$LOGS/device-build.log" | sed -E 's#/Users/[^/]+/Dev/ios/[^/]+/##' | awk '!seen[$0]++' | head -60
  return $rc
}

verify_signature() {
  local app=$1
  codesign --verify --strict --deep "$app"
  codesign -dvv "$app" 2>&1 | grep -E '^(Identifier|Authority|TeamIdentifier)=' | head -4
  cmp -s "$app/embedded.mobileprovision" "$PROFILE" || { log "embedded.mobileprovision is not $PROFILE"; return 1; }
}

case "${1:-}" in
  check)
    generate_project
    compile CODE_SIGNING_ALLOWED=NO
    ;;
  build)
    require_device_in_profile
    generate_project
    install_profile
    enter_keychain
    compile
    verify_signature "$PWD/$PRODUCTS/Crucible.app"
    printf '%s\n' "$PWD/$PRODUCTS/Crucible.app"
    ;;
  *)
    usage
    exit 2
    ;;
esac
