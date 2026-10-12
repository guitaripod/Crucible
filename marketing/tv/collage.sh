#!/usr/bin/env bash
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${OUT:-$HERE/out}
ICON=${ICON:-$HERE/../../tv/Resources/Assets.xcassets/App Icon & Top Shelf Image.brandassets/App Icon - Large.imagestack}
TAGLINE=${TAGLINE:-Your Plex library, beautifully on Apple TV.}

usage() {
  cat << 'USAGE'
Frame 3840x2160 tvOS screenshots with a slim TV bezel and lay them out as a collage.

Capture the screenshots at 4K from the mock server's fictional library: TV_SIM_TYPE=com.apple.CoreSimulator.SimDeviceType.Apple-TV-4K-3rd-generation-4K
tv/scripts/tv.sh uitest -only HomeTests/testLoadedHomeFollowsFocusAndScrolls exports them to tv/out/ui (wiped by every run).

  marketing/tv/collage.sh shot1.png shot2.png shot3.png shot4.png [...]

Writes marketing/tv/out/collage.png (full size), collage-web.png and collage-web.jpg (4096 px wide; the JPEG stays under
the 5 MB image limit of social posts) under a banner
with the app icon, TITLE (default Crucible) and TAGLINE. COLUMNS=<n> sets the grid width (default 2), TILE_WIDTH
the framed screenshot width in pixels (default 3400). The stock frames pack has no Apple TV, so make-tv-frame.py
writes the bezel into out/frame-assets and frames is pointed there with --assets.
USAGE
}

[[ $# -ge 2 ]] || { usage; exit 2; }

mkdir -p "$OUT/framed"
python3 "$HERE/make-tv-frame.py" "$OUT/frame-assets" > /dev/null
framed=()
for shot in "$@"; do
  frames --assets "$OUT/frame-assets" -o "$OUT/framed" "$shot" > /dev/null
  framed+=("$OUT/framed/$(basename "${shot%.*}")_framed.png")
done
python3 "$HERE/compose-collage.py" --columns "${COLUMNS:-2}" --tile-width "${TILE_WIDTH:-3400}" --icon-dir "$ICON" \
  --title "${TITLE:-Crucible}" --tagline "$TAGLINE" -o "$OUT/collage.png" "${framed[@]}"
