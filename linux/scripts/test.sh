#!/bin/bash
# Runs the package's tests (arguments go to `swift test`) with libmpv on the path and a throwaway XDG_CONFIG_HOME, so the
# UserDefaults suites Core's tests create land in a temporary directory instead of piling up in ~/.config.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
export PKG_CONFIG_PATH="$root/linux/.build/mpv/lib/pkgconfig" LD_LIBRARY_PATH="$root/linux/.build/mpv/lib"
swift build --build-tests
config="$(mktemp -d)"
trap 'rm -rf "$config"' EXIT
XDG_CONFIG_HOME="$config" swift test --skip-build "$@"
