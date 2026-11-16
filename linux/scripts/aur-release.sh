#!/bin/bash
# Prepares the AUR packages for a Linux release, and with --push publishes them, which needs Marcus's AUR SSH key and his go:
#   aur-release.sh VERSION [--push]
# Points crucible's PKGBUILD at the linux-VERSION tag's source archive on GitHub with its real SHA-256 and pkgrel 1, moves
# crucible-git's pkgver to the tag, regenerates both .SRCINFO files, and with --push commits each package to its AUR
# repository. The tag has to be on GitHub first.
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
version="${1:?usage: aur-release.sh VERSION [--push]}"
push="${2:-}"
aur="$repo/linux/packaging/aur"
tag="linux-$version"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

if ! curl -fsSL "https://github.com/guitaripod/Crucible/archive/refs/tags/$tag.tar.gz" -o "$work/source.tar.gz"; then
    echo "aur: GitHub has no source archive for $tag; push the tag first" >&2
    exit 1
fi
sum="$(sha256sum "$work/source.tar.gz" | cut -d ' ' -f 1)"
sed -i "s/^pkgver=.*/pkgver=$version/; s/^pkgrel=.*/pkgrel=1/; s/^sha256sums=.*/sha256sums=('$sum')/" "$aur/crucible/PKGBUILD"
git -C "$repo" fetch -q origin "refs/tags/$tag:refs/tags/$tag" 2>/dev/null || true
if git -C "$repo" rev-parse -q --verify "$tag^{commit}" >/dev/null; then
    git_version="$version.r$(git -C "$repo" rev-list --count "$tag").g$(git -C "$repo" rev-parse --short "$tag^{commit}")"
    sed -i "s/^pkgver=.*/pkgver=$git_version/; s/^pkgrel=.*/pkgrel=1/" "$aur/crucible-git/PKGBUILD"
fi
for package in crucible crucible-git; do
    (cd "$aur/$package" && makepkg --printsrcinfo > .SRCINFO)
done
echo "aur: crucible $version ($sum) and crucible-git prepared in $aur"

if [ "$push" = --push ]; then
    for package in crucible crucible-git; do
        git clone -q "ssh://aur@aur.archlinux.org/$package.git" "$work/$package"
        cp "$aur/$package/PKGBUILD" "$aur/$package/.SRCINFO" "$work/$package/"
        git -C "$work/$package" add PKGBUILD .SRCINFO
        if git -C "$work/$package" diff --cached --quiet; then
            echo "aur: $package already up to date"
            continue
        fi
        git -C "$work/$package" commit -q -m "Update to $version"
        git -C "$work/$package" push -q origin HEAD:master
        echo "aur: pushed $package"
    done
fi
