#!/usr/bin/env python3
"""SyncBox: the Linux (Raspberry Pi) player for SyncPlayer shows.

Plays one movie full screen with mpv and keeps it on the same timeline as the SyncPlayer Macs on
the LAN. It speaks the same UDP messages as the Mac app (Sources/SyncPlayer/Protocol.swift and
Roles.swift), so boxes and Macs can be mixed in one show: a box can follow a Mac master, a Mac
can follow a box master, and boxes alone work too.

Only the Python standard library is used. mpv is driven over its JSON IPC socket.

Stage 1: one movie, full screen, loop, follower or master, autostart (systemd).
"""

from __future__ import annotations

import argparse
import json
import math
import os
import selectors
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from dataclasses import dataclass, field
from typing import Callable, Optional

VERSION = "0.1.0"

BEACON_PORT = 47800   # master -> everyone (broadcast)
CLOCK_PORT = 47801    # follower <-> master (unicast)
MIN_LOOP = 0.5        # Show.minLoop on the Mac


def host_now() -> float:
    """Seconds on this box's monotonic clock (the Mac uses its host clock; only offsets cross)."""
    return time.monotonic()


def log(*parts) -> None:
    print(time.strftime("%H:%M:%S"), *parts, flush=True)


# ---------------------------------------------------------------- messages (Protocol.swift)

@dataclass
class Schedule:
    epoch: int
    playing: bool
    anchorHost: float
    anchorMedia: float
    cycle: Optional[float] = None

    def to_json(self) -> dict:
        d = {"epoch": int(self.epoch), "playing": bool(self.playing),
             "anchorHost": float(self.anchorHost), "anchorMedia": float(self.anchorMedia)}
        if self.cycle is not None:
            d["cycle"] = float(self.cycle)
        return d

    @staticmethod
    def from_json(d: dict) -> Optional["Schedule"]:
        try:
            c = d.get("cycle")
            return Schedule(int(d["epoch"]), bool(d["playing"]), float(d["anchorHost"]),
                            float(d["anchorMedia"]), float(c) if c is not None else None)
        except (KeyError, TypeError, ValueError):
            return None


def encode(msg: dict) -> bytes:
    """Like Swift's JSONEncoder for an optional-field struct: nil fields are left out."""
    return json.dumps({k: v for k, v in msg.items() if v is not None},
                      separators=(",", ":")).encode()


def decode(data: bytes) -> Optional[dict]:
    try:
        m = json.loads(data.decode())
    except (UnicodeDecodeError, ValueError):
        return None
    if not isinstance(m, dict) or not isinstance(m.get("k"), str):
        return None
    return m


def finite(x) -> bool:
    return isinstance(x, (int, float)) and not isinstance(x, bool) and math.isfinite(x)


# ---------------------------------------------------------------- clock (ClockSync.swift)

class ClockSync:
    """NTP-style estimate of offset = master clock - local clock.

    Keeps about a minute of samples and averages the offsets of the 5 shortest round trips.
    """

    def __init__(self) -> None:
        self.samples: list[tuple[float, float]] = []   # (rtt, offset)
        self.offset = 0.0
        self.rtt = 0.0

    @property
    def count(self) -> int:
        return len(self.samples)

    @property
    def ready(self) -> bool:
        return len(self.samples) >= 8

    def reset(self) -> None:
        self.samples.clear()
        self.offset = 0.0
        self.rtt = 0.0

    def add(self, t1: float, t2: float, t3: float, t4: float) -> None:
        rtt = (t4 - t1) - (t3 - t2)
        off = ((t2 - t1) + (t3 - t4)) / 2
        if not (0 <= rtt < 0.5):
            return
        self.samples.append((rtt, off))
        if len(self.samples) > 120:
            del self.samples[: len(self.samples) - 120]
        best = sorted(self.samples)[:5]
        self.offset = sum(o for _, o in best) / len(best)
        self.rtt = best[0][0]


# ---------------------------------------------------------------- UDP

def udp_socket(port: int, reuse: bool = False, broadcast: bool = False) -> socket.socket:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    if reuse:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        if hasattr(socket, "SO_REUSEPORT"):
            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
    if broadcast:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    s.bind(("0.0.0.0", port))
    s.setblocking(False)
    return s


def send(sock: socket.socket, data: bytes, addr) -> None:
    """Never blocks: a datagram that cannot go out at once is dropped (as on the Mac)."""
    try:
        sock.sendto(data, addr)
    except OSError:
        pass


