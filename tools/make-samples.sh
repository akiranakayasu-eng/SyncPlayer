#!/bin/bash
# Makes 10 sample movies with sound (1280x720, 30 fps, 20 s, H.264 + AAC) for practising sync.
# Each one shows a clear picture event at the same moment as a clear sound, plus the time and
# frame number, so you can see and hear whether several Macs play in step.
# Usage: tools/make-samples.sh [output folder]   (needs ffmpeg with drawtext)
set -euo pipefail
OUT="${1:-samples}"
mkdir -p "$OUT"
FONT="${FONT:-$(fc-match -f '%{file}' 'DejaVu Sans:bold' 2>/dev/null || echo /System/Library/Fonts/Helvetica.ttc)}"
W=1280; H=720; R=30; D=20
PI=3.14159265

label() { # $1 = title
  echo "drawtext=fontfile=$FONT:text='$1':x=30:y=24:fontsize=34:fontcolor=white:box=1:boxcolor=black@0.45:boxborderw=10,\
drawtext=fontfile=$FONT:text='%{pts\:hms}   frame %{n}':x=(w-tw)/2:y=h-60:fontsize=32:fontcolor=white:box=1:boxcolor=black@0.45:boxborderw=8"
}

make() { # $1 = file name, $2 = video source + filters, $3 = audio expression (left|right or one for both)
  local name="$1" vf="$2" af="$3"
  local ach="$af|$af"; [[ "$af" == *"|"* ]] && ach="$af"
  ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "$vf" \
    -f lavfi -i "aevalsrc=exprs=$ach:s=48000:d=$D" \
    -t $D -c:v libx264 -pix_fmt yuv420p -preset medium -crf 20 -g $R -r $R \
    -c:a aac -b:a 160k -movflags +faststart "$OUT/$name"
  echo "made $OUT/$name"
}

BG="color=s=${W}x${H}:r=$R:d=$D"

# 1. Countdown: the number changes and the screen flashes with a beep every second (high beep every 5 s).
make "sample01_countdown.mp4" \
  "$BG:c=0x1d3557,drawbox=x=0:y=0:w=iw:h=ih:color=white@0.85:t=fill:enable='lt(mod(t\,1)\,0.1)',drawtext=fontfile=$FONT:text='%{eif\:$D-floor(t)\:d}':x=(w-tw)/2:y=(h-th)/2-20:fontsize=320:fontcolor=white,$(label 'SAMPLE 01  COUNTDOWN')" \
  "0.3*sin(2*$PI*if(lt(mod(t\,5)\,0.1)\,1760\,880)*t)*lt(mod(t\,1)\,0.1)"

# 2. Bouncing ball: it hits the floor and clicks on every whole second.
make "sample02_ball.mp4" \
  "$BG:c=0x2a9d8f,drawbox=x=0:y=ih-90:w=iw:h=6:color=white:t=fill,drawbox=x=(iw-80)/2:y=ih-170-abs(sin($PI*t))*420:w=80:h=80:color=0xffd166:t=fill,$(label 'SAMPLE 02  BALL')" \
  "0.6*exp(-60*mod(t\,1))*sin(2*$PI*1200*t)"

# 3. Sweep: a bar crosses the screen in 4 s while the tone rises from 200 to 800 Hz.
make "sample03_sweep.mp4" \
  "$BG:c=0x264653,drawbox=x=mod(t\,4)/4*iw:y=0:w=24:h=ih:color=0xe9c46a:t=fill,$(label 'SAMPLE 03  SWEEP')" \
  "0.25*sin(2*$PI*(200*mod(t\,4)+75*mod(t\,4)*mod(t\,4)))"

# 4. Clapper: a white flash and a short noise burst every 2 s (like a slate).
make "sample04_clap.mp4" \
  "$BG:c=0x111111,drawbox=x=0:y=0:w=iw:h=ih:color=white:t=fill:enable='lt(mod(t\,2)\,0.067)',drawtext=fontfile=$FONT:text='CLAP':x=(w-tw)/2:y=(h-th)/2:fontsize=200:fontcolor=0xe63946:enable='lt(mod(t\,2)\,0.3)',$(label 'SAMPLE 04  CLAP')" \
  "0.6*(random(0)*2-1)*lt(mod(t\,2)\,0.03)"

