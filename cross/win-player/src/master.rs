//! The master role, ported from the Mac's `Master` (Sources/SyncPlayer/Roles.swift): owns the
//! schedule, answers clock pings (on a thread of its own, so drawing never delays an answer),
//! announces the schedule every 0.2 s, keeps the common loop length (the longest clip any follower
//! reports, or the show's fixed length), and steps down when it hears a newer master.
use std::collections::HashMap;
use std::net::{SocketAddr, UdpSocket};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Instant;
use syncplayer_proto::{Message, Schedule, BEACON_PORT, CLOCK_PORT};

/// Shortest fixed loop length (s), as Show.minLoop.
const MIN_LOOP: f64 = 0.5;
/// A follower silent this long drops out of the loop length (and the previous master's loop is
/// kept this long), as on the Mac.
const FORGET_AFTER: f64 = 300.0;

#[derive(Clone, Debug)]
#[allow(dead_code)]
pub struct Peer { pub name: String, pub ver: String, pub err: Option<f64>, pub seat: Option<String>, pub at: f64 }

#[derive(Default)]
struct Heard {
    /// Each follower's longest clip and when it was last heard, by address:port.
    reported: HashMap<String, (f64, f64)>,
    peers: HashMap<String, Peer>,
}

pub struct Master {
    pub id: String,
    pub since: f64,
    pub schedule: Schedule,
    sock: UdpSocket,
    targets: Vec<SocketAddr>,
    heard: Arc<Mutex<Heard>>,
    /// Tells the clock thread to end (it holds a copy of the socket, so the port would stay taken).
    stop: Arc<AtomicBool>,
    inherited: Option<(f64, f64)>,
    next_beacon: f64,
    pub name: String,
    pub ver: String,
    pub file: String,
}

fn new_id() -> String {
    // Unique enough for telling masters apart (uppercase hex, like a UUID's look).
    let t = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_nanos();
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for b in t.to_le_bytes().iter().chain(std::process::id().to_le_bytes().iter()) { h = (h ^ *b as u64).wrapping_mul(0x100_0000_01b3); }
    format!("{:016X}-{:08X}", h, std::process::id())
}

impl Master {
    /// `initial`: a schedule to continue (already in this PC's clock), so taking over is seamless.
    /// `to`: extra addresses to send the beacon to (unicast, as the Mac's --to).
    pub fn new(start: Instant, initial: Option<Schedule>, since: f64, position: f64, to: &[String], broadcast: bool,
               bind: [u8; 4],
               name: String, ver: String, file: String) -> Result<Master, String> {
        let host = move || start.elapsed().as_secs_f64();
        let sock = UdpSocket::bind((std::net::Ipv4Addr::from(bind), CLOCK_PORT)).map_err(|e| format!("cannot open UDP {CLOCK_PORT} for the clock ({e})"))?;
        sock.set_broadcast(true).map_err(|e| format!("broadcast: {e}"))?;
        let mut targets: Vec<SocketAddr> = vec![SocketAddr::from(([127, 0, 0, 1], BEACON_PORT))]; // followers on this PC
        if broadcast { targets.push(SocketAddr::from(([255, 255, 255, 255], BEACON_PORT))); }
        for t in to {
            match format!("{t}:{BEACON_PORT}").parse::<SocketAddr>() {
                Ok(a) => targets.push(a),
                Err(_) => return Err(format!("--to {t}: not an IP address")),
            }
        }
        let inherited = initial.as_ref().and_then(|s| s.cycle).filter(|c| *c > 0.0).map(|c| (c, host() + FORGET_AFTER));
        let schedule = initial.unwrap_or_else(|| Schedule {
            epoch: std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(1),
            playing: false, anchor_host: host(), anchor_media: position, cycle: None,
        });
        let heard = Arc::new(Mutex::new(Heard::default()));
        // Clock answers on their own thread: t2 when the ping arrives, t3 just before the answer.
        let (reader, h2) = (sock.try_clone().map_err(|e| format!("clock socket: {e}"))?, heard.clone());
        let stop = Arc::new(AtomicBool::new(false));
        let stop2 = stop.clone();
        let _ = reader.set_read_timeout(Some(std::time::Duration::from_millis(200)));
        std::thread::spawn(move || {
            let mut buf = [0u8; 2048];
            while !stop2.load(Ordering::SeqCst) {
                let Ok((n, from)) = reader.recv_from(&mut buf) else { continue };
                let t2 = host();
                let Some(m) = Message::decode(&buf[..n]) else { continue };
                if m.k != "p" { continue; }
                let mut q = Message::new("q");
                q.id = m.id; q.t1 = m.t1; q.t2 = Some(t2);
                q.t3 = Some(host());
                let _ = reader.send_to(&q.encode(), from);
                let key = from.to_string();
                if let Ok(mut h) = h2.lock() {
                    if let Some(d) = m.dur.filter(|d| d.is_finite() && *d > 0.0 && *d < 86_400.0) { h.reported.insert(key.clone(), (d, t2)); }
                    let name: String = m.name.clone().unwrap_or(from.ip().to_string()).chars().take(40).collect();
                    h.peers.insert(key, Peer { name, ver: m.ver.clone().unwrap_or("?".into()).chars().take(30).collect(),
                        err: m.err.filter(|e| e.is_finite()), seat: m.seat.clone(), at: t2 });
                }
            }
        });
        Ok(Master { id: new_id(), since, schedule, sock, targets, heard, stop, inherited, next_beacon: 0.0, name, ver, file })
    }