class Reader(threading.Thread):
    """Reads several UDP sockets and calls each one's handler with (data, addr, receive time)."""

    def __init__(self) -> None:
        super().__init__(daemon=True, name="udp-reader")
        self.sel = selectors.DefaultSelector()
        self.lock = threading.Lock()
        self.running = True

    def add(self, sock: socket.socket, handler: Callable[[bytes, tuple, float], None]) -> None:
        with self.lock:
            self.sel.register(sock, selectors.EVENT_READ, handler)

    def remove(self, sock: socket.socket) -> None:
        with self.lock:
            try:
                self.sel.unregister(sock)
            except (KeyError, ValueError):
                pass

    def run(self) -> None:
        while self.running:
            with self.lock:
                if not self.sel.get_map():
                    events = []
                else:
                    events = None
            if events is not None:
                time.sleep(0.05)
                continue
            for key, _ in self.sel.select(timeout=0.1):
                sock = key.fileobj
                while True:
                    try:
                        data, addr = sock.recvfrom(2048)
                    except (BlockingIOError, InterruptedError):
                        break
                    except OSError:
                        break
                    t = host_now()
                    try:
                        key.data(data, addr, t)
                    except Exception as e:   # one bad datagram never stops the reader
                        log("handler error:", e)


# ---------------------------------------------------------------- timeline (Transport / SyncNode)

class Timeline:
    """The schedule plus the clock offset, and what the movie should show at a local time."""

    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.schedule: Optional[Schedule] = None
        self.offset: Optional[float] = None    # master clock - local clock
        self.duration = 0.0                    # this box's movie length

    def set(self, schedule: Optional[Schedule], offset: Optional[float]) -> None:
        with self.lock:
            self.schedule = schedule
            self.offset = offset

    def snapshot(self):
        with self.lock:
            return self.schedule, self.offset, self.duration

    def period(self, s: Optional[Schedule], duration: float) -> float:
        if s is not None and s.cycle is not None and s.cycle > 0:
            return s.cycle
        return duration

    def timeline_at(self, h: float) -> Optional[float]:
        """Timeline position (not wrapped) at local time h."""
        s, off, _ = self.snapshot()
        if s is None or off is None:
            return None
        if not s.playing:
            return s.anchorMedia
        return s.anchorMedia + max(0.0, h + off - s.anchorHost)

    def loop_position(self, h: float) -> Optional[float]:
        """Position in the current loop at local time h (may be past the movie's end: holding)."""
        s, off, dur = self.snapshot()
        if s is None or off is None:
            return None
        t = s.anchorMedia if not s.playing else s.anchorMedia + max(0.0, h + off - s.anchorHost)
        p = self.period(s, dur)
        if p <= 0:
            return t
        r = math.fmod(t, p)
        return r + p if r < 0 else r


# ---------------------------------------------------------------- roles (Roles.swift)

