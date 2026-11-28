//! SyncPlayer Windows player (picture only, no sound): opens a .syncshow, shows one seat's first
//! output (its Screen) in one window, drawn like the Mac (layers with position / scale / rotation,
//! corner pin, mesh, crop, feather, mask, opacity, and the Screen's edge blend), and follows a
//! SyncPlayer master (protocol 1, docs/protocol.md), or is the master itself.
//!
//! Usage: win-player <show.syncshow> [--seat B] [--size 1920x1080] [--name NAME] [--master [--to IP,IP]] [--local]
//!   --seat   seat name (default: the first seat)
//!   --size   largest size movies are decoded at, aspect kept (default 1920x1080)
//!   --name   name reported to the master / announced as master (default: the computer name)
//!   --master start as the master (as M); --to: also send the beacon to these addresses (unicast)
//!   --fullscreen  start full screen
//!   --exhibit     for exhibitions: full screen, no status, no mouse pointer (I shows the status)
//!   (no show given: the one opened last time, with the seat chosen last time for it)
//!   --local  no master: play from 0 on this PC's own clock (to check the picture)
//!   --beacon-port N  listen for beacons on another port (tests with examples/fake_master only)
//!   --no-broadcast   as master, send the beacon only to this PC and --to (tests: leaves other masters alone)
//! Keys: double-click = full screen, Esc = back to a window, I = hide/show the status,
//!   M = become the master / step down. As master: space = play/stop, ← → = one frame (shift: 1 s),
//!   ↑ or R = to the start (as on the Mac).
//! Log: follow-log.csv in the folder it was started from, one line per second.
#![windows_subsystem = "windows"]

mod clip;
mod decoder;
mod font;
mod gpu;
mod master;
mod memory;
mod show;
mod warp;

use clip::ClipPlayer;
use std::io::Write;
use std::net::{IpAddr, UdpSocket};
use std::sync::Arc;
use std::time::{Duration, Instant};
use syncplayer_proto::{follower::Follower, Message, Schedule, BEACON_PORT, CLOCK_PORT};
use winit::application::ApplicationHandler;
use winit::event::{ElementState, MouseButton, WindowEvent};
use winit::event_loop::{ActiveEventLoop, ControlFlow, EventLoop};
use winit::keyboard::{Key, NamedKey};
use winit::window::{Fullscreen, Window, WindowId};

const VERSION: &str = "0.1.0-win";

struct Args { show: String, seat: Option<String>, w: u32, h: u32, name: String, local: bool, beacon_port: u16,
    master: bool, to: Vec<String>, no_broadcast: bool, fullscreen: bool, exhibit: bool }

fn parse_args() -> Result<Args, String> {
    let mut a = std::env::args().skip(1);
    let mut out = Args { show: String::new(), seat: None, w: 1920, h: 1080,
        name: std::env::var("COMPUTERNAME").unwrap_or("Windows".into()), local: false, beacon_port: BEACON_PORT,
        master: false, to: vec![], no_broadcast: false, fullscreen: false, exhibit: false };
    while let Some(x) = a.next() {
        match x.as_str() {
            "--seat" => out.seat = a.next(),
            "--name" => out.name = a.next().unwrap_or(out.name),
            "--local" => out.local = true,
            "--master" => out.master = true,
            "--fullscreen" => out.fullscreen = true,
            "--exhibit" => { out.exhibit = true; out.fullscreen = true; }
            "--no-broadcast" => out.no_broadcast = true,
            "--to" => out.to.extend(a.next().unwrap_or_default().split(',').map(|s| s.trim().to_string()).filter(|s| !s.is_empty())),
            "--beacon-port" => out.beacon_port = a.next().and_then(|p| p.parse().ok()).ok_or("bad --beacon-port")?,
            "--size" => {
                let s = a.next().unwrap_or_default();
                let (w, h) = s.split_once('x').ok_or("--size wants WxH, e.g. 1920x1080")?;
                out.w = w.parse().map_err(|_| "bad --size")?;
                out.h = h.parse().map_err(|_| "bad --size")?;
                // even sizes keep ffmpeg's scaler simple
                out.w = out.w.clamp(16, 7680) & !1; out.h = out.h.clamp(16, 4320) & !1;
            }
            _ if out.show.is_empty() && !x.starts_with("--") => out.show = x,
            _ => return Err(format!("unknown argument {x}")),
        }
    }
    // No show given: the one opened last time (an exhibition PC just starts the player).
    if out.show.is_empty() { if let Some(p) = memory::last_show() { out.show = p.to_string_lossy().to_string(); } }
    if out.show.is_empty() { return Err("usage: win-player <show.syncshow> [--seat B] [--size 1920x1080] [--name NAME] [--master [--to IP,IP]] [--fullscreen] [--exhibit] [--local]\n(no show to open yet: give one the first time)".into()); }
    Ok(out)
}

