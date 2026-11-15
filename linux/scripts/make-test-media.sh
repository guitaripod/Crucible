#!/bin/bash
set -euo pipefail
out="${1:-/mnt/nvme8tb/dev/crucible-test-media}"
mkdir -p "$out"
cd "$out"
ffmpeg -loglevel error -y -f lavfi -i "color=c=black:s=3840x2160:r=24:d=2,format=yuv420p10le" \
    -vf "geq=lum='if(lt(X,W/3),509,if(lt(X,2*W/3),572,723))':cb=512:cr=512" \
    -c:v libx265 -preset ultrafast \
    -x265-params "log-level=error:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:range=limited:master-display=G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,1):max-cll=1000,400:hdr10=1:lossless=1" \
    -tag:v hvc1 hdr10-patches.mkv
ffmpeg -loglevel error -y -f lavfi -i "testsrc2=s=3840x2160:r=24:d=4,format=yuv420p10le" -c:v libx265 -preset ultrafast \
    -x265-params "log-level=error:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:range=limited:repeat-headers=1" -f hevc bl.hevc
cat > p5.json <<'JSON'
{ "cm_version": "V40", "length": 96, "level6": { "max_display_mastering_luminance": 1000, "min_display_mastering_luminance": 1, "max_content_light_level": 1000, "max_frame_average_light_level": 400 } }
JSON
dovi_tool generate -j p5.json -p 5 -o p5.rpu
dovi_tool inject-rpu -i bl.hevc --rpu-in p5.rpu -o p5.hevc
rm -f bl.hevc p5.rpu p5.json
echo "$out: hdr10-patches.mkv (PQ codes 509, 572, 723 = 100, 203, 1000 cd/m2), p5.hevc (Dolby Vision 5 over testsrc2)"