# 5. Pattern: a growing pattern scrolls up with a slow chord (calm, for looking at the picture).
make "sample05_pattern.mp4" \
  "cellauto=s=320x180:r=$R:rule=30:scroll=1:full=1:pattern=1,scale=${W}:${H}:flags=neighbor,lutrgb=r=val*0.95:g=val*0.65+30:b=val*0.35+60,$(label 'SAMPLE 05  PATTERN')" \
  "(0.12*sin(2*$PI*110*t)+0.1*sin(2*$PI*165*t)+0.08*sin(2*$PI*220*t))*(0.7+0.3*sin(2*$PI*0.25*t))"

# 6. Life: cells change 10 times a second, a soft tick with each change.
make "sample06_life.mp4" \
  "life=s=320x180:r=10:ratio=0.2:mold=10:life_color=0x8ecae6:death_color=0x023047:seed=7,scale=${W}:${H}:flags=neighbor,fps=$R,$(label 'SAMPLE 06  LIFE')" \
  "0.15*exp(-80*mod(t\,0.1))*sin(2*$PI*2000*t)"

# 7. Gradient: moving colours and a chord that changes every 5 s.
make "sample07_gradient.mp4" \
  "gradients=s=${W}x${H}:r=$R:d=$D:speed=0.02:seed=3,$(label 'SAMPLE 07  GRADIENT')" \
  "0.1*(sin(2*$PI*if(lt(mod(t\,10)\,5)\,220\,196)*t)+sin(2*$PI*if(lt(mod(t\,10)\,5)\,277\,247)*t)+sin(2*$PI*if(lt(mod(t\,10)\,5)\,330\,294)*t))"

# 8. Scale: 8 bars light up in turn, each with its note (do re mi ... do), every 0.5 s.
BARS=""
for i in 0 1 2 3 4 5 6 7; do
  BARS+="drawbox=x=80+$i*140:y=200:w=110:h=320:color=0xf4a261:t=fill:enable='eq(floor(mod(t\,4)/0.5)\,$i)',drawbox=x=80+$i*140:y=200:w=110:h=320:color=white@0.5:t=3,"
done
make "sample08_scale.mp4" \
  "$BG:c=0x3d405b,${BARS}$(label 'SAMPLE 08  SCALE')" \
  "0.3*exp(-4*mod(t\,0.5))*sin(2*$PI*261.63*pow(2\,(2*floor(mod(t\,4)/0.5)-gte(floor(mod(t\,4)/0.5)\,3)-gte(floor(mod(t\,4)/0.5)\,7))/12)*t)"

# 9. Left / right: the left half flashes with a beep in the left speaker, then the right half with the right speaker.
make "sample09_left_right.mp4" \
  "$BG:c=0x22223b,drawbox=x=0:y=0:w=iw/2:h=ih:color=0x4cc9f0:t=fill:enable='lt(mod(t\,2)\,0.2)',drawbox=x=iw/2:y=0:w=iw/2:h=ih:color=0xf72585:t=fill:enable='between(mod(t\,2)\,1\,1.2)',drawtext=fontfile=$FONT:text='L':x=w/4-tw/2:y=(h-th)/2:fontsize=220:fontcolor=white,drawtext=fontfile=$FONT:text='R':x=3*w/4-tw/2:y=(h-th)/2:fontsize=220:fontcolor=white,$(label 'SAMPLE 09  LEFT RIGHT')" \
  "0.3*sin(2*$PI*660*t)*lt(mod(t\,2)\,0.2)|0.3*sin(2*$PI*660*t)*between(mod(t\,2)\,1\,1.2)"

# 10. Test pattern with a big time code and a 1 kHz pip at each second (for checking with a camera).
make "sample10_testpattern.mp4" \
  "testsrc2=s=${W}x${H}:r=$R:d=$D,drawbox=x=0:y=0:w=iw:h=ih:color=white@0.7:t=fill:enable='lt(mod(t\,1)\,0.034)',drawtext=fontfile=$FONT:text='%{pts\:hms}':x=(w-tw)/2:y=(h-th)/2:fontsize=120:fontcolor=white:box=1:boxcolor=black@0.6:boxborderw=16,$(label 'SAMPLE 10  TEST PATTERN')" \
  "0.3*sin(2*$PI*1000*t)*lt(mod(t\,1)\,0.04)"
