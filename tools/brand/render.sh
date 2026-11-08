#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
out=../../Sources/CrucibleDesign/Resources
base=72
for scale in 2 3; do
  h=$((base * scale))
  for name in imdb tmdb rottentomatoes-fresh rottentomatoes-rotten metacritic myanimelist seerr letterboxd-dark letterboxd-light; do
    rsvg-convert -h "$h" "sources/$name.svg" -o "$out/brand-$name@${scale}x.png"
  done
  rsvg-convert -h "$h" sources/trakt.svg | magick - -gravity west -crop "${h}x${h}+0+0" +repage "$out/brand-trakt@${scale}x.png"
done
for f in "$out"/brand-*.png; do magick "$f" -strip -define png:compression-level=9 "$f"; done