    /// Followers heard in the last 3 s.
    pub fn peers(&self, now: f64) -> Vec<Peer> {
        let Ok(mut h) = self.heard.lock() else { return vec![] };
        h.peers.retain(|_, p| now - p.at < 3.0);
        let mut v: Vec<Peer> = h.peers.values().cloned().collect();
        v.sort_by(|a, b| a.name.cmp(&b.name));
        v
    }

    /// Another master's beacon: true when it is newer (this one should step down).
    pub fn outranked_by(&self, m: &Message) -> bool {
        let (Some(mid), Some(since)) = (&m.mid, m.since) else { return false };
        m.k == "b" && mid != &self.id && (since > self.since || (since == self.since && mid > &self.id))
    }

    /// Timeline now on this PC's clock (offset 0), not wrapped.
    pub fn position(&self, now: f64) -> f64 { self.schedule.timeline(now, 0.0) }

    /// Length of one loop: the common loop, else this PC's longest clip (Transport.duration).
    fn loop_len(&self, longest: f64) -> f64 { self.schedule.cycle.filter(|c| *c > 0.0).unwrap_or(longest) }

    fn set(&mut self, s: Schedule, now: f64) { self.schedule = s; self.announce(now); }

    pub fn toggle(&mut self, now: f64) { if self.schedule.playing { self.pause(now) } else { self.play(now) } }

    pub fn play(&mut self, now: f64) {
        if self.schedule.playing { return; }
        let mut s = self.schedule.clone();
        s.epoch += 1;
        s.anchor_media = self.position(now);
        s.anchor_host = now + 0.3; // give every follower time to hear it
        s.playing = true;
        self.set(s, now);
    }

    pub fn pause(&mut self, now: f64) {
        if !self.schedule.playing { return; }
        let mut s = self.schedule.clone();
        s.epoch += 1;
        s.anchor_media = self.position(now);
        s.anchor_host = now;
        s.playing = false;
        self.set(s, now);
    }

    /// Jump (wrapped by the loop length, so a jump past the end lands near the start).
    pub fn jump_to(&mut self, media: f64, longest: f64, now: f64) {
        let mut s = self.schedule.clone();
        s.epoch += 1;
        let d = self.loop_len(longest);
        let mut t = media.max(0.0);
        if d > 0.0 { t %= d; }
        s.anchor_media = t;
        s.anchor_host = now + 0.3;
        self.set(s, now);
    }

    pub fn jump_by(&mut self, delta: f64, longest: f64, now: f64) { let p = self.position(now); self.jump_to(p + delta, longest, now); }

