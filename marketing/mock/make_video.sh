#!/bin/sh
set -e
cd "$(dirname "$0")"
mkdir -p assets
SOURCE=${1:-assets/backdrop_2001.jpg}
ffmpeg -y -hide_banner -loglevel error \
  -loop 1 -framerate 25 -i "$SOURCE" \
  -f lavfi -i "anullsrc=r=48000:cl=stereo" \
  -vf "scale=2600:-1,zoompan=z='1.0+0.00012*on':x='iw/2-(iw/zoom/2)+on*0.12':y='ih/2-(ih/zoom/2)-on*0.03':d=1:s=1920x1080:fps=25,noise=alls=3:allf=t,format=yuv420p" \
  -map 0:v -map 1:a -t 150 -c:v libx264 -preset veryfast -crf 27 -maxrate 3500k -bufsize 7000k -r 25 -movflags +faststart -c:a aac -b:a 64k -ac 2 -shortest assets/clip.mp4
ls -l assets/clip.mp4