/// Shown as a message box, since the app has no console.
fn fail(msg: &str) -> ! {
    eprintln!("{msg}");
    #[cfg(windows)]
    {
        let text: Vec<u16> = format!("{msg}\0").encode_utf16().collect();
        let title: Vec<u16> = "SyncPlayer win-player\0".encode_utf16().collect();
        #[link(name = "user32")]
        unsafe extern "system" { fn MessageBoxW(h: isize, t: *const u16, c: *const u16, f: u32) -> i32; }
        unsafe { MessageBoxW(0, text.as_ptr(), title.as_ptr(), 0x10); }
    }
    std::process::exit(1);
}

struct App {
    args: Args,
    seat_name: String,
    file_label: String,
    clips: Vec<ClipPlayer>,
    /// Layers for the GPU (handed over when the window is made).
    specs: Option<Vec<gpu::LayerSpec>>,
    blend: show::Blend,
    layer_info: Vec<String>,
    missing: Vec<String>,
    // network
    beacon: Option<UdpSocket>,
    clock: UdpSocket,
    /// Pongs with their receive time, read on their own thread: drawing waits for the display's
    /// refresh, and a pong read late would look like a longer round trip.
    pongs: std::sync::mpsc::Receiver<(Vec<u8>, f64)>,
    f: Follower,
    /// This PC is the master (M or --master): it owns the schedule.
    master: Option<master::Master>,
    /// After stepping down: the schedule (this PC's clock) that goes on until the new master's
    /// clock is known, so the picture does not stop.
    hold: Option<Schedule>,
    loop_together: bool,
    loop_fixed: f64,
    master_ip: Option<IpAddr>,
    start: Instant,
    next_ping: f64,
    tick_err: f64,
    // follow stats
    max_abs_err: f64,
    loops: u32,
    last_cycle: Option<i64>,
    log: Option<std::fs::File>,
    next_log: f64,
    // picture
    window: Option<Arc<Window>>,
    gpu: Option<gpu::Gpu>,
    /// Last frame serial uploaded, per clip.
    uploaded: Vec<u64>,
    overlay_dirty: bool,
    dirty: bool,
    status: Vec<String>,
    next_status: f64,
    show_status: bool,
    last_click: Option<Instant>,
    shift: bool,
}

impl App {
    fn host(&self) -> f64 { self.start.elapsed().as_secs_f64() }