class Master:
    """Owns the schedule, answers clock pings, announces the schedule every 0.2 s."""

    FORGET_AFTER = 300.0

    def __init__(self, reader: Reader, timeline: Timeline, *, name: str, file_label: str,
                 broadcast: str, extra_targets: list[str], since: float,
                 together: bool = True, fixed_loop: float = 0.0,
                 initial: Optional[Schedule] = None,
                 on_demote: Optional[Callable[[], None]] = None) -> None:
        self.reader = reader
        self.timeline = timeline
        self.id = str(uuid.uuid4()).upper()
        self.name = name
        self.file_label = file_label
        self.since = since
        self.together = together
        self.fixed_loop = fixed_loop
        self.on_demote = on_demote
        self.lock = threading.Lock()
        self.reported: dict[str, tuple[float, float]] = {}   # follower -> (longest clip, heard at)
        self.inherited: Optional[tuple[float, float]] = None
        self.sock = udp_socket(CLOCK_PORT, broadcast=True)
        try:
            self.listen = udp_socket(BEACON_PORT, reuse=True)
        except OSError:
            self.sock.close()
            raise
        self.targets = [(broadcast, BEACON_PORT), ("127.0.0.1", BEACON_PORT)]
        self.targets += [(t, BEACON_PORT) for t in extra_targets]
        if initial is not None:
            self.schedule = initial
            if initial.cycle:
                self.inherited = (initial.cycle, host_now() + self.FORGET_AFTER)
        else:
            self.schedule = Schedule(int(time.time()), False, host_now(), 0.0)
        timeline.set(self.schedule, 0.0)
        reader.add(self.sock, self._on_clock)
        reader.add(self.listen, self._on_beacon)
        self.running = True
        self.thread = threading.Thread(target=self._loop, daemon=True, name="master")
        self.thread.start()

    def stop(self) -> None:
        self.running = False
        self.reader.remove(self.sock)
        self.reader.remove(self.listen)
        self.sock.close()
        self.listen.close()

    def _on_clock(self, data: bytes, addr, t2: float) -> None:
        m = decode(data)
        if m is None or m.get("k") != "p":
            return
        d = m.get("dur")
        if finite(d) and 0 < d < 86_400:
            with self.lock:
                self.reported[f"{addr[0]}:{addr[1]}"] = (float(d), t2)
        reply = {"k": "q", "id": m.get("id"), "t1": m.get("t1"), "t2": t2, "t3": host_now()}
        send(self.sock, encode(reply), addr)

    def _on_beacon(self, data: bytes, addr, _t: float) -> None:
        m = decode(data)
        if m is None or m.get("k") != "b":
            return
        mid, since = m.get("mid"), m.get("since")
        if not isinstance(mid, str) or mid == self.id or not finite(since):
            return
        if since > self.since or (since == self.since and mid > self.id):
            log("a newer master is on the network:", m.get("name") or addr[0])
            if self.on_demote:
                self.on_demote()

    def _loop(self) -> None:
        while self.running:
            self._update_cycle()
            self.announce()
            time.sleep(0.2)

    def announce(self) -> None:
        with self.lock:
            s = self.schedule
        msg = {"k": "b", "s": s.to_json(), "mid": self.id, "since": self.since,
               "file": self.file_label, "name": self.name or None}
        data = encode(msg)
        for t in self.targets:
            send(self.sock, data, t)

    def _set(self, s: Schedule) -> None:
        with self.lock:
            self.schedule = s
        self.timeline.set(s, 0.0)
        self.announce()

    def _update_cycle(self) -> None:
        want: Optional[float] = None
        _, _, own = self.timeline.snapshot()
        if self.together:
            if self.fixed_loop > 0:
                want = max(self.fixed_loop, MIN_LOOP)
            else:
                now = host_now()
                with self.lock:
                    self.reported = {k: v for k, v in self.reported.items()
                                     if now - v[1] < self.FORGET_AFTER}
                    longest = max([v[0] for v in self.reported.values()], default=0.0)
                longest = max(longest, own)
                if self.inherited is not None:
                    if now < self.inherited[1]:
                        longest = max(longest, self.inherited[0])
                    else:
                        self.inherited = None
                want = longest if longest > 0 else None
        with self.lock:
            cur = self.schedule
        if abs((cur.cycle or 0) - (want or 0)) <= 0.0005:
            return
        at = host_now() + (0.3 if cur.playing else 0.0)
        t = self.timeline.timeline_at(at) or 0.0
        old = cur.cycle if cur.cycle else own
        if old > 0:
            t = math.fmod(t, old)
        if want:
            t = math.fmod(t, want)
        self._set(Schedule(cur.epoch + 1, cur.playing, at, max(0.0, t), want))

    def position(self) -> float:
        return self.timeline.timeline_at(host_now()) or 0.0

    def play(self) -> None:
        with self.lock:
            cur = self.schedule
        if cur.playing:
            return
        self._set(Schedule(cur.epoch + 1, True, host_now() + 0.3, self.position(), cur.cycle))

    def pause(self) -> None:
        with self.lock:
            cur = self.schedule
        if not cur.playing:
            return
        self._set(Schedule(cur.epoch + 1, False, host_now(), self.position(), cur.cycle))

    def toggle(self) -> None:
        with self.lock:
            playing = self.schedule.playing
        self.pause() if playing else self.play()

    def jump(self, media: float) -> None:
        with self.lock:
            cur = self.schedule
        _, _, own = self.timeline.snapshot()
        d = cur.cycle if cur.cycle else own
        t = max(0.0, media)
        if d > 0:
            t = math.fmod(t, d)
        self._set(Schedule(cur.epoch + 1, cur.playing, host_now() + 0.3, t, cur.cycle))


