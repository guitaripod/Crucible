#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
RAW=${RAW:-$ROOT/marketing/shots/out/raw-dark}
RAW_LIGHT=${RAW_LIGHT:-$ROOT/marketing/shots/out/raw-light}
OUT=${OUT:-$ROOT/marketing/shots/out/framed}
COLOR=${COLOR:-Silver}
GALLERY=(01-home 02-library 03-detail 04b-show-episodes 05-search 06-downloads 07-stats 07c-share-preview 11c-libraries 09-player)
BANNER=(01-home 02-library 03-detail 04b-show-episodes 06-downloads)

rm -rf "$OUT"
mkdir -p "$OUT/gallery" "$OUT/banner"

for name in "${GALLERY[@]}"; do
  frames -c "$COLOR" -o "$OUT/gallery" "$RAW/$name.png" > /dev/null
done

frames -c "$COLOR" -o "$OUT/gallery" "$RAW_LIGHT/08-you.png" > /dev/null
mv "$OUT/gallery/08-you_framed.png" "$OUT/gallery/08-you-light_framed.png"

frames -m -c "$COLOR" -o "$OUT/banner" $(for name in "${BANNER[@]}"; do printf '%s ' "$RAW/$name.png"; done) > /dev/null

python3 - "$OUT" <<'PY'
import sys
from PIL import Image
out = sys.argv[1]
banner = Image.open(f"{out}/banner/merged_framed.png")
width = 3000
height = round(banner.height * width / banner.width)
banner.resize((width, height), Image.LANCZOS).save(f"{out}/screenshots.png", optimize=True)
print("screenshots.png", width, height)
PY
ls -la "$OUT" "$OUT/gallery"
