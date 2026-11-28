# Makes the two short test movies test.syncshow uses (needs ffmpeg on PATH).
Set-Location $PSScriptRoot
ffmpeg -hide_banner -loglevel error -y -f lavfi -i testsrc=size=1280x720:rate=30:duration=10 -pix_fmt yuv420p -c:v libx264 -g 30 clipA.mp4
ffmpeg -hide_banner -loglevel error -y -f lavfi -i "color=c=red:size=640x640:rate=25:duration=4,drawbox=x='mod(t*200,640)':y=0:w=40:h=640:c=white:t=fill" -pix_fmt yuv420p -c:v libx264 clipB.mp4
# A movie whose frame spacing varies (VFR): every 5th frame left out.
ffmpeg -hide_banner -loglevel error -y -f lavfi -i testsrc=size=640x360:rate=30:duration=6 -vf "select='mod(n\,5)'" -fps_mode vfr -pix_fmt yuv420p clipV.mp4
