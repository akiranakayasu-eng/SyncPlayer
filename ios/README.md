# SyncFollower (iOS, stage 1)

An iPhone/iPad follower for a Mac SyncPlayer master (protocol 1, `docs/protocol.md`). Plays the bundled `test.mp4` (13 s, counter) in step with the master; shows offset / rtt / error on screen (triple-tap hides it).

- `Shared/` are copies of the Mac files that define the protocol. `./check-shared.sh` must say "shared files match".
- Build: `brew install xcodegen && cd ios && xcodegen && open SyncFollower.xcodeproj`; set a Team (a free Apple ID works, the app expires after 7 days), run on the device.
- Use: start the Mac master with this device's IP as an extra target: `SyncPlayer --master --to <ip shown on the iPad>`. Allow Local Network when asked. Play on the Mac.
- Stage 1 limits: one clip, no warp/seats, simple loop (a hiccup at the loop point), movie is the bundled test only.
