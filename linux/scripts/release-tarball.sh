#!/bin/bash
# Builds the Linux release tarball from what is committed at HEAD, in a clean export so nothing uncommitted rides along:
#   linux/.build/dist/crucible-linux-X.Y.Z-ARCH.tar.zst and its .sha256
# The tarball holds lib/ (the executable, its resource bundles, the vendored libmpv and libplacebo), the icons, the desktop
# entry, the licence and install.sh, which installs it and stamps it so Software Update can replace it with the next one.
# Trakt's Client ID is kept out of the public repository, so a release says whether it carries it:
#   release-tarball.sh --with-trakt | --without-trakt
# Publishing is separate and needs Marcus's go: the script prints the gh command that would do it.
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
case "${1:-}" in
    --with-trakt) trakt=with ;;
    --without-trakt) trakt=without ;;
    *)
        echo "usage: release-tarball.sh --with-trakt | --without-trakt" >&2
        exit 2
        ;;
esac
mpv="$repo/linux/.build/mpv"
"$repo/linux/scripts/build-mpv.sh" --if-stale
[ -f "$mpv/lib/libaccesskit.a" ] || "$repo/linux/scripts/build-accesskit.sh"
trakt_id=Sources/CrucibleCore/Features/Trakt/TraktClientID.swift
if [ "$trakt" = with ] && [ ! -s "$repo/$trakt_id" ]; then
    echo "release: --with-trakt, but $trakt_id is missing" >&2
    exit 1
fi

version="$(git -C "$repo" show HEAD:linux/Sources/CrucibleApp/main.swift | sed -n 's/.*static let version = "\(.*\)"/\1/p')"
arch="$(uname -m)"
name="crucible-linux-$version-$arch"
work="$repo/linux/.build/release-work"
dist="$repo/linux/.build/dist"
rm -rf "$work"
mkdir -p "$work/src/linux/.build" "$dist"
trap 'rm -rf "$work"' EXIT
git -C "$repo" archive HEAD | tar -x -C "$work/src"
ln -s "$mpv" "$work/src/linux/.build/mpv"
[ "$trakt" = with ] && cp "$repo/$trakt_id" "$work/src/$trakt_id"

cd "$work/src"
PKG_CONFIG_PATH="$mpv/lib/pkgconfig" swift build -c release --product crucible --static-swift-stdlib
built="$(PKG_CONFIG_PATH="$mpv/lib/pkgconfig" swift build -c release --product crucible --static-swift-stdlib --show-bin-path)"

stage="$work/$name"
mkdir -p "$stage/lib" "$stage/share/applications"
install -m 755 "$built/crucible" "$stage/lib/crucible"
for bundle in "$built"/*.resources "$built"/*.bundle; do
    [ -e "$bundle" ] && cp -rL "$bundle" "$stage/lib/"
done
cp -P "$mpv"/lib/libmpv.so* "$mpv"/lib/libplacebo.so* "$stage/lib/"
patchelf --set-rpath '$ORIGIN' "$stage/lib/crucible"
for size in 64 128 256 512; do
    mkdir -p "$stage/share/icons/hicolor/${size}x${size}/apps"
    magick linux/Resources/org.guitaripod.Crucible.png -resize "${size}x${size}" "$stage/share/icons/hicolor/${size}x${size}/apps/org.guitaripod.Crucible.png"
done
cp linux/packaging/org.guitaripod.Crucible.desktop "$stage/share/applications/"
install -m 755 linux/packaging/tarball/install.sh "$stage/install.sh"
cp linux/packaging/tarball/README.md LICENSE "$stage/"
reported="$("$stage/lib/crucible" --version)"
if [ "$reported" != "crucible $version" ]; then
    echo "release: the built crucible reports '$reported', expected 'crucible $version'" >&2
    exit 1
fi

tar -C "$work" -cf - "$name" | zstd -19 -T0 -q -f -o "$dist/$name.tar.zst"
(cd "$dist" && sha256sum "$name.tar.zst" > "$name.tar.zst.sha256")
echo "release: $dist/$name.tar.zst ($(du -h "$dist/$name.tar.zst" | cut -f1), Trakt $trakt)"
echo "publish: gh release create linux-$version '$dist/$name.tar.zst' '$dist/$name.tar.zst.sha256' -R guitaripod/Crucible --title 'Crucible for Linux $version' --notes-file NOTES.md"
