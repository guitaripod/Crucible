#!/usr/bin/env bash
set -euo pipefail

SERVER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="guitaripod/Crucible"
TAP_REPO="guitaripod/homebrew-tap"
AUR_URL="ssh://aur@aur.archlinux.org/crucible-server-bin.git"
LINUX_HOST="${CRUCIBLE_SERVER_LINUX_HOST:-arch}"
VERSION="$(sed -n 's/^version = "\(.*\)"/\1/p' "$SERVER_DIR/Cargo.toml" | head -1)"
OUT="${CRUCIBLE_SERVER_RELEASE_DIR:-$HOME/.cache/crucible-server-release}/$VERSION"
TAG="server-v$VERSION"

usage() {
    cat << 'EOF'
Usage: server/scripts/release.sh <command>

  macos      Tests, then release binaries for arm64 and x86_64 macOS, ad-hoc signed, as tarballs
  linux      Static musl tarballs for x86_64 and aarch64, built on the Linux host (CRUCIBLE_SERVER_LINUX_HOST, default arch)
  packages   The Homebrew formula and the AUR PKGBUILD filled in with this release's checksums
  publish    The GitHub release server-v<version> with every tarball, the formula in guitaripod/homebrew-tap, and
             crucible-server-bin on the AUR (pushed from the Linux host)
  all        macos, linux, packages

The version comes from server/Cargo.toml; output goes to ~/.cache/crucible-server-release/<version>/.
EOF
}

tarball() {
    local binary=$1 name=$2
    local stage
    stage=$(mktemp -d)
    cp "$binary" "$stage/crucible-server"
    cp "$SERVER_DIR/README.md" "$SERVER_DIR/../LICENSE" "$stage/"
    COPYFILE_DISABLE=1 tar --no-xattrs --uid 0 --gid 0 -czf "$OUT/$name.tar.gz" -C "$stage" crucible-server README.md LICENSE
    rm -rf "$stage"
    (cd "$OUT" && shasum -a 256 "$name.tar.gz" > "$name.tar.gz.sha256")
    echo "$OUT/$name.tar.gz"
}

macos() {
    mkdir -p "$OUT"
    (cd "$SERVER_DIR" && cargo test --release --quiet)
    local target arch
    for target in aarch64-apple-darwin x86_64-apple-darwin; do
        (cd "$SERVER_DIR" && cargo build --release --locked --target "$target")
        codesign --force --sign - --identifier cc.midgarcorp.crucible-server "$SERVER_DIR/target/$target/release/crucible-server"
        arch=$([[ $target == aarch64-* ]] && echo arm64 || echo x86_64)
        tarball "$SERVER_DIR/target/$target/release/crucible-server" "crucible-server-$VERSION-macos-$arch"
    done
}

linux() {
    mkdir -p "$OUT"
    rsync -az --delete --exclude target "$SERVER_DIR/" "$LINUX_HOST:.cache/crucible-server-src/"
    local arch
    for arch in x86_64 aarch64; do
        ssh "$LINUX_HOST" "cd ~/.cache/crucible-server-src && PATH=\$HOME/.cargo/bin:\$PATH cargo zigbuild --release --locked --target $arch-unknown-linux-musl 2>&1 | tail -1"
        scp -q "$LINUX_HOST:.cache/crucible-server-src/target/$arch-unknown-linux-musl/release/crucible-server" "$OUT/crucible-server-linux-$arch"
        tarball "$OUT/crucible-server-linux-$arch" "crucible-server-$VERSION-linux-$arch"
    done
}

checksum() {
    cut -d' ' -f1 < "$OUT/$1.tar.gz.sha256"
}

