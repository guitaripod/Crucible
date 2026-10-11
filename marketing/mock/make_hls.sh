#!/bin/sh
set -e
cd "$(dirname "$0")"
rm -rf assets/hls
mkdir -p assets/hls
ffmpeg -y -hide_banner -loglevel error -i assets/clip.mp4 \
  -c copy -f hls -hls_time 6 -hls_playlist_type vod -hls_segment_type fmp4 \
  -hls_fmp4_init_filename init.mp4 -hls_segment_filename 'assets/hls/seg%d.m4s' assets/hls/index.m3u8
ls assets/hls | head -5
