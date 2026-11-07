#!/bin/sh
set -eu

REPO="guitaripod/Crucible"
BIN_DIR="${CRUCIBLE_SERVER_BIN_DIR:-$HOME/.local/bin}"

fail() {
    echo "crucible-server install: $1" >&2
    exit 1
}

case "$(uname -s)" in
    Linux) os=linux ;;
    Darwin) os=macos ;;
    *) fail "this installer covers Linux and macOS; on Windows use Docker for now" ;;
esac
case "$(uname -m)" in
    x86_64 | amd64) arch=x86_64 ;;
    aarch64 | arm64) arch=$([ "$os" = macos ] && echo arm64 || echo aarch64) ;;
    *) fail "no build for $(uname -m)" ;;
esac

command -v curl > /dev/null || fail "curl is needed"
tag=$(curl -fsSL "https://api.github.com/repos/$REPO/releases?per_page=30" | grep -o '"tag_name": *"server-v[0-9.]*"' | head -1 | sed 's/.*"\(server-v[0-9.]*\)"/\1/')
[ -n "$tag" ] || fail "could not find a Crucible Server release"
version=${tag#server-v}
name="crucible-server-$version-$os-$arch.tar.gz"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

echo "Downloading Crucible Server $version for $os $arch..."
curl -fsSL "https://github.com/$REPO/releases/download/$tag/$name" -o "$work/$name"
curl -fsSL "https://github.com/$REPO/releases/download/$tag/$name.sha256" -o "$work/$name.sha256"
expected=$(cut -d' ' -f1 < "$work/$name.sha256")
if command -v sha256sum > /dev/null; then actual=$(sha256sum "$work/$name" | cut -d' ' -f1); else actual=$(shasum -a 256 "$work/$name" | cut -d' ' -f1); fi
[ "$expected" = "$actual" ] || fail "the download does not match its checksum"
tar -xzf "$work/$name" -C "$work"
mkdir -p "$BIN_DIR"
install -m 0755 "$work/crucible-server" "$BIN_DIR/crucible-server"
echo "Installed $BIN_DIR/crucible-server."
command -v ffmpeg > /dev/null || echo "Install ffmpeg too, so recaps can read subtitles."
case ":$PATH:" in *":$BIN_DIR:"*) ;; *) echo "Add $BIN_DIR to your PATH." ;; esac
if (: < /dev/tty) 2> /dev/null; then
    "$BIN_DIR/crucible-server" setup < /dev/tty
else
    echo "Now run: crucible-server setup"
fi