packages() {
    local base="https://github.com/$REPO/releases/download/$TAG"
    cat > "$OUT/crucible-server.rb" << EOF
class CrucibleServer < Formula
  desc "Companion to Plex for Crucible: skips, Previously On and answers from a model you choose"
  homepage "https://github.com/$REPO/tree/master/server"
  license "GPL-3.0-only"
  version "$VERSION"

  livecheck do
    url :stable
    regex(/^server-v?(\d+(?:\.\d+)+)$/i)
    strategy :github_releases
  end

  depends_on :macos
  depends_on "ffmpeg"

  on_macos do
    on_arm do
      url "$base/crucible-server-$VERSION-macos-arm64.tar.gz"
      sha256 "$(checksum "crucible-server-$VERSION-macos-arm64")"
    end
    on_intel do
      url "$base/crucible-server-$VERSION-macos-x86_64.tar.gz"
      sha256 "$(checksum "crucible-server-$VERSION-macos-x86_64")"
    end
  end

  def install
    bin.install "crucible-server"
  end

  def caveats
    <<~EOS
      Run \`crucible-server setup\` once, on the Mac that runs Plex.
      It signs you in with Plex, finds a local model, keeps the server running and shows the QR code that pairs Crucible.
      No local model? Use a hosted one with your own key: crucible-server model --url ADDRESS --name NAME --key-file FILE
    EOS
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/crucible-server --version")
  end
end
EOF
    cat > "$OUT/PKGBUILD" << EOF
# Maintainer: guitaripod <marcus@midgarcorp.cc>
pkgname=crucible-server-bin
pkgver=$VERSION
pkgrel=1
pkgdesc="Companion to Plex for Crucible: skips, Previously On and answers from a model you choose"
arch=('x86_64' 'aarch64')
url="https://github.com/$REPO/tree/master/server"
license=('GPL-3.0-only')
depends=('ffmpeg')
provides=('crucible-server')
conflicts=('crucible-server')
source_x86_64=("crucible-server-$VERSION-linux-x86_64.tar.gz::$base/crucible-server-$VERSION-linux-x86_64.tar.gz")
source_aarch64=("crucible-server-$VERSION-linux-aarch64.tar.gz::$base/crucible-server-$VERSION-linux-aarch64.tar.gz")
sha256sums_x86_64=('$(checksum "crucible-server-$VERSION-linux-x86_64")')
sha256sums_aarch64=('$(checksum "crucible-server-$VERSION-linux-aarch64")')

package() {
    install -Dm755 crucible-server "\$pkgdir/usr/bin/crucible-server"
    install -Dm644 README.md "\$pkgdir/usr/share/doc/crucible-server/README.md"
    install -Dm644 LICENSE "\$pkgdir/usr/share/licenses/\$pkgname/LICENSE"
}
EOF
    echo "$OUT/crucible-server.rb"
    echo "$OUT/PKGBUILD"
}

publish() {
    [[ -f "$OUT/PKGBUILD" && -f "$OUT/crucible-server.rb" ]] || { echo "run all first" >&2; exit 1; }
    local assets=("$OUT"/*.tar.gz "$OUT"/*.tar.gz.sha256 "$SERVER_DIR/packaging/install.sh")
    if gh release view "$TAG" --repo "$REPO" > /dev/null 2>&1; then
        gh release upload "$TAG" "${assets[@]}" --repo "$REPO" --clobber
    else
        gh release create "$TAG" "${assets[@]}" --repo "$REPO" --latest=false --title "Crucible Server $VERSION" \
            --notes "The optional companion to Plex for Crucible. Install: curl -fsSL https://raw.githubusercontent.com/$REPO/master/server/packaging/install.sh | sh, brew install guitaripod/tap/crucible-server, or crucible-server-bin on the AUR. Then run crucible-server setup. See server/README.md."
    fi
    local tap
    tap=$(mktemp -d)
    gh repo clone "$TAP_REPO" "$tap" -- --quiet
    cp "$OUT/crucible-server.rb" "$tap/Formula/crucible-server.rb"
    (cd "$tap" && git add Formula/crucible-server.rb && { git diff --cached --quiet || git commit -q -m "crucible-server $VERSION"; } && git push -q)
    rm -rf "$tap"
    scp -q "$OUT/PKGBUILD" "$LINUX_HOST:.cache/crucible-server-PKGBUILD"
    ssh "$LINUX_HOST" "set -e; rm -rf ~/.cache/crucible-server-aur; git clone -q $AUR_URL ~/.cache/crucible-server-aur; cd ~/.cache/crucible-server-aur; \
        cp ~/.cache/crucible-server-PKGBUILD PKGBUILD; makepkg --printsrcinfo > .SRCINFO; git add PKGBUILD .SRCINFO; \
        git diff --cached --quiet || git commit -q -m 'crucible-server-bin $VERSION'; git push -q origin HEAD:master; rm -rf ~/.cache/crucible-server-aur ~/.cache/crucible-server-PKGBUILD"
    echo "published $TAG"
}

case "${1:-}" in
    macos) macos ;;
    linux) linux ;;
    packages) packages ;;
    publish) publish ;;
    all) macos && linux && packages ;;
    *) usage ;;
esac