class Follower:
    """Listens for the master's beacon, measures the clock, takes on the schedule."""

    def __init__(self, reader: Reader, timeline: Timeline, *, file_label: str,
                 provisional_offset: Optional[float] = None) -> None:
        self.reader = reader
        self.timeline = timeline
        self.file_label = file_label
        self.clock = ClockSync()
        self.lock = threading.Lock()
        self.master_addr: Optional[tuple] = None
        self.master_id: Optional[str] = None
        self.master_since = 0.0
        self.master_name: Optional[str] = None
        self.master_file: Optional[str] = None
        self.highest_since = 0.0
        self.last_beacon = 0.0
        self.ping_id = 0
        self.generation_start = 0
        self.adopted = False
        self.provisional = provisional_offset
        self.pending: Optional[Schedule] = None
        self.warned_file: Optional[str] = None
        self.beacon_sock = udp_socket(BEACON_PORT, reuse=True)
        self.clock_sock = udp_socket(0)
        reader.add(self.beacon_sock, self._on_beacon)
        reader.add(self.clock_sock, self._on_pong)
        self.running = True
        self.thread = threading.Thread(target=self._loop, daemon=True, name="follower")
        self.thread.start()

    def stop(self) -> None:
        self.running = False
        self.reader.remove(self.beacon_sock)
        self.reader.remove(self.clock_sock)
        self.beacon_sock.close()
        self.clock_sock.close()

    def offset(self) -> Optional[float]:
        with self.lock:
            if not self.adopted:
                return self.provisional
            return self.clock.offset if self.clock.ready else None

    def _on_beacon(self, data: bytes, addr, now: float) -> None:
        m = decode(data)
        if m is None or m.get("k") != "b" or not isinstance(m.get("s"), dict):
            return
        s = Schedule.from_json(m["s"])
        if s is None:
            return
        mid = m.get("mid") if isinstance(m.get("mid"), str) else addr[0]
        since = float(m["since"]) if finite(m.get("since")) else 0.0
        with self.lock:
            self.highest_since = max(self.highest_since, since)
            if mid != self.master_id:
                newer = since > self.master_since
                silent = now - self.last_beacon > 1.0
                if not (self.master_id is None or newer or silent):
                    return
                cur_s, cur_off, _ = self.timeline.snapshot()
                self.provisional = cur_off if cur_s is not None else None
                self.adopted = False
                self.master_id = mid
                self.master_since = since
                self.clock.reset()
                self.generation_start = self.ping_id
                log("following master", m.get("name") or addr[0])
            self.last_beacon = now
            self.master_addr = (addr[0], CLOCK_PORT)
            self.master_name = m.get("name") if isinstance(m.get("name"), str) else None
            self.master_file = m.get("file") if isinstance(m.get("file"), str) else None
            if not self.adopted and self.clock.ready:
                self.adopted = True
                self.provisional = None
            offset = self.clock.offset if self.adopted else self.provisional
            adopted = self.adopted
        if adopted:
            self.timeline.set(s, offset)
        if self.master_file and self.file_label and self.master_file != self.file_label \
                and self.warned_file != self.master_file:
            self.warned_file = self.master_file
            log(f"note: the master plays '{self.master_file}', this box plays '{self.file_label}'")

    def _on_pong(self, data: bytes, _addr, t4: float) -> None:
        m = decode(data)
        if m is None or m.get("k") != "q":
            return
        pid, t1, t2, t3 = m.get("id"), m.get("t1"), m.get("t2"), m.get("t3")
        if not (isinstance(pid, int) and finite(t1) and finite(t2) and finite(t3)):
            return
        with self.lock:
            if pid <= self.generation_start:   # a late answer from the previous master
                return
            self.clock.add(t1, t2, t3, t4)
            if self.adopted:
                s, _, _ = self.timeline.snapshot()
                self.timeline.set(s, self.clock.offset)

    def _loop(self) -> None:
        tick = 0
        while self.running:
            time.sleep(0.1)
            tick += 1
            with self.lock:
                addr = self.master_addr
                if addr is None:
                    continue
                if self.clock.count >= 40 and tick % 5 != 0:
                    continue
                self.ping_id += 1
                pid = self.ping_id
            _, _, dur = self.timeline.snapshot()
            msg = {"k": "p", "id": pid, "dur": dur if dur > 0 else None, "t1": host_now()}
            send(self.clock_sock, encode(msg), addr)

    @property
    def master_alive(self) -> bool:
        with self.lock:
            return self.master_id is not None and host_now() - self.last_beacon < 1.0

    def local_schedule(self) -> Optional[Schedule]:
        """The master's schedule in this box's clock (to take over as master)."""
        s, off, _ = self.timeline.snapshot()
        if s is None or off is None:
            return None
        return Schedule(s.epoch, s.playing, s.anchorHost - off, s.anchorMedia, s.cycle)

    def stats(self):
        with self.lock:
            return self.clock.offset, self.clock.rtt, self.clock.ready


