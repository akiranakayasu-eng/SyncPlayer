# SyncPlayer sync protocol 1

The wire protocol Mac v0.3.7 speaks, written down so other OSes (Windows, iOS, Linux/Pi) can follow a Mac master. Source of truth is `Sources/SyncPlayer/Protocol.swift`, `Roles.swift`, `ClockSync.swift`, `Transport.swift`; this file mirrors them. Reference implementation for non-Mac: `cross/proto` (Rust).

Rule: all machines in one show must speak the same *protocol number*. Mac app versions must still match each other as before. A change that older machines cannot read bumps the protocol number.

## Transport
- UDP, one JSON object per datagram (UTF-8). Unknown fields are ignored; absent optional fields are omitted (not `null`).
- **Beacon** (port 47800): master → everyone. Sent every 0.2 s to the subnet broadcast address, to 127.0.0.1, and to each `--to` address (unicast, for networks that drop broadcast and for iOS).
- **Clock** (port 47801): follower ⇄ master, unicast. The follower sends pings from any free port to the master's address (the beacon's source address) on 47801; the master replies to the ping's source.
- Times are seconds (f64) on each machine's own monotonic host clock (Mac: `CMClockGetHostTimeClock`). Machines never compare wall clocks except `since`.

## Messages (field `k`)
| k | from | fields |
|---|---|---|
| `b` beacon | master | `s` (schedule), `mid` (master id), `since` (wall-clock time this master took over; newest wins), `file`, `ident`, `name`, `ver` |
| `p` ping | follower | `id` (1, 2, … per master), `t1` (follower send time), `dur` (longest clip, s), `name`, `ver`, `err` (ms), `warn`, `file`, `seat` |
| `q` pong | master | `id`, `t1` (echoed), `t2` (master receive time), `t3` (master send time) |

Schedule `s`: `epoch` (int, bumps on every play/pause/jump), `playing`, `anchorHost` (master host seconds), `anchorMedia` (media seconds at anchorHost), `cycle` (optional common loop length in s).

## Clock sync (follower)
`rtt = (t4 − t1) − (t3 − t2)`, `offset = ((t2 − t1) + (t3 − t4)) / 2` with t4 = follower receive time. Drop samples with rtt < 0 or ≥ 0.5 s. Keep the last 120 samples; offset = mean of the offsets of the 5 shortest-rtt samples. Ready after 8 samples. Ping every 0.1 s until 40 samples, then every 0.5 s. A pong whose `id` is not above the id at the time this master was adopted belongs to an earlier master: drop it.

## Following a master
- Follow the master with the largest `since` (ties: larger `mid`). Switch to a different `mid` only if it is newer, or the current one has been silent for 1 s.
- On switching: reset the clock samples, remember the current ping id as the generation start. Keep playing the old schedule until the new clock is ready, then adopt the beacon's schedule.
- Adopt a new schedule only when it differs from the current one.

## Where the picture is
- Timeline (not wrapped) at local time h: if not playing, `anchorMedia`; else `anchorMedia + max(0, h + offset − anchorHost)`.
- A clip of length L shows: with `cycle` c > 0, `min(timeline mod c, L)` (shorter clips hold the last frame); without, `timeline mod L`.
- Re-schedule (re-seek) when the smoothed error passes 4 ms or a single error passes 40 ms.

## Show file
`.syncshow` JSON, version 3 (see `Show.swift`); movie and mask paths may be relative to the show file (a "Collect Files" folder). Followers only read it.

## Open points (verify on real machines)
- iOS receiving broadcast beacons needs the local-network permission; unicast `--to` is the fallback.
- Windows firewall prompt on first run (UDP in).
