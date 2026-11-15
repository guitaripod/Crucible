#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
vendor="$root/Vendor/mpv"
work="${MPV_WORK:-$root/.build/mpv-src}"
prefix="${MPV_PREFIX:-$root/.build/mpv}"
source "$vendor/VERSIONS"
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
CFLAGS="-I$headers" meson setup build --prefix="$prefix" -Dbuildtype=release -Dlibmpv=true -Dcplayer=false \
    -Dlibplacebo:vulkan-registry="$registry" -Dlibplacebo:demos=false > "$work/setup.log"
ninja -C build > "$work/build.log"
rm -rf "$prefix"
ninja -C build install > /dev/null
echo "$prefix/lib/libmpv.so.2 (mpv $MPV_TAG with $(ls "$vendor"/patches/mpv | wc -l) patches, libplacebo ${LIBPLACEBO_COMMIT:0:8})"
