#!/bin/bash
# Builds Crucible for Linux in release and installs it for the current user:
#   ~/.local/lib/crucible/      the executable, its resource bundles, and the vendored libmpv and libplacebo
#   ~/.local/bin/crucible       a link to it
#   ~/.local/share/applications/org.guitaripod.Crucible.desktop and the icon in hicolor
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
prefix="${PREFIX:-$HOME/.local}"
lib="$prefix/lib/crucible"
mpv="$repo/linux/.build/mpv"

[ -f "$mpv/lib/libmpv.so.2" ] || "$repo/linux/scripts/build-mpv.sh"

# Trakt's Client ID lives in a file kept out of the public repository; a build without it compiles but has no Trakt.
# Take it from the main checkout or the vault copy, as scripts/store-build.sh does, and refuse to install without it.
trakt_id=Sources/CrucibleCore/Features/Trakt/TraktClientID.swift
if [ ! -s "$repo/$trakt_id" ]; then
    main="$(git -C "$repo" worktree list --porcelain | awk 'NR == 1 { print $2 }')"
    for source in "$main/$trakt_id" "$HOME/.config/midgar/crucible/TraktClientID.swift"; do
        if [ -s "$source" ]; then
            cp "$source" "$repo/$trakt_id"
            echo "install: took $trakt_id from $source"
            break
        fi
    done
fi
if [ ! -s "$repo/$trakt_id" ] && [ "${CRUCIBLE_ALLOW_NO_TRAKT:-0}" != 1 ]; then
    echo "install: $trakt_id is missing, so this build would have no Trakt; put it there or in ~/.config/midgar/crucible/, or set CRUCIBLE_ALLOW_NO_TRAKT=1" >&2
    exit 1
fi

cd "$repo"
PKG_CONFIG_PATH="$mpv/lib/pkgconfig" swift build -c release --product crucible --static-swift-stdlib
built="$(PKG_CONFIG_PATH="$mpv/lib/pkgconfig" swift build -c release --product crucible --static-swift-stdlib --show-bin-path)"

staging="$(mktemp -d "$prefix/lib/.crucible-install.XXXXXX" 2>/dev/null || mktemp -d)"
chmod 755 "$staging"
trap 'rm -rf "$staging"' EXIT
install -m 755 "$built/crucible" "$staging/crucible"
for bundle in "$built"/*.resources "$built"/*.bundle; do
    [ -e "$bundle" ] && cp -rL "$bundle" "$staging/"
done
cp -P "$mpv"/lib/libmpv.so* "$mpv"/lib/libplacebo.so* "$staging/"
patchelf --set-rpath '$ORIGIN' "$staging/crucible"

mkdir -p "$prefix/lib" "$prefix/bin"
rm -rf "$lib"
mv "$staging" "$lib"
trap - EXIT
ln -sf "$lib/crucible" "$prefix/bin/crucible"

for size in 64 128 256 512; do
    dir="$prefix/share/icons/hicolor/${size}x${size}/apps"
    mkdir -p "$dir"
    magick "$repo/linux/Resources/org.guitaripod.Crucible.png" -resize "${size}x${size}" "$dir/org.guitaripod.Crucible.png"
done
mkdir -p "$prefix/share/applications"
cat > "$prefix/share/applications/org.guitaripod.Crucible.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=Crucible
GenericName=Plex Client
Comment=Your Plex library, beautifully on Linux
Exec=$lib/crucible %U
Icon=org.guitaripod.Crucible
Terminal=false
Categories=AudioVideo;Video;Player;TV;
Keywords=Plex;Movies;TV;Media;
StartupWMClass=org.guitaripod.Crucible
MimeType=x-scheme-handler/crucible;
Actions=Couch;

[Desktop Action Couch]
Name=Open on the TV (Couch)
Exec=$lib/crucible --couch
DESKTOP
command -v update-desktop-database >/dev/null && update-desktop-database -q "$prefix/share/applications" || true
command -v gtk-update-icon-cache >/dev/null && gtk-update-icon-cache -q -t "$prefix/share/icons/hicolor" 2>/dev/null || true
"$lib/crucible" --version
