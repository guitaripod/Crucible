#!/bin/sh
set -e
cd "$(dirname "$0")"
mkdir -p assets
bokeh() {
  i=$1; cx=$2; cy=$3; r=$4; sx=$5; sy=$6; ph=$7
  echo "exp(-((X-(${cx}+${sx}*sin(T*0.05+${ph})*40+T*${sy}*0.8))*(X-(${cx}+${sx}*sin(T*0.05+${ph})*40+T*${sy}*0.8))+(Y-(${cy}+22*sin(T*0.07+${ph})))*(Y-(${cy}+22*sin(T*0.07+${ph}))))/(${r}*${r}))"
}
B="0.5*$(bokeh 1 80 90 26 1 0.3 0.2)+0.4*$(bokeh 2 220 150 40 -1 0.2 1.3)+0.5*$(bokeh 3 330 70 22 1 -0.2 2.1)+0.35*$(bokeh 4 150 200 34 1 0.25 3.0)+0.45*$(bokeh 5 400 180 28 -1 0.15 4.2)+0.3*$(bokeh 6 270 40 50 1 0.1 5.1)"
WAVE="(0.82+0.10*sin(X/38+Y/21+T*0.5)+0.08*sin(X/17-Y/33+T*0.8))"
ffmpeg -y -hide_banner -loglevel error \
  -f lavfi -i "gradients=s=480x270:r=25:c0=0b2d3a:c1=1f6f78:c2=d9893a:c3=1a1018:nb_colors=4:speed=0.006:x0=0:y0=0:x1=480:y1=270:d=150" \
  -f lavfi -i "anullsrc=r=48000:cl=stereo:d=150" \
  -filter_complex "[0:v]format=gbrp,geq=r='clip(r(X,Y)*${WAVE}+${B}*0.62,0,255)':g='clip(g(X,Y)*${WAVE}+${B}*0.42,0,255)':b='clip(b(X,Y)*${WAVE}+${B}*0.20,0,255)',scale=1920:1080:flags=bicubic,gblur=sigma=2,vignette=PI/4,noise=alls=9:allf=t,format=yuv420p[v]" \
  -map "[v]" -map 1:a -t 150 -c:v libx264 -preset medium -crf 24 -maxrate 2500k -bufsize 5000k -pix_fmt yuv420p -r 25 -movflags +faststart -c:a aac -b:a 64k -ac 2 assets/clip.mp4
ls -l assets/clip.mp4