    fn new(args: Args) -> App {
        let path = std::path::PathBuf::from(&args.show);
        // Full path (remembered for the next launch), without Windows' \\?\ prefix.
        let path = std::fs::canonicalize(&path)
            .map(|p| std::path::PathBuf::from(p.to_string_lossy().trim_start_matches(r"\\?\").to_string())).unwrap_or(path);
        let sh = show::ShowFile::read(&path).unwrap_or_else(|e| fail(&e));
        let seat = match &args.seat {
            Some(n) => sh.seats.iter().find(|s| &s.name == n).unwrap_or_else(|| fail(&format!(
                "no seat '{n}' in the show (seats: {})", sh.seats.iter().map(|s| s.name.clone()).collect::<Vec<_>>().join(", ")))),
            // Not given: the seat chosen last time for this show, else the first.
            None => memory::seat_for(&path).and_then(|n| sh.seats.iter().find(|s| s.name == n)).unwrap_or(&sh.seats[0]),
        };
        if !args.local { memory::remember(&path, &seat.name); }
        let out = seat.outputs.first().cloned().unwrap_or(show::Output { name: "Screen".into(), layers: vec![], blend: show::Blend::default() });
        let mut clips: Vec<ClipPlayer> = vec![];
        let mut missing = vec![];
        let mut layers = vec![];
        for l in &out.layers {
            let idx = match clips.iter().position(|c| c.id == l.clip_id) {
                Some(i) => Some(i),
                None => match sh.clip_path(&l.clip_id).map(|p| decoder::Media::probe(&p)) {
                    Some(Ok(m)) => {
                        let (w, h) = decoder::decode_size(&m, args.w, args.h);
                        clips.push(ClipPlayer::new(l.clip_id.clone(), m, w, h));
                        Some(clips.len() - 1)
                    }
                    Some(Err(e)) => { missing.push(e); None }
                    None => { missing.push(format!("missing movie {}", sh.clip_label(l))); None }
                },
            };
            let Some(i) = idx else { continue };
            if !l.visible || l.opacity <= 0.0 { continue; }
            let mask = match &l.mask {
                None => None,
                Some(m) => match sh.find(m).map(|p| gpu::load_mask(&p)) {
                    Some(Ok(img)) => Some(img),
                    Some(Err(e)) => { missing.push(e); None }
                    None => { missing.push(format!("missing mask {}", m.rsplit(['/', '\\']).next().unwrap_or(m))); None }
                },
            };
            layers.push(gpu::LayerSpec { clip: i, look: l.look.clone(), opacity: l.opacity.min(1.0), mask, mask_invert: l.mask_invert });
        }
        // front first, as on the Mac
        let layer_info = out.layers.iter().enumerate().rev().map(|(i, l)| format!("{} {} {}%{}", i + 1, sh.clip_label(l),
            (l.opacity * 100.0).round(), if l.visible { "" } else { " (hidden)" })).collect();
        // Same label the Mac master announces (movie names in name order), so a mismatch can be seen.
        let mut names: Vec<String> = sh.clips.iter().map(|c| c.path.rsplit(['/', '\\']).next().unwrap_or(&c.path).to_string()).collect();
        names.sort();
        let full = names.join(" + ");
        let file_label = if full.len() <= 400 { full } else {
            let mut h: u32 = 2_166_136_261;
            for b in full.bytes() { h = (h ^ b as u32).wrapping_mul(16_777_619); }
            format!("{} 本（{}… #{:x}）", sh.clips.len(), full.chars().take(60).collect::<String>(), h)
        };

        let beacon = if args.local { None } else {
            let s = UdpSocket::bind(("0.0.0.0", args.beacon_port)).unwrap_or_else(|e| fail(&format!(
                "cannot listen on UDP {} ({e}). Is another follower (follow.exe, win-player) running?", args.beacon_port)));
            s.set_nonblocking(true).unwrap();
            Some(s)
        };
        let clock = UdpSocket::bind(("0.0.0.0", 0)).unwrap_or_else(|e| fail(&format!("clock socket: {e}")));
        let start = Instant::now();
        let (ptx, pongs) = std::sync::mpsc::channel();
        let reader = clock.try_clone().unwrap_or_else(|e| fail(&format!("clock socket: {e}")));
        std::thread::spawn(move || {
            let mut b = [0u8; 2048];
            loop {
                match reader.recv_from(&mut b) {
                    Ok((n, _)) => {
                        let t4 = start.elapsed().as_secs_f64();
                        if ptx.send((b[..n].to_vec(), t4)).is_err() { break; }
                    }
                    // Windows reports a ping that met a closed port (a master that quit) as an error on
                    // the next receive (WSAECONNRESET). Keep reading: the next master's answers come here.
                    Err(_) => std::thread::sleep(std::time::Duration::from_millis(1)),
                }
            }
        });
        let log = std::fs::File::create("follow-log.csv").ok().map(|mut f| {
            let _ = f.write_all(b"wall,host,offset_ms,rtt_ms,err_ms,max_abs_err_ms,resyncs,loops,epoch,playing,seat,clips\n");
            f
        });
        App {
            seat_name: seat.name.clone(), file_label, uploaded: vec![0; clips.len()], clips, specs: Some(layers), blend: out.blend, layer_info, missing,
            beacon, clock, pongs, f: Follower::new(), master: None, hold: None,
            loop_together: sh.loop_together, loop_fixed: sh.loop_length, master_ip: None, start, next_ping: 0.0, tick_err: 0.0,
            max_abs_err: 0.0, loops: 0, last_cycle: None, log, next_log: 1.0,
            window: None, gpu: None, overlay_dirty: true, dirty: true,
            status: vec![], next_status: 0.0, show_status: !args.exhibit, last_click: None, shift: false, args,
        }
    }

    /// The master counts as there for 5 s after its last beacon (master_alive is 1 s): over a VPN
    /// (Tailscale) beacons can pause for a second or two, and stopping would restart every clip.
    fn heard(&self, now: f64) -> bool { self.f.master_alive(now - 4.0) }

    fn longest(&self) -> f64 { self.clips.iter().map(|c| c.media.len).fold(0.0, f64::max) }

    /// Become the master (M or --master). Continues what is playing (the followed schedule, moved
    /// to this PC's clock), so taking over is seamless, as on the Mac. Newest wins: `since` is the
    /// wall clock, but above any master heard so far.
    fn become_master(&mut self) -> Result<(), String> {
        if self.master.is_some() || self.args.local { return Ok(()); }
        let now = self.host();
        let wall = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs_f64()).unwrap_or(0.0);
        let since = wall.max(self.f.highest_since + 0.001);
        let initial = match (&self.hold, self.f.schedule.clone(), self.f.offset()) {
            (Some(h), _, _) => Some(h.clone()),
            (None, Some(mut s), Some(off)) if self.heard(now) => { s.anchor_host -= off; Some(s) }
            _ => None,
        };
        let m = master::Master::new(self.start, initial, since, 0.0, &self.args.to, !self.args.no_broadcast, [0, 0, 0, 0], self.args.name.clone(),
            VERSION.into(), self.file_label.clone())?;
        self.master = Some(m);
        self.hold = None;
        self.dirty = true;
        Ok(())
    }

    /// Stop being the master (M, or a newer master was heard). What plays goes on until the new
    /// master's clock is known.
    fn step_down(&mut self, _now: f64) {
        if let Some(m) = self.master.take() {
            self.hold = Some(m.schedule.clone());
            // Learn the clock of whichever master is heard next, from the start.
            self.f = Follower::new();
            self.master_ip = None;
        }
    }

    /// Frame length of the first clip, for the ← → keys.
    fn frame_step(&self) -> f64 { self.clips.first().map(|c| 1.0 / c.media.fps).unwrap_or(1.0 / 30.0) }

    /// Network, following and the log. Called about every 2 ms.
    fn step(&mut self) {
        let mut buf = [0u8; 4096];
        let mut got = vec![];
        if let Some(b) = &self.beacon {
            while let Ok((n, from)) = b.recv_from(&mut buf) {
                if let Some(m) = Message::decode(&buf[..n]) { got.push((m, from.ip(), self.host())); }
            }
        }
        for (m, ip, now) in got {
            if let Some(ms) = &self.master {
                // Our own beacon (sent to 127.0.0.1 too) is not another master.
                if m.mid.as_deref() == Some(ms.id.as_str()) { continue; }
                // A newer master: step down (as the Mac's onDemote) and follow it.
                if ms.outranked_by(&m) { self.step_down(now); }
            }
            let before = self.f.master_id.clone();
            self.f.on_beacon(&m, &ip.to_string(), now);
            if self.f.master_id != before || self.master_ip.is_none() { self.master_ip = Some(ip); }
        }
        while let Ok((d, t4)) = self.pongs.try_recv() {
            if let Some(m) = Message::decode(&d) { self.f.on_pong(&m, t4); }
        }
        let now = self.host();
        let longest = self.longest();
        if let Some(ms) = &mut self.master { ms.tick(now, self.loop_together, self.loop_fixed, longest); }
        if self.master.is_none() && now >= self.next_ping {
            self.next_ping = now + 0.1;
            let (name, longest) = (self.args.name.clone(), self.longest());
            if let Some(mut p) = self.f.ping_due(now, &name, VERSION, Some(self.tick_err * 1000.0), longest) {
                p.seat = Some(self.seat_name.chars().take(40).collect());
                p.file = Some(self.file_label.clone());
                if let Some(ip) = self.master_ip { let _ = self.clock.send_to(&p.encode(), (ip, CLOCK_PORT)); }
            }
        }

        // The schedule to follow: the master's, or (--local) playing from 0 on our own clock.
        if self.hold.is_some() && self.f.offset().is_some() { self.hold = None; }
        let (sched, offset) = if self.args.local {
            (Some(Schedule { epoch: 1, playing: true, anchor_host: 1.0, anchor_media: 0.0, cycle: None }), 0.0)
        } else if let Some(ms) = &self.master {
            (Some(ms.schedule.clone()), 0.0)
        } else if let Some(h) = &self.hold {
            // Just stepped down: our own last schedule goes on until the new master's clock is known.
            (Some(h.clone()), 0.0)
        } else if let (true, Some(off)) = (self.heard(now), self.f.offset()) {
            // Also while a new master's clock is learned: the previous schedule and offset go on
            // (no stop, no re-start of the movies).
            (self.f.schedule.clone(), off)
        } else { (None, 0.0) };

        match &sched {
            Some(s) => {
                let tl = s.timeline(now, offset);
                for c in self.clips.iter_mut() { if c.follow(tl, s.playing, s.cycle, now) { self.dirty = true; } }
                self.tick_err = self.clips.iter().map(|c| c.last_err).fold(0.0, |a, e| if e.abs() > a.abs() { e } else { a });
                self.max_abs_err = self.max_abs_err.max(self.tick_err.abs());
                let span = s.cycle.filter(|c| *c > 0.0).unwrap_or(self.longest());
                if span > 0.0 {
                    let idx = (tl / span).floor() as i64;
                    if let Some(l) = self.last_cycle { if idx > l { self.loops += 1; } }
                    self.last_cycle = Some(idx);
                }
                if now >= self.next_log { self.next_log = now + 1.0; self.write_log(now, s); }
            }
            None => { for c in self.clips.iter_mut() { if c.idle(now) { self.dirty = true; } } self.tick_err = 0.0; }
        }

        if now >= self.next_status {
            self.next_status = now + 0.25;
            self.update_status(now, sched.as_ref());
        }
    }

    fn resyncs(&self) -> u32 { self.clips.iter().map(|c| c.resyncs).sum() }

    fn write_log(&mut self, now: f64, s: &Schedule) {
        let line = format!("{},{:.3},{:.3},{:.2},{:.3},{:.3},{},{},{},{},{},{}\n", wall_iso(), now,
            self.f.offset().unwrap_or(0.0) * 1000.0, self.f.clock.rtt * 1000.0, self.tick_err * 1000.0, self.max_abs_err * 1000.0,
            self.resyncs(), self.loops, s.epoch, s.playing as u8, self.seat_name, self.clips.len());
        if let Some(f) = &mut self.log { let _ = f.write_all(line.as_bytes()); }
        self.max_abs_err = 0.0;
    }

    fn update_status(&mut self, now: f64, s: Option<&Schedule>) {
        let mname = self.f.master_name.clone().or(self.master_ip.map(|i| i.to_string())).unwrap_or_default();
        let mut st = vec![];
        if self.args.local {
            st.push(format!("LOCAL test (no master)  seat {}", self.seat_name));
        } else if let Some(m) = &self.master {
            let s = &m.schedule;
            st.push(format!("MASTER (this PC)  {}  seat {}", if s.playing { "playing" } else { "stopped" }, self.seat_name));
            st.push(format!("time {:.2} s  loop {}  epoch {}  resyncs {}  loops {}", m.position(now),
                s.cycle.map(|c| format!("{c:.2} s")).unwrap_or("-".into()), s.epoch, self.resyncs(), self.loops));
            let peers = m.peers(now);
            st.push(if peers.is_empty() { "followers: none heard".into() } else {
                format!("followers: {}", peers.iter().map(|p| format!("{}{} {}", p.name,
                    p.seat.as_ref().map(|s| format!(" [{s}]")).unwrap_or_default(),
                    p.err.map(|e| format!("{e:+.1}ms")).unwrap_or("-".into()))).collect::<Vec<_>>().join(", "))
            });
            st.push("space play/stop  <- -> frame (shift 1 s)  up/R start  M step down".into());
        } else if self.hold.is_some() {
            st.push(format!("Stepped down: waiting for the next master (the last schedule goes on)  seat {}", self.seat_name));
        } else if !self.heard(now) {
            st.push(format!("Waiting for a master...  seat {}  (Mac: --to <this PC's IP>)", self.seat_name));
        } else if s.is_none() {
            st.push(format!("Learning the clock from {mname}... samples {}  seat {}", self.f.clock.count(), self.seat_name));
        } else {
            let s = s.unwrap();
            st.push(format!("{} {}  seat {}", if s.playing { "Following" } else { "Paused by" }, mname, self.seat_name));
            st.push(format!("err {:+.1} ms  rtt {:.1} ms  resyncs {}  loops {}  epoch {}",
                self.tick_err * 1000.0, self.f.clock.rtt * 1000.0, self.resyncs(), self.loops, s.epoch));
            if !self.f.adopted { st.push(format!("learning the new master's clock (samples {}); the last schedule goes on", self.f.clock.count())); }
            if !self.f.master_alive(now) { st.push("! no beacon for over 1 s (keeps following the last schedule up to 5 s)".into()); }
            if let Some(mf) = &self.f.master_file { if mf != &self.file_label { st.push("! the master has other movies".into()); } }
        }
        st.extend(self.missing.iter().map(|m| format!("! {m}")));
        if self.status != st {
            if let Some(w) = &self.window { w.set_title(&format!("SyncPlayer — {}", st[0])); }
            self.status = st;
            if self.show_status { self.dirty = true; self.overlay_dirty = true; }
        }
    }

    fn redraw(&mut self) {
        let Some(g) = self.gpu.as_mut() else { return };
        for (k, c) in self.clips.iter().enumerate() {
            if c.serial != self.uploaded[k] {
                if let Some(f) = &c.cur { g.set_frame(k, c.w, c.h, &f.rgba); }
                self.uploaded[k] = c.serial;
            }
        }
        if self.overlay_dirty {
            self.overlay_dirty = false;
            if self.show_status {
                let mut lines = self.status.clone();
                if self.status.len() <= 2 { lines.extend(self.layer_info.iter().cloned()); }
                let wide = self.window.as_ref().map(|w| w.inner_size().width >= 1600).unwrap_or(false);
                g.set_overlay(Some(font::render(&lines, if wide { 2 } else { 1 })));
            } else { g.set_overlay(None); }
        }
        g.render(&self.blend);
        self.dirty = false;
    }

    fn toggle_full(&self, full: bool) {
        if let Some(w) = &self.window { w.set_fullscreen(if full { Some(Fullscreen::Borderless(None)) } else { None }); }
    }
}

fn wall_iso() -> String {
    // UTC, ISO 8601, without a date crate.
    let t = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default();
    let secs = t.as_secs() as i64;
    let (days, rem) = (secs.div_euclid(86400), secs.rem_euclid(86400));
    // civil from days (Howard Hinnant)
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = yoe + era * 400 + if m <= 2 { 1 } else { 0 };
    format!("{y:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}.{:03}Z", rem / 3600, rem % 3600 / 60, rem % 60, t.subsec_millis())
}

impl ApplicationHandler for App {
    fn resumed(&mut self, el: &ActiveEventLoop) {
        if self.window.is_some() { return; }
        let attrs = Window::default_attributes().with_title("SyncPlayer")
            .with_inner_size(winit::dpi::LogicalSize::new(960.0, 540.0))
            .with_fullscreen(self.args.fullscreen.then_some(Fullscreen::Borderless(None)));
        let w = Arc::new(el.create_window(attrs).unwrap_or_else(|e| fail(&format!("window: {e}"))));
        // An exhibition screen shows no mouse pointer.
        if self.args.exhibit { w.set_cursor_visible(false); }
        let specs = self.specs.take().unwrap_or_default();
        let g = gpu::Gpu::new(w.clone(), self.clips.len(), specs).unwrap_or_else(|e| fail(&format!("GPU: {e}")));
        self.layer_info.push(format!("GPU {}", g.adapter_name));
        self.gpu = Some(g);
        self.window = Some(w);
        self.overlay_dirty = true;
        self.dirty = true;
    }

    fn window_event(&mut self, el: &ActiveEventLoop, _: WindowId, ev: WindowEvent) {
        match ev {
            WindowEvent::CloseRequested => el.exit(),
            WindowEvent::RedrawRequested => self.redraw(),
            WindowEvent::Resized(s) => {
                if let Some(g) = &mut self.gpu { g.resize(s.width, s.height); }
                self.dirty = true; self.overlay_dirty = true;
            }
            WindowEvent::MouseInput { state: ElementState::Pressed, button: MouseButton::Left, .. } => {
                let now = Instant::now();
                if self.last_click.map(|t| now - t < Duration::from_millis(400)).unwrap_or(false) {
                    let full = self.window.as_ref().map(|w| w.fullscreen().is_some()).unwrap_or(false);
                    self.toggle_full(!full);
                    self.last_click = None;
                } else { self.last_click = Some(now); }
            }
            WindowEvent::ModifiersChanged(m) => self.shift = m.state().shift_key(),
            WindowEvent::KeyboardInput { event, .. } if event.state == ElementState::Pressed => {
                let now = self.host();
                let (longest, frame) = (self.longest(), self.frame_step());
                let step = if self.shift { 1.0 } else { frame };
                match event.logical_key {
                    Key::Named(NamedKey::Escape) => self.toggle_full(false),
                    Key::Character(c) if c.eq_ignore_ascii_case("i") => { self.show_status = !self.show_status; self.dirty = true; self.overlay_dirty = true; }
                    Key::Character(c) if c.eq_ignore_ascii_case("m") && !event.repeat => {
                        if self.master.is_some() { self.step_down(now); }
                        else if let Err(e) = self.become_master() { self.missing.push(e); }
                        self.next_status = 0.0;
                    }
                    // Master keys, as on the Mac: space, ← → (shift: 1 s), ↑ or R to the start.
                    Key::Named(NamedKey::Space) if !event.repeat => if let Some(m) = &mut self.master { m.toggle(now); },
                    Key::Named(NamedKey::ArrowLeft) => if let Some(m) = &mut self.master { m.jump_by(-step, longest, now); },
                    Key::Named(NamedKey::ArrowRight) => if let Some(m) = &mut self.master { m.jump_by(step, longest, now); },
                    Key::Named(NamedKey::ArrowUp) => if let Some(m) = &mut self.master { m.jump_to(0.0, longest, now); },
                    Key::Character(c) if c.eq_ignore_ascii_case("r") => if let Some(m) = &mut self.master { m.jump_to(0.0, longest, now); },
                    _ => {}
                }
            }
            _ => {}
        }
    }

    fn about_to_wait(&mut self, el: &ActiveEventLoop) {
        self.step();
        if self.dirty { if let Some(w) = &self.window { w.request_redraw(); } }
        el.set_control_flow(ControlFlow::WaitUntil(Instant::now() + Duration::from_millis(2)));
    }
}

fn main() {
    let args = parse_args().unwrap_or_else(|e| fail(&e));
    let start_master = args.master;
    let mut app = App::new(args);
    if start_master { app.become_master().unwrap_or_else(|e| fail(&e)); }
    let el = EventLoop::new().unwrap_or_else(|e| fail(&format!("event loop: {e}")));
    let _ = el.run_app(&mut app);
}
