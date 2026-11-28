# win-player (SyncPlayer for Windows, stage 1: picture)

Opens a `.syncshow`, shows one seat's first output in one window, and follows a Mac SyncPlayer
master (protocol 1, `docs/protocol.md`). No sound, no warp / crop / mask / edge blend yet (the same
scope as the iOS follower). Layers are drawn in order (the last one in front) with their opacity,
each fitted into the picture with its aspect kept.

## Needs
- `ffmpeg.exe` and `ffprobe.exe` (e.g. `winget install Gyan.FFmpeg`): on PATH, next to
  `win-player.exe`, or in the folder named by `SYNCPLAYER_FFMPEG_DIR`.
- Build: `cargo build --release` (Rust; no C libraries).

## Run
```
win-player <show.syncshow> [--seat B] [--size 1280x720] [--name NAME] [--local]
```
- `--seat`: seat name (default: the first seat). Shows without seats (version 1–2) are seat `A`.
- `--size`: the size the movies are decoded at (default 1280x720); the window scales it.
- `--local`: no master, play from 0 on this PC's clock (to check the picture).
- On the Mac master, add this PC's address with `--to` (unicast), or rely on broadcast.
- Double-click: full screen. Esc: back to a window. I: hide/show the status.
- Log: `follow-log.csv` in the folder it was started from, one line per second
  (`wall,host,offset_ms,rtt_ms,err_ms,max_abs_err_ms,resyncs,loops,epoch,playing,seat,clips`, as iOS).
- Only one follower per PC can listen on UDP 47800: close `follow.exe` first.
- First run: Windows Firewall asks to allow the app; press Allow (private networks). If it was
  cancelled, the Block rule is tied to the exe's path; copying the exe to another folder (e.g.
  `dist\`, ignored by git) asks again.
- `SYNCPLAYER_DEBUG=1` (environment) writes why each clip re-started to `win-player-debug.txt`.
- Without beacons the last schedule is followed for 5 s (beacons can pause over a VPN), then it waits.

## How it follows
- Each clip has its own ffmpeg child process (`-ss` to the wanted frame, raw RGBA on stdout, no `-re`).
  It decodes ahead into a small queue; every frame carries the timeline time at which it is due, and
  the window shows the newest frame whose time has come.
- Loops are laid out by the decoder: the master's `cycle` if set (a shorter clip holds its last frame
  until the next cycle; holding is not counted as an error), else the clip's own length. The next
  ffmpeg (from frame 0) is started while the current one plays, so the seam costs no start-up time.
- `err` is 0 while the frame on screen is the one due now; otherwise how far it is off. A new start
  (re-seek) happens when the smoothed error passes 4 ms or a single error 40 ms (`docs/protocol.md`),
  on every jump / pause, and when the master's `cycle` changes.
- Not measured by the log: the time from "frame chosen" to light on the screen (window compositor,
  display). Check that with a camera against the Mac.

## Test without a Mac
```
powershell -File test\make-test-movies.ps1
cargo run --release --example fake_master 47810
target\release\win-player.exe test\test.syncshow --seat B --beacon-port 47810
```
`fake_master` sends beacons to 127.0.0.1 and walks through play, jump, pause, play, cycle 6 s, no cycle.