# ---------------------------------------------------------------- mpv

class Mpv:
    """mpv driven over its JSON IPC socket."""

    def __init__(self, movie: str, *, mpv_args: list[str], audio: bool, loop_file: bool,
                 binary: str = "mpv") -> None:
        self.dir = tempfile.mkdtemp(prefix="syncbox-")
        self.path = os.path.join(self.dir, "mpv.sock")
        args = [binary, "--idle=no", "--pause", "--keep-open=always",
                f"--loop-file={'inf' if loop_file else 'no'}",
                "--fullscreen", "--no-osc", "--osd-level=0", "--no-input-default-bindings",
                "--input-vo-keyboard=no", "--cursor-autohide=always", "--really-quiet",
                "--hr-seek=yes", "--cache=yes", "--demuxer-max-bytes=512MiB",
                f"--input-ipc-server={self.path}"]
        if not audio:
            args.append("--no-audio")
        args += mpv_args
        args.append(movie)
        self.proc = subprocess.Popen(args)
        self.sock = self._connect()
        self.lock = threading.Lock()
        self.next_id = 0
        self.waiting: dict[int, list] = {}
        self.buf = b""
        self.alive = True
        threading.Thread(target=self._read, daemon=True, name="mpv-ipc").start()

    def _connect(self) -> socket.socket:
        deadline = time.monotonic() + 15
        while True:
            if self.proc.poll() is not None:
                raise RuntimeError(f"mpv exited with {self.proc.returncode}")
            try:
                s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                s.connect(self.path)
                return s
            except OSError:
                if time.monotonic() > deadline:
                    raise RuntimeError("mpv did not open its IPC socket")
                time.sleep(0.05)

    def _read(self) -> None:
        while True:
            try:
                chunk = self.sock.recv(65536)
            except OSError:
                chunk = b""
            if not chunk:
                self.alive = False
                with self.lock:
                    for w in self.waiting.values():
                        w[1] = {"error": "closed"}
                        w[0].set()
                return
            self.buf += chunk
            while b"\n" in self.buf:
                line, self.buf = self.buf.split(b"\n", 1)
                try:
                    m = json.loads(line)
                except ValueError:
                    continue
                rid = m.get("request_id")
                if rid is None:
                    continue
                with self.lock:
                    w = self.waiting.pop(rid, None)
                if w:
                    w[1] = m
                    w[0].set()

    def command(self, *cmd, timeout: float = 2.0):
        with self.lock:
            self.next_id += 1
            rid = self.next_id
            w = [threading.Event(), None]
            self.waiting[rid] = w
        data = json.dumps({"command": list(cmd), "request_id": rid}).encode() + b"\n"
        try:
            self.sock.sendall(data)
        except OSError:
            with self.lock:
                self.waiting.pop(rid, None)
            return None
        if not w[0].wait(timeout):
            with self.lock:
                self.waiting.pop(rid, None)
            return None
        m = w[1] or {}
        return m.get("data") if m.get("error") == "success" else None

    def get(self, prop: str):
        return self.command("get_property", prop)

    def set(self, prop: str, value) -> None:
        self.command("set_property", prop, value)

    def close(self) -> None:
        try:
            self.command("quit", timeout=1.0)
        except Exception:
            pass
        try:
            self.proc.wait(3)
        except subprocess.TimeoutExpired:
            self.proc.kill()
        try:
            self.sock.close()
        except OSError:
            pass


class PlayerAPI:
    """What the controller needs from a player (mpv, or a simulated one in the tests)."""

    def position(self) -> Optional[float]: ...
    def paused(self) -> bool: ...
    def set_paused(self, p: bool) -> None: ...
    def seek(self, t: float) -> None: ...
    def set_speed(self, s: float) -> None: ...
    def duration(self) -> float: ...
    def frame_interval(self) -> float: ...


