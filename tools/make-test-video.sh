#!/bin/sh
# Frame-numbered test clip: 1280x720, 60 fps, 20 s, every frame a key frame, 1 kHz click each second.
# Usage: [DUR=120] tools/make-test-video.sh [out.mp4]
OUT=${1:-media/sync-test-60fps-20s.mp4}
FONT=${FONT:-/System/Library/Fonts/Supplemental/Arial Bold.ttf}
mkdir -p "$(dirname "$OUT")"
ffmpeg -hide_banner -loglevel error -y \
 -f lavfi -i "color=c=0x202020:s=1280x720:r=60:d=${DUR:-20}" \
 -f lavfi -i "aevalsrc='if(lt(mod(t\,1)\,0.03)\,0.5*sin(2*PI*1000*t)\,0)':s=48000:d=${DUR:-20}" \
 -vf "drawbox=x='mod(t*960\,1280)':y=0:w=16:h=720:c=white:t=fill,drawtext=fontfile='$FONT':text='%{frame_num}':start_number=0:fontsize=260:fontcolor=yellow:x=(w-tw)/2:y=(h-th)/2-60,drawtext=fontfile='$FONT':text='%{pts\:hms}':fontsize=60:fontcolor=white:x=(w-tw)/2:y=h-140" \
 -c:v libx264 -g 1 -crf 23 -pix_fmt yuv420p -c:a aac -b:a 128k -shortest "$OUT"
