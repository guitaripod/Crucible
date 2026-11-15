#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
MAC=${MAC:-mac}
PLATFORM=${1:-}
BUILD_NUMBER=${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}
MARKETING=${MARKETING:-$(grep -A1 CFBundleShortVersionString "$ROOT/InfoAdditions.plist" | grep -o '[0-9][0-9.]*' | head -1)}

usage() {
  cat << 'USAGE'
Archive Crucible for the App Store inside buildvm's stable-macOS guest and upload it to App Store Connect.

  scripts/store-build.sh ios        the iPhone app and its widget extension (ios/project.yml)
  scripts/store-build.sh tv         the Apple TV app and its Top Shelf extension (tv/project.yml)

BUILD_NUMBER=<n> sets CFBundleVersion (default: the time, yyyyMMddHHmm); MARKETING=<x.y.z> the version (default: InfoAdditions.plist);
NO_UPLOAD=1 builds and verifies without uploading; the staged checkout is rsynced from the working tree without .git, so buildvm's behind-upstream check is always skipped; CLEAN=1 empties the guest's DerivedData first.

The Mac runs a beta macOS, so a local archive would carry a beta BuildMachineOSBuild and be rejected (ITMS-90111): buildvm archives in
a Tart guest instead. It stages a checkout and runs xcodegen on a project.yml at its root, so scripts/store-spec.py derives that file
from ios/project.yml or tv/project.yml with distribution signing. The App Store profiles live in ~/.config/midgar/signing on the Mac.
USAGE
}

case "$PLATFORM" in
  ios) NAME=crucible; SCHEME=CrucibleIOS; PROJECT=CrucibleIOS; BUILDVM_PLATFORM=ios
       PROFILES=(crucible-ios-appstore-2026.mobileprovision crucible-widgets-appstore-2026.mobileprovision) ;;
  tv) NAME=crucible-tv; SCHEME=CrucibleTV; PROJECT=CrucibleTV; BUILDVM_PLATFORM=tvos
      PROFILES=(crucible-tvos-appstore-2026.mobileprovision crucible-topshelf-appstore-2026.mobileprovision) ;;
  *) usage; exit 2 ;;
esac

# The Trakt Client ID is kept out of the public repository, so a fresh clone or a git worktree lacks it and a build from
# there ships without Trakt. Takes it from the main checkout or the midgar vault when it is missing, and refuses to
# build without it.
ensure_trakt_id() {
  local file=Sources/CrucibleCore/Features/Trakt/TraktClientID.swift main source
  [[ -s "$ROOT/$file" ]] && return 0
  main=$(git -C "$ROOT" worktree list --porcelain | awk 'NR == 1 { print $2 }')
  for source in "$main/$file" "$HOME/.config/midgar/crucible/TraktClientID.swift"; do
    if [[ -s "$source" ]]; then
      cp "$source" "$ROOT/$file"
      echo "store-build: took $file from $source"
      return 0
    fi
  done
  echo "store-build: $file is missing, so this build would ship without Trakt; put it there or in ~/.config/midgar/crucible/ and run again" >&2
  exit 1
}

ensure_trakt_id
STAGE=Dev/ios/store-$NAME

NAME=store-$NAME "$ROOT/scripts/mac.sh" sync

profile_args=""
for profile in "${PROFILES[@]}"; do profile_args+=" --profile \$HOME/.config/midgar/signing/$profile"; done
flags="-project $PROJECT.xcodeproj -skipPackagePluginValidation -skipMacroValidation -scmProvider system"
extra=" --allow-stale"
[[ -z "${NO_UPLOAD:-}" ]] || extra+=" --no-upload"
[[ -z "${CLEAN:-}" ]] || extra+=" --clean"

ssh -o BatchMode=yes "$MAC" "cd ~/$STAGE && export PATH=\$HOME/Dev/buildvm/bin:/opt/homebrew/bin:/usr/local/bin:\$PATH \
  && python3 scripts/store-spec.py $PLATFORM --package-name ${NAME//-/_} --output project.yml \
  && buildvm build --dir ~/$STAGE --name $NAME --scheme $SCHEME --platform $BUILDVM_PLATFORM $profile_args \
       --build $BUILD_NUMBER --marketing $MARKETING --archive-flags '$flags' $extra" < /dev/null
