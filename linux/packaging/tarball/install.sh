#!/bin/bash
# Installs Crucible from this release folder for the current user, or under PREFIX (or --prefix DIR):
#   PREFIX/lib/crucible/      the executable, its resource bundles, and the vendored libmpv and libplacebo
#   PREFIX/bin/crucible       a link to it
#   PREFIX/share/applications/org.guitaripod.Crucible.desktop and the icon in hicolor
# An existing install is replaced in one move, so a running Crucible keeps working until it restarts. The stamp in
# $XDG_STATE_HOME/crucible/install.json tells Crucible's Software Update that this install can replace itself.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
prefix="${PREFIX:-$HOME/.local}"
if [ "${1:-}" = --prefix ] && [ -n "${2:-}" ]; then
    prefix="$2"
fi
mkdir -p "$prefix/lib" "$prefix/bin"
prefix="$(cd "$prefix" && pwd -P)"
lib="$prefix/lib/crucible"

staging="$(mktemp -d "$prefix/lib/.crucible-install.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
cp -a "$here/lib/." "$staging/"
chmod 755 "$staging"
version="$("$staging/crucible" --version | awk '{ print $NF }')"
if [ -z "$version" ]; then
    echo "install: the crucible in $here/lib does not run on this machine" >&2
    exit 1
fi

old=""
if [ -e "$lib" ]; then
    old="$(mktemp -d "$prefix/lib/.crucible-old.XXXXXX")"
    mv "$lib" "$old/crucible"
fi
mv "$staging" "$lib"
trap - EXIT
[ -n "$old" ] && rm -rf "$old"
ln -sf "$lib/crucible" "$prefix/bin/crucible"

for size in 64 128 256 512; do
    install -Dm644 "$here/share/icons/hicolor/${size}x${size}/apps/org.guitaripod.Crucible.png" \
        "$prefix/share/icons/hicolor/${size}x${size}/apps/org.guitaripod.Crucible.png"
done
mkdir -p "$prefix/share/applications"
sed "s|^Exec=crucible|Exec=$lib/crucible|" "$here/share/applications/org.guitaripod.Crucible.desktop" \
    > "$prefix/share/applications/org.guitaripod.Crucible.desktop"
command -v update-desktop-database >/dev/null && update-desktop-database -q "$prefix/share/applications" || true
command -v gtk-update-icon-cache >/dev/null && gtk-update-icon-cache -q -t "$prefix/share/icons/hicolor" 2>/dev/null || true

json() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
state="${XDG_STATE_HOME:-$HOME/.local/state}/crucible"
mkdir -p "$state"
binary="$(realpath "$lib/crucible")"
printf '{"kind":"tarball","version":"%s","binary":"%s","size":%s,"prefix":"%s","installedAt":"%s"}\n' \
    "$(json "$version")" "$(json "$binary")" "$(stat -c %s "$binary")" "$(json "$prefix")" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    > "$state/install.json.tmp"
mv "$state/install.json.tmp" "$state/install.json"
"$lib/crucible" --version
