#!/bin/bash
# Builds the vendored libmpv and libplacebo (linux/Vendor/mpv: the tags and the patch series) into linux/.build/mpv, and
# stamps the build with the recipe it came from. `--if-stale` builds only when the prefix lacks a build of the current
# recipe, so a new patch reaches every install without anyone deleting the prefix by hand.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
vendor="$root/Vendor/mpv"
work="${MPV_WORK:-$root/.build/mpv-src}"
prefix="${MPV_PREFIX:-$root/.build/mpv}"
source "$vendor/VERSIONS"
recipe="$(cat "$0" "$vendor/VERSIONS" "$vendor"/patches/*/*.patch | sha256sum | cut -c1-16)"
if [ "${1:-}" = "--if-stale" ] && [ -f "$prefix/lib/libmpv.so.2" ] && [ "$(cat "$prefix/.recipe" 2>/dev/null)" = "$recipe" ]; then
    exit 0
fi
identity=(-c user.name=Kiln -c user.email=kiln@localhost)

rm -rf "$work"
mkdir -p "$work"
git clone -q --depth 1 --branch "$MPV_TAG" https://github.com/mpv-player/mpv.git "$work/mpv"
git -C "$work/mpv" "${identity[@]}" am -q "$vendor"/patches/mpv/*.patch

git clone -q https://code.videolan.org/videolan/libplacebo.git "$work/mpv/subprojects/libplacebo"
git -C "$work/mpv/subprojects/libplacebo" checkout -q "$LIBPLACEBO_COMMIT"
git -C "$work/mpv/subprojects/libplacebo" submodule update -q --init --recursive --depth 1
git -C "$work/mpv/subprojects/libplacebo" "${identity[@]}" am -q "$vendor"/patches/libplacebo/*.patch

headers="/usr/include"
registry="/usr/share/vulkan/registry/vk.xml"
if [ ! -f /usr/include/vulkan/vulkan.h ] || [ ! -f "$registry" ]; then
    git clone -q https://github.com/KhronosGroup/Vulkan-Headers.git "$work/vulkan-headers"
    git -C "$work/vulkan-headers" checkout -q "$VULKAN_HEADERS_COMMIT"
    headers="$work/vulkan-headers/include"
    registry="$work/vulkan-headers/registry/vk.xml"
fi

cd "$work/mpv"
CFLAGS="-I$headers" LDFLAGS="-Wl,-rpath,\$ORIGIN" meson setup build --prefix="$prefix" -Dbuildtype=release -Dlibmpv=true -Dcplayer=false -Dsndio=disabled --force-fallback-for=libplacebo \
    -Dlibplacebo:vulkan-registry="$registry" -Dlibplacebo:demos=false -Dlibplacebo:default_library=shared > "$work/setup.log"
ninja -C build > "$work/build.log"
rm -rf "$prefix"
ninja -C build install > /dev/null
if [ "$headers" != "/usr/include" ]; then
    cp -r "$headers/vulkan" "$headers/vk_video" "$prefix/include/"
fi
echo "$recipe" > "$prefix/.recipe"
echo "$prefix/lib/libmpv.so.2 (mpv $MPV_TAG with $(ls "$vendor"/patches/mpv | wc -l) patches, libplacebo ${LIBPLACEBO_COMMIT:0:8})"