class MpvPlayer(PlayerAPI):
    def __init__(self, mpv: Mpv) -> None:
        self.mpv = mpv
        self._paused = True
        self._speed = 1.0
        self._fi = 0.0

    def position(self):
        v = self.mpv.get("time-pos")
        return float(v) if finite(v) else None

    def paused(self) -> bool:
        return self._paused

    def set_paused(self, p: bool) -> None:
        self.mpv.set("pause", bool(p))
        self._paused = bool(p)

    def seek(self, t: float) -> None:
        self.mpv.command("seek", max(0.0, t), "absolute+exact")

    def set_speed(self, s: float) -> None:
        if abs(s - self._speed) > 1e-6:
            self.mpv.set("speed", s)
            self._speed = s

    def duration(self) -> float:
        v = self.mpv.get("duration")
        return float(v) if finite(v) else 0.0

    def frame_interval(self) -> float:
        if self._fi <= 0:
            v = self.mpv.get("container-fps")
            self._fi = 1.0 / float(v) if finite(v) and v > 0 else 0.0
        return self._fi


# ---------------------------------------------------------------- controller

@dataclass
class ControlStats:
    error: float = 0.0    # last reading (jumps by up to a frame: mpv reports whole frames)
    mean: float = 0.0     # smoothed error, what the speed is corrected by
    speed: float = 1.0
    restarts: int = 0
    holding: bool = False


class Controller:
    """Keeps the player on the timeline.

    mpv has no 'start at host time' call like AVPlayer, so: a restart seeks a little ahead,
    waits, and unpauses at the moment the timeline reaches that point. Small errors are taken
    out by nudging the speed (mpv changes speed without a stall); large ones restart.
    """

    TICK = 0.05
    LEAD = 0.5            # restart: seek this far ahead of now
    SOFT = 0.004          # mean error above this: correct with speed
    HARD = 0.25           # one error above this: restart
    MAX_NUDGE = 0.05      # speed 0.95 .. 1.05
    GAIN = 0.5            # speed = 1 + error / 2 s
    ARM = 0.2             # holding: show frame 0 this long before the loop point

    def __init__(self, timeline: Timeline, player: PlayerAPI, *, pos_bias: Optional[float] = None,
                 now: Callable[[], float] = host_now,
                 sleep: Callable[[float], None] = time.sleep) -> None:
        self.timeline = timeline
        self.player = player
        self.pos_bias = pos_bias
        self.now = now
        self.sleep = sleep
        self.stats = ControlStats()
        self.epoch: Optional[int] = None
        self.ema = 0.0
        self.correcting = False
        self.settle_until = 0.0

    def _holds(self, s: Schedule, dur: float) -> bool:
        """The common loop is longer than this movie: its last frame is held until the loop
        point. (When the loop is the movie's own length, mpv loops by itself.)"""
        return self.timeline.period(s, dur) > dur + 0.02

    def _holding(self, pos: float, dur: float) -> bool:
        return dur > 0 and pos >= dur - 0.05

    def _bias(self) -> float:
        # mpv's time-pos is the shown frame's time; on average the timeline is half a frame on.
        if self.pos_bias is not None:
            return self.pos_bias
        return self.player.frame_interval() / 2

    def tick(self) -> None:
        s, off, dur = self.timeline.snapshot()
        if s is None or off is None or dur <= 0:
            return
        new_epoch = s.epoch != self.epoch
        self.epoch = s.epoch
        now = self.now()
        want = self.timeline.loop_position(now)
        if want is None:
            return
        holds = self._holds(s, dur)

        if not s.playing:
            self.player.set_speed(1.0)
            if not self.player.paused():
                self.player.set_paused(True)
            if new_epoch:
                self.player.seek(min(want, max(0.0, dur - 0.001)))
            return

        if holds and self._holding(want, dur) and not new_epoch:
            self.stats.holding = True
            self.stats.error = 0.0
            if not self.player.paused():
                self.player.set_paused(True)
                self.player.seek(max(0.0, dur - 0.001))
            # Close to the loop point: show frame 0 (paused) and start exactly on it.
            to_loop = self.timeline.period(s, dur) - want
            if to_loop <= self.ARM:
                self.player.seek(0.0)
                self.sleep(max(0.0, to_loop - (self.now() - now)))
                self.player.set_paused(False)
                self.settle_until = self.now() + 0.3
                self.stats.holding = False
            return
        self.stats.holding = False

        if new_epoch or self.player.paused():
            self.restart()
            return
        if now < self.settle_until:
            return

        t0 = self.now()
        pos = self.player.position()
        t1 = self.now()
        if pos is None:
            return
        want = self.timeline.loop_position((t0 + t1) / 2)
        if want is None or (holds and self._holding(want, dur)):
            return
        err = pos + self._bias() - want
        period = self.timeline.period(s, dur)
        if period > 0:   # shortest way around the loop point
            if err > period / 2:
                err -= period
            if err < -period / 2:
                err += period
        self.stats.error = err
        self.ema = self.ema * 0.8 + err * 0.2
        self.stats.mean = self.ema
        if abs(err) > self.HARD:
            self.restart()
            return
        # Start correcting above SOFT, keep on until the mean error is nearly gone (hysteresis,
        # so the speed does not flip on and off at the threshold).
        if abs(self.ema) > self.SOFT:
            self.correcting = True
        elif abs(self.ema) < self.SOFT / 4:
            self.correcting = False
        speed = 1.0
        if self.correcting:
            speed += max(-self.MAX_NUDGE, min(self.MAX_NUDGE, -self.ema * self.GAIN))
        self.player.set_speed(speed)
        self.stats.speed = speed

    def restart(self) -> None:
        """Seek ahead, wait, unpause exactly when the timeline reaches that point."""
        s, off, dur = self.timeline.snapshot()
        if s is None or off is None or dur <= 0:
            return
        start_local = self.now() + self.LEAD
        start_local = max(start_local, s.anchorHost - off)   # a play announced ahead: start then
        pos = self.timeline.loop_position(start_local)
        if pos is None:
            return
        self.ema = 0.0
        self.correcting = False
        self.player.set_speed(1.0)
        self.stats.speed = 1.0
        if not self.player.paused():
            self.player.set_paused(True)
        if self._holds(s, dur) and self._holding(pos, dur):
            self.player.seek(max(0.0, dur - 0.001))
            return
        self.stats.restarts += 1
        self.player.seek(min(pos, max(0.0, dur - 0.001)))
        wait = start_local - self.now()
        if wait < 0:      # the seek took longer than the lead: try again next tick
            return
        self.sleep(wait)
        self.player.set_paused(False)
        self.settle_until = self.now() + 0.3

    def run(self, stop: threading.Event) -> None:
        while not stop.is_set():
            try:
                self.tick()
            except Exception as e:
                log("control error:", e)
            stop.wait(self.TICK)


