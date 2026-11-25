"""Tests for syncbox.py without mpv: a simulated player on a virtual clock, and a master and a
follower talking over this machine's UDP. Run: python3 -m unittest box/test_syncbox.py"""

import json
import os
import sys
import time
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import syncbox as sb  # noqa: E402


class Clock:
    def __init__(self):
        self.t = 1000.0

    def now(self):
        return self.t

    def sleep(self, d):
        self.t += max(0.0, d)


class SimPlayer(sb.PlayerAPI):
    """A player whose picture advances at speed * drift. Reports positions quantized to frames
    (like mpv's time-pos), loops by itself when `loop` is on, else stops on the last frame."""

    def __init__(self, clock, dur, fps=30.0, drift=1.0, loop=True, seek_cost=0.08):
        self.c, self.dur, self.fps, self.drift, self.loop = clock, dur, fps, drift, loop
        self.seek_cost = seek_cost
        self.pos0, self.t0 = 0.0, clock.now()
        self._paused, self.speed = True, 1.0
        self.seeks = 0

    def _raw(self):
        p = self.pos0
        if not self._paused:
            p += (self.c.now() - self.t0) * self.speed * self.drift
        if self.loop:
            return p % self.dur
        return min(p, self.dur)

    def _rebase(self):
        self.pos0, self.t0 = self._raw(), self.c.now()

    def position(self):
        p = self._raw()
        return int(p * self.fps) / self.fps

    def paused(self):
        return self._paused

    def set_paused(self, p):
        self._rebase()
        self._paused = p

    def seek(self, t):
        self.c.sleep(self.seek_cost * 0.1)   # the command returns quickly
        self.pos0, self.t0 = min(max(0.0, t), self.dur), self.c.now()
        self.seeks += 1

    def set_speed(self, s):
        self._rebase()
        self.speed = s

    def duration(self):
        return self.dur

    def frame_interval(self):
        return 1.0 / self.fps


def make(clock, dur, schedule, offset=0.0):
    tl = sb.Timeline()
    tl.duration = dur
    tl.set(schedule, offset)
    return tl


def run(ctl, clock, seconds, errs=None):
    end = clock.t + seconds
    while clock.t < end:
        ctl.tick()
        if errs is not None:
            errs.append(ctl.stats.error)
        clock.sleep(sb.Controller.TICK)


def true_error(tl, player, clock):
    """Continuous picture position minus where the timeline says it should be."""
    want = tl.loop_position(clock.now())
    err = player._raw() - want
    p = tl.period(tl.schedule, tl.duration)
    if err > p / 2:
        err -= p
    if err < -p / 2:
        err += p
    return err


class ControllerTests(unittest.TestCase):
    def test_starts_on_schedule(self):
        c = Clock()
        s = sb.Schedule(1, True, c.now() - 3.0, 0.0)          # started 3 s ago
        tl = make(c, 20.0, s, offset=0.0)
        pl = SimPlayer(c, 20.0)
        ctl = sb.Controller(tl, pl, now=c.now, sleep=c.sleep)
        run(ctl, c, 10)
        self.assertLess(abs(true_error(tl, pl, c)), 0.003)
        self.assertEqual(ctl.stats.restarts, 1)

    def test_follows_master_clock_offset(self):
        c = Clock()
        off = 12345.678                                         # master clock - local clock
        s = sb.Schedule(1, True, c.now() + off - 1.0, 5.0)
        tl = make(c, 30.0, s, offset=off)
        pl = SimPlayer(c, 30.0)
        ctl = sb.Controller(tl, pl, now=c.now, sleep=c.sleep)
        run(ctl, c, 8)
        self.assertLess(abs(true_error(tl, pl, c)), 0.003)

    def test_drift_is_taken_out_by_speed(self):
        c = Clock()
        s = sb.Schedule(1, True, c.now(), 0.0)
        tl = make(c, 60.0, s)
        pl = SimPlayer(c, 60.0, drift=1.002)                    # 2 ms per second fast
        ctl = sb.Controller(tl, pl, now=c.now, sleep=c.sleep)
        run(ctl, c, 20)
        worst = 0.0
        for _ in range(400):                                    # the next 20 s
            run(ctl, c, sb.Controller.TICK)
            worst = max(worst, abs(true_error(tl, pl, c)))
        self.assertLess(worst, 0.005)
        self.assertEqual(ctl.stats.restarts, 1)                 # only the first start

    def test_loops_by_itself_without_restart(self):
        c = Clock()
        s = sb.Schedule(1, True, c.now(), 0.0, cycle=10.0)      # common loop = this movie
        tl = make(c, 10.0, s)
        pl = SimPlayer(c, 10.0, loop=True)
        ctl = sb.Controller(tl, pl, now=c.now, sleep=c.sleep)
        run(ctl, c, 35)                                         # three loop points
        self.assertEqual(ctl.stats.restarts, 1)
        self.assertLess(abs(true_error(tl, pl, c)), 0.003)

    def test_holds_last_frame_then_restarts_at_loop_point(self):
        c = Clock()
        s = sb.Schedule(1, True, c.now(), 0.0, cycle=13.0)      # longer than this 10 s movie
        tl = make(c, 10.0, s)
        pl = SimPlayer(c, 10.0, loop=False)
        ctl = sb.Controller(tl, pl, now=c.now, sleep=c.sleep)
        run(ctl, c, 11.5)
        self.assertTrue(pl.paused())
        self.assertGreater(pl._raw(), 9.9)                      # on the last frame
        run(ctl, c, 1.6)                                        # past the loop point (13 s)
        self.assertFalse(pl.paused())
        self.assertLess(abs(true_error(tl, pl, c)), 0.01)
        run(ctl, c, 5)
        self.assertLess(abs(true_error(tl, pl, c)), 0.003)
        self.assertEqual(ctl.stats.restarts, 1)                 # the hold is not a restart

    def test_pause_and_jump(self):
        c = Clock()
        s = sb.Schedule(1, True, c.now(), 0.0)
        tl = make(c, 30.0, s)
        pl = SimPlayer(c, 30.0)
        ctl = sb.Controller(tl, pl, now=c.now, sleep=c.sleep)
        run(ctl, c, 3)
        tl.set(sb.Schedule(2, False, c.now(), 7.5), 0.0)
        run(ctl, c, 1)
        self.assertTrue(pl.paused())
        self.assertAlmostEqual(pl._raw(), 7.5, places=3)
        tl.set(sb.Schedule(3, True, c.now() + 0.3, 7.5), 0.0)
        run(ctl, c, 4)
        self.assertLess(abs(true_error(tl, pl, c)), 0.003)