    /// Every step: keep the loop length up to date and announce every 0.2 s.
    /// `together` / `fixed`: the show's loopTogether / loopLength. `longest`: this PC's longest clip.
    pub fn tick(&mut self, now: f64, together: bool, fixed: f64, longest: f64) {
        if now < self.next_beacon { return; }
        self.next_beacon = now + 0.2;
        self.update_cycle(now, together, fixed, longest);
        self.announce(now);
    }

    fn update_cycle(&mut self, now: f64, together: bool, fixed: f64, longest: f64) {
        let want = if !together { None } else if fixed > 0.0 { Some(fixed.max(MIN_LOOP)) } else {
            let mut l = longest;
            if let Ok(mut h) = self.heard.lock() {
                h.reported.retain(|_, (_, at)| now - *at < FORGET_AFTER);
                l = h.reported.values().map(|(d, _)| *d).fold(l, f64::max);
            }
            if let Some((c, until)) = self.inherited { if now < until { l = l.max(c) } else { self.inherited = None } }
            (l > 0.0).then_some(l)
        };
        if (self.schedule.cycle.unwrap_or(0.0) - want.unwrap_or(0.0)).abs() <= 0.0005 { return; }
        let mut s = self.schedule.clone();
        s.epoch += 1;
        let at = now + if s.playing { 0.3 } else { 0.0 };
        // Continue from where the loop is now: the timeline wrapped by the old loop length.
        let mut t = self.schedule.timeline(at, 0.0);
        let old = self.loop_len(longest);
        if old > 0.0 { t %= old; }
        if let Some(c) = want { if c > 0.0 { t %= c; } }
        s.anchor_media = t.max(0.0);
        s.anchor_host = at;
        s.cycle = want;
        self.schedule = s;
    }

    fn announce(&mut self, _now: f64) {
        let mut m = Message::new("b");
        m.s = Some(self.schedule.clone());
        m.mid = Some(self.id.clone());
        m.since = Some(self.since);
        m.file = Some(self.file.clone());
        if !self.name.is_empty() { m.name = Some(self.name.clone()); m.ver = Some(self.ver.clone()); }
        let d = m.encode();
        for t in &self.targets { let _ = self.sock.send_to(&d, t); }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn master(start: Instant) -> Master {
        Master::new(start, None, 10.0, 0.0, &[], false, [127, 0, 0, 1], "t".into(), "0".into(), "".into()).unwrap()
    }

    #[test]
    fn play_pause_jump_and_cycle() {
        // One test, since the master holds UDP 47801.
        let start = Instant::now();
        let mut m = master(start);
        let e0 = m.schedule.epoch;
        assert!(!m.schedule.playing);
        m.play(1.0);
        assert!(m.schedule.playing && m.schedule.epoch == e0 + 1);
        assert_eq!(m.schedule.anchor_host, 1.3);
        assert!((m.position(3.3) - 2.0).abs() < 1e-9);
        m.pause(3.3);
        assert!(!m.schedule.playing);
        assert!((m.position(10.0) - 2.0).abs() < 1e-9);
        // A jump past the end of a 4 s loop lands near the start.
        m.jump_to(9.0, 4.0, 10.0);
        assert!((m.schedule.anchor_media - 1.0).abs() < 1e-9);
        // Loop together, automatic length: the longest clip here (no followers yet).
        m.update_cycle(11.0, true, 0.0, 4.0);
        assert_eq!(m.schedule.cycle, Some(4.0));
        // A fixed length wins; it is never shorter than 0.5 s.
        m.update_cycle(12.0, true, 0.2, 4.0);
        assert_eq!(m.schedule.cycle, Some(0.5));
        // Not together: no common loop.
        m.update_cycle(13.0, false, 0.0, 4.0);
        assert_eq!(m.schedule.cycle, None);
        // A newer master outranks this one; an older one does not.
        let mut b = Message::new("b");
        b.mid = Some("X".into()); b.since = Some(11.0);
        assert!(m.outranked_by(&b));
        b.since = Some(9.0);
        assert!(!m.outranked_by(&b));
    }
}

impl Drop for Master {
    fn drop(&mut self) { self.stop.store(true, Ordering::SeqCst); }
}
