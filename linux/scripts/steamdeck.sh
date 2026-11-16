#!/bin/bash
# Builds Crucible for the Steam Deck and installs it there. SteamOS trails Arch (FFmpeg 8 where Arch has 9), so a build made
# on Arch does not load on it; this one is built in a container on SteamOS's own package repositories
# (linux/packaging/steamos), with the vendored libmpv and libplacebo built against them.
#
#   linux/scripts/steamdeck.sh build                  the build, staged in linux/.build/steamos/stage
#   linux/scripts/steamdeck.sh install [HOST]         build, then install on HOST (default deck@steamdeck) into ~/.local
#   linux/scripts/steamdeck.sh deploy [HOST]          install the last build without building
#
# Needs podman and a Swift toolchain (swiftly's, or SWIFT_TOOLCHAIN=/path/to/usr/..). The Steam shortcut is added by
# linux/scripts/steam-library.py on the Deck, which talks to the running Steam, so Game Mode never has to restart.
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
steamos="${STEAMOS_VERSION:-3.9}"
image="crucible-steamos:$steamos"
work="$repo/linux/.build/steamos"
stage="$work/stage"
toolchain="${SWIFT_TOOLCHAIN:-$(ls -d "$HOME"/.local/share/swiftly/toolchains/* 2>/dev/null | sort -V | tail -1)}"

build_image() {
    local containerfile="$repo/linux/packaging/steamos/Containerfile"
    local stamp
    stamp="$(cat "$containerfile" "$repo/linux/packaging/steamos/pacman.conf" | sha256sum | cut -c1-16)"
    if [ "$(podman image inspect "$image" --format '{{ index .Labels "crucible.recipe" }}' 2>/dev/null)" != "$stamp" ]; then
        podman build -q --label "crucible.recipe=$stamp" -t "$image" "$repo/linux/packaging/steamos" > /dev/null
    fi
}

build() {
    [ -x "$toolchain/usr/bin/swift" ] || { echo "steamdeck: no Swift toolchain at '$toolchain'; set SWIFT_TOOLCHAIN" >&2; exit 1; }
    build_image
    mkdir -p "$work" "$HOME/.cache/org.swift.swiftpm"
    podman run --rm -v "$repo:/src" -v "$toolchain:/opt/swift:ro" -v "$HOME/.cache/org.swift.swiftpm:/root/.cache/org.swift.swiftpm" \
        -w /src "$image" bash -euo pipefail -c '
            mpv=/src/linux/.build/steamos/mpv
            MPV_PREFIX="$mpv" MPV_WORK=/src/linux/.build/steamos/mpv-src linux/scripts/build-mpv.sh --if-stale
            [ -f "$mpv/lib/libaccesskit.a" ] || MPV_PREFIX="$mpv" ACCESSKIT_WORK=/src/linux/.build/steamos/accesskit-src linux/scripts/build-accesskit.sh
            rm -rf /src/linux/.build/steamos/mpv-src
            export PKG_CONFIG_PATH="$mpv/lib/pkgconfig" PATH=/opt/swift/usr/bin:/usr/bin
            swift build -c release --product crucible --static-swift-stdlib --scratch-path /src/.build/steamos
            built="$(swift build -c release --product crucible --static-swift-stdlib --scratch-path /src/.build/steamos --show-bin-path)"
            stage=/src/linux/.build/steamos/stage
            rm -rf "$stage"
            mkdir -p "$stage/lib" "$stage/share/applications"
            install -m 755 "$built/crucible" "$stage/lib/crucible"
            for bundle in "$built"/*.resources "$built"/*.bundle; do
                [ -e "$bundle" ] && cp -rL "$bundle" "$stage/lib/"
            done
            cp -P "$mpv"/lib/libmpv.so* "$mpv"/lib/libplacebo.so* "$stage/lib/"
            patchelf --set-rpath "\$ORIGIN" "$stage/lib/crucible"
            for size in 64 128 256 512; do
                mkdir -p "$stage/share/icons/hicolor/${size}x${size}/apps"
                magick linux/Resources/org.guitaripod.Crucible.png -resize "${size}x${size}" "$stage/share/icons/hicolor/${size}x${size}/apps/org.guitaripod.Crucible.png"
            done
            cp linux/packaging/org.guitaripod.Crucible.desktop "$stage/share/applications/"
            cp linux/scripts/steam-library.py "$stage/"
            cp -r linux/packaging/steamos/steam-art "$stage/"
            "$stage/lib/crucible" --version
        '
}

install_on() {
    local host="$1" commit
    commit="$(git -C "$repo" rev-parse HEAD 2>/dev/null || echo "${CRUCIBLE_COMMIT:-}")"
    ssh "$host" mkdir -p .local/lib
    rsync -a --delete "$stage/" "$host:.local/lib/.crucible-incoming/"
    ssh "$host" bash -euo pipefail -s -- "$commit" <<'REMOTE'
commit="$1"
prefix="$HOME/.local"
incoming="$prefix/lib/.crucible-incoming"
lib="$prefix/lib/crucible"
mkdir -p "$prefix/bin" "$prefix/share/applications"
cp -r "$incoming/share/icons" "$prefix/share/"
sed "s|^Exec=crucible|Exec=$lib/crucible|" "$incoming/share/applications/org.guitaripod.Crucible.desktop" > "$prefix/share/applications/org.guitaripod.Crucible.desktop"
install -Dm755 "$incoming/steam-library.py" "$prefix/share/crucible/steam-library.py"
rm -rf "$prefix/share/crucible/steam-art"
cp -r "$incoming/steam-art" "$prefix/share/crucible/steam-art"
rm -rf "$lib.old"
if [ -d "$lib" ]; then mv "$lib" "$lib.old"; fi
mv "$incoming/lib" "$lib"
rm -rf "$lib.old" "$incoming"
ln -sf "$lib/crucible" "$prefix/bin/crucible"
command -v update-desktop-database > /dev/null && update-desktop-database -q "$prefix/share/applications" || true
missing="$(ldd "$lib/crucible" | grep 'not found' || true)"
[ -z "$missing" ] || { echo "steamdeck: missing libraries on the Deck:" >&2; echo "$missing" >&2; exit 1; }
state="${XDG_STATE_HOME:-$HOME/.local/state}/crucible"
mkdir -p "$state"
binary="$(realpath "$lib/crucible")"
version="$("$binary" --version | awk '{ print $NF }')"
printf '{"kind":"steamdeck","version":"%s","binary":"%s","size":%s,"prefix":"%s","commit":"%s","installedAt":"%s"}\n' \
    "$version" "$binary" "$(stat -c %s "$binary")" "$prefix" "$commit" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$state/install.json.tmp"
mv "$state/install.json.tmp" "$state/install.json"
python3 "$prefix/share/crucible/steam-library.py" --exe "$lib/crucible" || echo "steamdeck: Steam shortcut not updated (is Steam running?)" >&2
"$binary" --version
REMOTE
}

case "${1:-}" in
    build) build ;;
    install)
        build
        install_on "${2:-deck@steamdeck}"
        ;;
    deploy) install_on "${2:-deck@steamdeck}" ;;
    *)
        echo "usage: steamdeck.sh build | install [HOST] | deploy [HOST]" >&2
        exit 2
        ;;
esac