class MessageTests(unittest.TestCase):
    def test_schedule_without_cycle_leaves_it_out(self):
        d = sb.Schedule(3, True, 1.5, 2.0).to_json()
        self.assertNotIn("cycle", d)
        self.assertIsInstance(d["epoch"], int)

    def test_reads_a_mac_beacon(self):
        raw = json.dumps({"k": "b", "s": {"epoch": 1764000000, "playing": True,
                          "anchorHost": 123456.25, "anchorMedia": 0, "cycle": 20.5},
                          "mid": "A1", "since": 1764000000.5, "file": "a.mov",
                          "name": "nakaAir2022"}).encode()
        m = sb.decode(raw)
        s = sb.Schedule.from_json(m["s"])
        self.assertEqual(s.cycle, 20.5)
        self.assertTrue(s.playing)

    def test_ignores_garbage(self):
        self.assertIsNone(sb.decode(b"\xff\xfe"))
        self.assertIsNone(sb.decode(b"[1,2]"))
        self.assertIsNone(sb.Schedule.from_json({"epoch": 1}))

    def test_clock_sync_uses_short_round_trips(self):
        cs = sb.ClockSync()
        for i in range(20):
            rtt = 0.002 if i % 4 == 0 else 0.030
            # master is 5 s ahead; long round trips are lopsided (all delay on the way back)
            t1 = 100.0 + i
            t2 = t1 + 5.0 + (rtt / 2 if rtt < 0.01 else 0.001)
            t3 = t2 + 0.0001
            t4 = t3 - 5.0 + (rtt / 2 if rtt < 0.01 else rtt - 0.001)
            cs.add(t1, t2, t3, t4)
        self.assertTrue(cs.ready)
        self.assertAlmostEqual(cs.offset, 5.0, delta=0.0005)


class NetworkTests(unittest.TestCase):
    """A master and a follower on this machine, over real UDP (127.0.0.1)."""

    def test_follower_learns_clock_and_schedule(self):
        reader = sb.Reader()
        reader.start()
        mt, ft = sb.Timeline(), sb.Timeline()
        mt.duration, ft.duration = 20.0, 26.0
        m = sb.Master(reader, mt, name="box-a", file_label="a.mp4", broadcast="127.255.255.255",
                      extra_targets=[], since=time.time())
        f = sb.Follower(reader, ft, file_label="a.mp4")
        try:
            m.play()
            deadline = time.time() + 6
            while time.time() < deadline:
                s, off, _ = ft.snapshot()
                ms, _, _ = mt.snapshot()
                if s is not None and off is not None and s.cycle == 26.0 and s == ms:
                    break
                time.sleep(0.1)
            s, off, _ = ft.snapshot()
            self.assertIsNotNone(s)
            self.assertTrue(s.playing)
            self.assertLess(abs(off), 0.002)                    # same clock on one machine
            self.assertEqual(s.cycle, 26.0)                     # the follower's longer movie
            a = mt.loop_position(sb.host_now())
            b = ft.loop_position(sb.host_now())
            self.assertLess(abs(a - b), 0.005)
        finally:
            f.stop()
            m.stop()
            reader.running = False


if __name__ == "__main__":
    unittest.main()
