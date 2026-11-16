#!/bin/bash
# Builds AccessKit's C API with its Unix adapter (AT-SPI, for Orca) from the tag in linux/Vendor/accesskit into the vendored
# prefix next to libmpv: lib/libaccesskit.a, include/accesskit.h and lib/pkgconfig/accesskit.pc.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
source "$root/Vendor/accesskit/VERSIONS"
work="${ACCESSKIT_WORK:-$root/.build/accesskit-src}"
prefix="${MPV_PREFIX:-$root/.build/mpv}"

rm -rf "$work"
git -c advice.detachedHead=false clone -q --depth 1 --branch "$ACCESSKIT_C_TAG" https://github.com/AccessKit/accesskit-c.git "$work"
commit="$(git -C "$work" rev-parse HEAD)"
if [ "$commit" != "$ACCESSKIT_C_COMMIT" ]; then
    echo "build-accesskit: tag $ACCESSKIT_C_TAG is $commit, not the pinned $ACCESSKIT_C_COMMIT" >&2
    exit 1
fi
CARGO_PROFILE_RELEASE_DEBUG=0 cargo build -q --manifest-path "$work/Cargo.toml" --release --locked --lib

install -Dm644 "$work/target/release/libaccesskit.a" "$prefix/lib/libaccesskit.a"
install -Dm644 "$work/include/accesskit.h" "$prefix/include/accesskit.h"
install -dm755 "$prefix/lib/pkgconfig"
cat > "$prefix/lib/pkgconfig/accesskit.pc" <<PC
prefix=$prefix
Name: accesskit
Description: AccessKit's C API with its Unix (AT-SPI) adapter
Version: $ACCESSKIT_C_TAG
Libs: -L\${prefix}/lib -l:libaccesskit.a -lgcc_s -lutil -lrt -lpthread -lm -ldl
Cflags: -I\${prefix}/include
PC
rm -rf "$work"
