#!/bin/bash
# Captures every page of the design gallery offscreen, in its rest, focused, hovered and presented states, and checks each
# capture against its golden thumbnail in linux/Tests/Gallery: Desk in the dark appearance and Couch in the light, at
# 1600x900 and scale 1. Exits non-zero on any mismatch and keeps the captures and red diff images for a look.
#   gallery-check.sh            check
#   gallery-check.sh --update   write new goldens after a deliberate design change, then look at every one before committing
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
export PKG_CONFIG_PATH="$root/linux/.build/mpv/lib/pkgconfig" LD_LIBRARY_PATH="$root/linux/.build/mpv/lib"
if ! log="$(swift build -c release --product crucible-gallery 2>&1)"; then
    echo "$log" >&2
    exit 1
fi
mode=--check
[[ "${1:-}" == --update ]] && mode=--update-golden
out="$(mktemp -d)"
failed=0
for variant in desk-dark couch-light; do
    density="${variant%-*}"
    appearance="${variant#*-}"
    args=(--capture "$out/$variant" --size 1600x900 --scale 1 --density "$density" "$mode" "linux/Tests/Gallery/$variant")
    [[ "$appearance" == light ]] && args+=(--light)
    if ! "$root/.build/release/crucible-gallery" "${args[@]}" | grep '^golden'; then
        failed=1
    fi
done
if [[ $failed -eq 0 ]]; then
    rm -rf "$out"
    echo "gallery: every capture matches its golden"
else
    echo "gallery: mismatches; captures and diffs in $out" >&2
    exit 1
fi
