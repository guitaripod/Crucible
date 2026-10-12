#!/usr/bin/env bash
set -euo pipefail

IOS=$(cd "$(dirname "$0")/.." && pwd)

usage() {
  cat << 'USAGE'
Generate ios/CrucibleIOS.xcodeproj with XcodeGen (run it on the Mac, or anywhere xcodegen is installed).

SwiftPM names a local package after the lowercased directory that holds Package.swift and compiles its modules
with -package-name <that name>. The app target compiles Sources/Crucible itself and must pass the same name for
the package access level to resolve, so this script feeds it to project.yml as CRUCIBLE_PACKAGE_NAME.
USAGE
}

[[ ${1:-} != -h && ${1:-} != --help ]] || { usage; exit 0; }

CRUCIBLE_PACKAGE_NAME=$(basename "$(cd "$IOS/.." && pwd)" | tr '[:upper:]' '[:lower:]')
export CRUCIBLE_PACKAGE_NAME
cd "$IOS"
xcodegen generate --spec project.yml --quiet
echo "xcodegen: generated ios/CrucibleIOS.xcodeproj (package name $CRUCIBLE_PACKAGE_NAME)"
