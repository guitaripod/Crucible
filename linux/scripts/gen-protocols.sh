#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
out_c="$root/Sources/CKiln/protocols"
out_h="$root/Sources/CKiln/protocols"
mkdir -p "$out_c" "$out_h"
for xml in "$root"/Protocols/*.xml; do
    name="$(basename "$xml" .xml)"
    wayland-scanner client-header "$xml" "$out_h/$name-client-protocol.h"
    wayland-scanner private-code "$xml" "$out_c/$name-protocol.c"
done
