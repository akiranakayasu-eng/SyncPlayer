//! Follower state machine (no sockets): feed it beacons and pongs, ask it for pings.
//! Mirrors Roles.swift Follower: follows the newest master (larger `since`, then larger `mid`),
//! switches to another only if newer or the current one has been silent for 1 s, learns the clock
//! first (8 samples) and then adopts the schedule.
use crate::{clock::ClockSync, message::*};

pub struct Follower {
    pub clock: ClockSync,
    pub master_id: Option<String>,
    master_since: f64,
    last_beacon: f64,
    pub adopted: bool,
    pub schedule: Option<Schedule>,
    pending: Option<Schedule>,
    ping_id: i64,
    generation_start: i64,
    pub highest_since: f64,
    /// While the clock to a new master is learned: the offset the current schedule is in, so it
    /// keeps playing (the Mac's `provisional`, Roles.swift). None when nothing was playing.
    provisional: Option<f64>,
    pub master_file: Option<String>,
    pub master_name: Option<String>,
    pub master_ver: Option<String>,
    pub master_ident: bool,
    tick: u64,
}

impl Default for Follower { fn default() -> Self { Self::new() } }

impl Follower {
    pub fn new() -> Self {
        Follower { clock: ClockSync::new(), master_id: None, master_since: 0.0, last_beacon: f64::NEG_INFINITY,
            adopted: false, schedule: None, pending: None, provisional: None, ping_id: 0, generation_start: 0, highest_since: 0.0,
            master_file: None, master_name: None, master_ver: None, master_ident: false, tick: 0 }
    }

    /// `now` = local host clock seconds, `from` = sender address string.
    pub fn on_beacon(&mut self, m: &Message, from: &str, now: f64) {
        let Some(s) = m.s.clone() else { return };
        if m.k != "b" { return; }
        let mid = m.mid.clone().unwrap_or_else(|| from.to_string());
        let since = m.since.unwrap_or(0.0);
        self.highest_since = self.highest_since.max(since);
        if self.master_id.as_deref() != Some(&mid) {
            let newer = since > self.master_since;
            let silent = now - self.last_beacon > 1.0;
            if !(self.master_id.is_none() || newer || silent) { return; }
            // Keep playing the current schedule with the offset it is in until the clock to the
            // new master is known.
            self.provisional = if self.schedule.is_some() { self.offset() } else { None };
            self.adopted = false;
            self.master_id = Some(mid);
            self.master_since = since;
            self.clock.reset();
            self.generation_start = self.ping_id;
        }
        self.last_beacon = now;
        self.master_file = m.file.clone();
        self.master_ident = m.ident.unwrap_or(false);
        self.master_name = m.name.clone();
        self.master_ver = m.ver.clone();
        if !self.adopted && self.clock.ready() { self.adopted = true; self.provisional = None; }
        if self.adopted { self.schedule = Some(s); } else { self.pending = Some(s); }
    }

    pub fn on_pong(&mut self, m: &Message, t4: f64) {
        if m.k != "q" { return; }
        let (Some(id), Some(t1), Some(t2), Some(t3)) = (m.id, m.t1, m.t2, m.t3) else { return };
        if id <= self.generation_start { return; }
        self.clock.add(t1, t2, t3, t4);
        if !self.adopted && self.clock.ready() {
            self.adopted = true;
            self.provisional = None;
            if let Some(s) = self.pending.take() { self.schedule = Some(s); }
        }
    }

    pub fn master_alive(&self, now: f64) -> bool { self.master_id.is_some() && now - self.last_beacon < 1.0 }

    /// Call every 0.1 s. Returns a ping to send to the master's clock port, or None.
    /// Fast while learning (every call), then every 5th call (0.5 s).
    pub fn ping_due(&mut self, now: f64, name: &str, ver: &str, err_ms: Option<f64>, dur: f64) -> Option<Message> {
        self.master_id.as_ref()?;
        self.tick += 1;
        if self.clock.count() >= 40 && self.tick % 5 != 0 { return None; }
        self.ping_id += 1;
        let mut m = Message::new("p");
        m.id = Some(self.ping_id);
        if dur > 0.0 { m.dur = Some(dur); }
        if !name.is_empty() { m.name = Some(name.into()); m.ver = Some(ver.into()); m.err = err_ms; }
        m.t1 = Some(now);
        Some(m)
    }

    /// The offset (master clock - local clock) the current schedule is in: the learned one once
    /// adopted, the previous master's while a new master's clock is learned, else None.
    pub fn offset(&self) -> Option<f64> {
        if !self.adopted { return self.provisional; }
        self.clock.ready().then_some(self.clock.offset)
    }

    /// Timeline position now: once the clock is known and a schedule adopted, and also while a new
    /// master's clock is learned (the previous schedule goes on with the previous offset).
    pub fn timeline(&self, local: f64) -> Option<f64> {
        let off = self.offset()?;
        self.schedule.as_ref().map(|s| s.timeline(local, off))
    }
}