# ---------------------------------------------------------------- app

def load_config(path: Optional[str]) -> dict:
    if not path:
        return {}
    with open(path, encoding="utf-8") as f:
        c = json.load(f)
    if not isinstance(c, dict):
        raise SystemExit(f"{path}: the settings must be a JSON object")
    base = os.path.dirname(os.path.abspath(path))
    if isinstance(c.get("movie"), str) and not os.path.isabs(c["movie"]):
        c["movie"] = os.path.join(base, c["movie"])
    return c


def parse_args(argv=None):
    p = argparse.ArgumentParser(description="SyncBox: play a movie in sync with SyncPlayer Macs.")
    p.add_argument("movie", nargs="?", help="movie file (or set 'movie' in the settings file)")
    p.add_argument("--config", help="settings file (JSON); command-line options win")
    role = p.add_mutually_exclusive_group()
    role.add_argument("--master", action="store_true", help="be the master (plays on start)")
    role.add_argument("--follower", action="store_true", help="follow a master (default)")
    p.add_argument("--name", help="name shown on the Macs (default: host name)")
    p.add_argument("--broadcast", help="broadcast address for the master (default 255.255.255.255)")
    p.add_argument("--to", action="append", default=None, help="extra address the master sends to")
    p.add_argument("--loop", type=float, default=None, help="master: fixed common loop length (s)")
    p.add_argument("--own-loop", action="store_true", help="master: each movie loops by its own length")
    p.add_argument("--no-autoplay", action="store_true", help="master: do not start playing")
    p.add_argument("--audio", action="store_true", help="play the movie's sound")
    p.add_argument("--log", action="store_true", help="print error, speed and clock once a second")
    p.add_argument("--mpv", default=None, help="mpv binary")
    p.add_argument("--mpv-arg", action="append", default=None, help="extra mpv option (repeatable)")
    p.add_argument("--pos-bias", type=float, default=None, help="seconds added to mpv's time-pos")
    p.add_argument("--version", action="version", version=VERSION)
    return p.parse_args(argv)


def merged(args, cfg: dict) -> dict:
    def pick(key, val, default=None):
        return val if val not in (None, False, []) else cfg.get(key, default)
    role = "master" if args.master else "follower" if args.follower else cfg.get("role", "follower")
    return {
        "movie": pick("movie", args.movie),
        "role": role,
        "name": pick("name", args.name, socket.gethostname()),
        "broadcast": pick("broadcast", args.broadcast, "255.255.255.255"),
        "to": pick("to", args.to, []),
        "loop": pick("loop", args.loop, 0.0),
        "together": not (args.own_loop or cfg.get("ownLoop", False)),
        "autoplay": not (args.no_autoplay or cfg.get("autoplay", True) is False),
        "audio": bool(args.audio or cfg.get("audio", False)),
        "log": bool(args.log or cfg.get("log", False)),
        "mpv": pick("mpv", args.mpv, "mpv"),
        "mpvArgs": pick("mpvArgs", args.mpv_arg, []),
        "posBias": pick("posBias", args.pos_bias, None),
    }


def main(argv=None) -> int:
    args = parse_args(argv)
    o = merged(args, load_config(args.config))
    movie = o["movie"]
    if not movie or not os.path.isfile(movie):
        print(f"movie not found: {movie}", file=sys.stderr)
        return 2
    label = os.path.basename(movie)

    timeline = Timeline()
    reader = Reader()
    reader.start()
    # Loop inside mpv unless the common loop may be longer than this movie (decided once the
    # length is known; a longer common loop holds the last frame, which needs keep-open).
    mpv = Mpv(movie, mpv_args=list(o["mpvArgs"]), audio=o["audio"],
              loop_file=True, binary=o["mpv"])
    player = MpvPlayer(mpv)
    for _ in range(100):
        d = player.duration()
        if d > 0:
            break
        time.sleep(0.05)
    if d <= 0:
        log("could not read the movie's length")
        mpv.close()
        return 3
    with timeline.lock:
        timeline.duration = d
    log(f"SyncBox {VERSION}: {label} ({d:.3f} s) as {o['role']}, name '{o['name']}'")

    stop = threading.Event()
    role: dict = {"node": None}

    def start_master(initial=None):
        since = max(time.time(), (role["node"].highest_since + 0.001)
                    if isinstance(role["node"], Follower) else 0)
        m = Master(reader, timeline, name=o["name"], file_label=label, broadcast=o["broadcast"],
                   extra_targets=list(o["to"]), since=since, together=o["together"],
                   fixed_loop=float(o["loop"] or 0), initial=initial,
                   on_demote=lambda: threading.Thread(target=demote, daemon=True).start())
        return m

    def demote():
        node = role["node"]
        if not isinstance(node, Master):
            return
        node.stop()
        role["node"] = Follower(reader, timeline, file_label=label, provisional_offset=0.0)
        log("now a follower")

    if o["role"] == "master":
        role["node"] = start_master()
        if o["autoplay"]:
            time.sleep(0.3)
            role["node"].play()
    else:
        role["node"] = Follower(reader, timeline, file_label=label)

    # The common loop can be longer than this movie: then mpv must not loop by itself.
    def watch_loop_mode():
        looping = True
        while not stop.is_set():
            s, _, dur = timeline.snapshot()
            want = not (s is not None and s.cycle and s.cycle > dur + 0.02)
            if want != looping:
                mpv.set("loop-file", "inf" if want else "no")
                looping = want
            stop.wait(0.5)

    threading.Thread(target=watch_loop_mode, daemon=True, name="loop-mode").start()

    ctl = Controller(timeline, player, pos_bias=o["posBias"])
    threading.Thread(target=ctl.run, args=(stop,), daemon=True, name="control").start()

    def on_signal(*_):
        stop.set()
    signal.signal(signal.SIGTERM, on_signal)
    signal.signal(signal.SIGINT, on_signal)

    last = 0.0
    while not stop.is_set():
        if not mpv.alive or mpv.proc.poll() is not None:
            log("mpv stopped")
            stop.set()
            break
        if o["log"] and host_now() - last >= 1.0:
            last = host_now()
            node = role["node"]
            st = ctl.stats
            if isinstance(node, Follower):
                off, rtt, ready = node.stats()
                log(f"follower mean={st.mean*1000:+.2f}ms err={st.error*1000:+.2f}ms speed={st.speed:.4f} "
                    f"restarts={st.restarts} hold={st.holding} rtt={rtt*1000:.2f}ms ready={ready}")
            else:
                log(f"master mean={st.mean*1000:+.2f}ms err={st.error*1000:+.2f}ms speed={st.speed:.4f} "
                    f"restarts={st.restarts} hold={st.holding}")
        stop.wait(0.2)

    node = role["node"]
    if node:
        node.stop()
    reader.running = False
    mpv.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
