//! SyncPlayer Windows player, stage 1 (picture only, no sound): opens a .syncshow, shows one seat's
//! first output in one window, and follows a Mac SyncPlayer master (protocol 1, docs/protocol.md).
//!
//! Usage: win-player <show.syncshow> [--seat B] [--size 1280x720] [--name NAME] [--local]
//!   --seat   seat name (default: the first seat)
//!   --size   picture size the movies are decoded at (default 1280x720)
//!   --name   name reported to the master (default: the computer name)
//!   --local  no master: play from 0 on this PC's own clock (to check the picture)
//!   --beacon-port N  listen for beacons on another port (tests with examples/fake_master only)
//! Keys: double-click = full screen, Esc = back to a window, I = hide/show the status.
//! Log: follow-log.csv in the folder it was started from, one line per second.
#![windows_subsystem = "windows"]

mod clip;
mod decoder;
mod font;
mod show;

use clip::ClipPlayer;
use std::io::Write;
use std::net::{IpAddr, UdpSocket};
use std::num::NonZeroU32;
use std::rc::Rc;
use std::time::{Duration, Instant};
use syncplayer_proto::{follower::Follower, Message, Schedule, BEACON_PORT, CLOCK_PORT};
use winit::application::ApplicationHandler;
use winit::event::{ElementState, MouseButton, WindowEvent};
use winit::event_loop::{ActiveEventLoop, ControlFlow, EventLoop};
use winit::keyboard::{Key, NamedKey};
use winit::window::{Fullscreen, Window, WindowId};

const VERSION: &str = "0.1.0-win";

struct Args { show: String, seat: Option<String>, w: u32, h: u32, name: String, local: bool, beacon_port: u16 }

fn parse_args() -> Result<Args, String> {
    let mut a = std::env::args().skip(1);
    let mut out = Args { show: String::new(), seat: None, w: 1280, h: 720,
        name: std::env::var("COMPUTERNAME").unwrap_or("Windows".into()), local: false, beacon_port: BEACON_PORT };
    while let Some(x) = a.next() {
        match x.as_str() {
            "--seat" => out.seat = a.next(),
            "--name" => out.name = a.next().unwrap_or(out.name),
            "--local" => out.local = true,
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
    if out.show.is_empty() { return Err("usage: win-player <show.syncshow> [--seat B] [--size 1280x720] [--name NAME] [--local]".into()); }
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

struct LayerRef { clip: usize, opacity: f64 }

struct App {
    args: Args,
    seat_name: String,
    file_label: String,
    clips: Vec<ClipPlayer>,
    layers: Vec<LayerRef>,
    layer_info: Vec<String>,
    missing: Vec<String>,
    // network
    beacon: Option<UdpSocket>,
    clock: UdpSocket,
    f: Follower,
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
    window: Option<Rc<Window>>,
    surface: Option<softbuffer::Surface<Rc<Window>, Rc<Window>>>,
    canvas: Vec<u32>,
    dirty: bool,
    status: Vec<String>,
    next_status: f64,
    show_status: bool,
    last_click: Option<Instant>,
}

impl App {
    fn host(&self) -> f64 { self.start.elapsed().as_secs_f64() }

    fn new(args: Args) -> App {
        let path = std::path::PathBuf::from(&args.show);
        let sh = show::ShowFile::read(&path).unwrap_or_else(|e| fail(&e));
        let seat = match &args.seat {
            Some(n) => sh.seats.iter().find(|s| &s.name == n).unwrap_or_else(|| fail(&format!(
                "no seat '{n}' in the show (seats: {})", sh.seats.iter().map(|s| s.name.clone()).collect::<Vec<_>>().join(", ")))),
            None => &sh.seats[0],
        };
        let out = seat.outputs.first().cloned().unwrap_or(show::Output { name: "Screen".into(), layers: vec![] });
        let mut clips: Vec<ClipPlayer> = vec![];
        let mut missing = vec![];
        let mut layers = vec![];
        for l in &out.layers {
            let idx = match clips.iter().position(|c| c.id == l.clip_id) {
                Some(i) => Some(i),
                None => match sh.clip_path(&l.clip_id).map(|p| decoder::Media::probe(&p)) {
                    Some(Ok(m)) => { clips.push(ClipPlayer::new(l.clip_id.clone(), m, args.w, args.h)); Some(clips.len() - 1) }
                    Some(Err(e)) => { missing.push(e); None }
                    None => { missing.push(format!("missing movie {}", sh.clip_label(l))); None }
                },
            };
            if let Some(i) = idx { if l.visible && l.opacity > 0.0 { layers.push(LayerRef { clip: i, opacity: l.opacity.min(1.0) }); } }
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
        clock.set_nonblocking(true).unwrap();
        let log = std::fs::File::create("follow-log.csv").ok().map(|mut f| {
            let _ = f.write_all(b"wall,host,offset_ms,rtt_ms,err_ms,max_abs_err_ms,resyncs,loops,epoch,playing,seat,clips\n");
            f
        });
        App {
            seat_name: seat.name.clone(), file_label, clips, layers, layer_info, missing,
            beacon, clock, f: Follower::new(), master_ip: None, start: Instant::now(), next_ping: 0.0, tick_err: 0.0,
            max_abs_err: 0.0, loops: 0, last_cycle: None, log, next_log: 1.0,
            window: None, surface: None, canvas: vec![0; (args.w * args.h) as usize], dirty: true,
            status: vec![], next_status: 0.0, show_status: true, last_click: None, args,
        }
    }

    /// The master counts as there for 5 s after its last beacon (master_alive is 1 s): over a VPN
    /// (Tailscale) beacons can pause for a second or two, and stopping would restart every clip.
    fn heard(&self, now: f64) -> bool { self.f.master_alive(now - 4.0) }

    fn longest(&self) -> f64 { self.clips.iter().map(|c| c.media.len).fold(0.0, f64::max) }

    /// Network, following and the log. Called about every 2 ms.
    fn step(&mut self) {
        let mut buf = [0u8; 4096];
        if let Some(b) = &self.beacon {
            while let Ok((n, from)) = b.recv_from(&mut buf) {
                let now = self.host();
                if let Some(m) = Message::decode(&buf[..n]) {
                    let before = self.f.master_id.clone();
                    self.f.on_beacon(&m, &from.ip().to_string(), now);
                    if self.f.master_id != before || self.master_ip.is_none() { self.master_ip = Some(from.ip()); }
                }
            }
        }
        while let Ok((n, _)) = self.clock.recv_from(&mut buf) {
            let t4 = self.host();
            if let Some(m) = Message::decode(&buf[..n]) { self.f.on_pong(&m, t4); }
        }
        let now = self.host();
        if now >= self.next_ping {
            self.next_ping = now + 0.1;
            let (name, longest) = (self.args.name.clone(), self.longest());
            if let Some(mut p) = self.f.ping_due(now, &name, VERSION, Some(self.tick_err * 1000.0), longest) {
                p.seat = Some(self.seat_name.chars().take(40).collect());
                p.file = Some(self.file_label.clone());
                if let Some(ip) = self.master_ip { let _ = self.clock.send_to(&p.encode(), (ip, CLOCK_PORT)); }
            }
        }

        // The schedule to follow: the master's, or (--local) playing from 0 on our own clock.
        let (sched, offset) = if self.args.local {
            (Some(Schedule { epoch: 1, playing: true, anchor_host: 1.0, anchor_media: 0.0, cycle: None }), 0.0)
        } else if self.heard(now) && self.f.clock.ready() {
            (self.f.schedule.clone(), self.f.clock.offset)
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
            self.f.clock.offset * 1000.0, self.f.clock.rtt * 1000.0, self.tick_err * 1000.0, self.max_abs_err * 1000.0,
            self.resyncs(), self.loops, s.epoch, s.playing as u8, self.seat_name, self.clips.len());
        if let Some(f) = &mut self.log { let _ = f.write_all(line.as_bytes()); }
        self.max_abs_err = 0.0;
    }

    fn update_status(&mut self, now: f64, s: Option<&Schedule>) {
        let mname = self.f.master_name.clone().or(self.master_ip.map(|i| i.to_string())).unwrap_or_default();
        let mut st = vec![];
        if self.args.local {
            st.push(format!("LOCAL test (no master)  seat {}", self.seat_name));
        } else if !self.heard(now) {
            st.push(format!("Waiting for a master...  seat {}  (Mac: --to <this PC's IP>)", self.seat_name));
        } else if s.is_none() {
            st.push(format!("Learning the clock from {mname}... samples {}  seat {}", self.f.clock.count(), self.seat_name));
        } else {
            let s = s.unwrap();
            st.push(format!("{} {}  seat {}", if s.playing { "Following" } else { "Paused by" }, mname, self.seat_name));
            st.push(format!("err {:+.1} ms  rtt {:.1} ms  resyncs {}  loops {}  epoch {}",
                self.tick_err * 1000.0, self.f.clock.rtt * 1000.0, self.resyncs(), self.loops, s.epoch));
            if !self.f.master_alive(now) { st.push("! no beacon for over 1 s (keeps following the last schedule up to 5 s)".into()); }
            if let Some(mf) = &self.f.master_file { if mf != &self.file_label { st.push("! the master has other movies".into()); } }
        }
        st.extend(self.missing.iter().map(|m| format!("! {m}")));
        if self.status != st {
            if let Some(w) = &self.window { w.set_title(&format!("SyncPlayer — {}", st[0])); }
            self.status = st;
            if self.show_status { self.dirty = true; }
        }
    }

    /// Layers in order (the last one in front), each with its opacity and the movie's own alpha bars.
    fn compose(&mut self) {
        self.canvas.fill(0);
        for l in &self.layers {
            let Some(f) = &self.clips[l.clip].cur else { continue };
            let op = (l.opacity * 256.0) as u32;
            for (d, s) in self.canvas.iter_mut().zip(f.rgba.chunks_exact(4)) {
                let a = (s[3] as u32 * op) >> 8;
                if a == 0 { continue; }
                if a >= 255 { *d = (s[0] as u32) << 16 | (s[1] as u32) << 8 | s[2] as u32; continue; }
                let ia = 255 - a;
                let (dr, dg, db) = ((*d >> 16) & 255, (*d >> 8) & 255, *d & 255);
                let r = (s[0] as u32 * a + dr * ia) / 255;
                let g = (s[1] as u32 * a + dg * ia) / 255;
                let b = (s[2] as u32 * a + db * ia) / 255;
                *d = r << 16 | g << 8 | b;
            }
        }
    }

    fn redraw(&mut self) {
        let Some(win) = self.window.clone() else { return };
        let size = win.inner_size();
        let (ww, wh) = (size.width, size.height);
        let (Some(nw), Some(nh)) = (NonZeroU32::new(ww), NonZeroU32::new(wh)) else { return };
        self.compose();
        let surface = self.surface.as_mut().unwrap();
        if surface.resize(nw, nh).is_err() { return; }
        let Ok(mut buf) = surface.buffer_mut() else { return };
        buf.fill(0);
        // Fit the picture into the window (aspect kept, black bars), nearest pixel.
        let (cw, ch) = (self.args.w as f64, self.args.h as f64);
        let k = (ww as f64 / cw).min(wh as f64 / ch);
        let (dw, dh) = ((cw * k) as u32, (ch * k) as u32);
        let (ox, oy) = ((ww - dw) / 2, (wh - dh) / 2);
        let xs: Vec<usize> = (0..dw).map(|x| ((x as f64 + 0.5) / k) as usize).map(|x| x.min(self.args.w as usize - 1)).collect();
        for y in 0..dh {
            let sy = (((y as f64 + 0.5) / k) as usize).min(self.args.h as usize - 1);
            let src = &self.canvas[sy * self.args.w as usize..][..self.args.w as usize];
            let row = &mut buf[((oy + y) * ww + ox) as usize..][..dw as usize];
            for (d, &sx) in row.iter_mut().zip(&xs) { *d = src[sx]; }
        }
        if self.show_status {
            let mut lines = self.status.clone();
            if self.status.len() <= 2 { lines.extend(self.layer_info.iter().cloned()); }
            font::draw_lines(&mut buf, ww, wh, 8, 8, &lines);
        }
        let _ = buf.present();
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
            .with_inner_size(winit::dpi::LogicalSize::new(960.0, 540.0));
        let w = Rc::new(el.create_window(attrs).unwrap_or_else(|e| fail(&format!("window: {e}"))));
        let ctx = softbuffer::Context::new(w.clone()).unwrap_or_else(|e| fail(&format!("softbuffer: {e}")));
        self.surface = Some(softbuffer::Surface::new(&ctx, w.clone()).unwrap_or_else(|e| fail(&format!("softbuffer: {e}"))));
        self.window = Some(w);
        self.dirty = true;
    }

    fn window_event(&mut self, el: &ActiveEventLoop, _: WindowId, ev: WindowEvent) {
        match ev {
            WindowEvent::CloseRequested => el.exit(),
            WindowEvent::RedrawRequested => self.redraw(),
            WindowEvent::Resized(_) => self.dirty = true,
            WindowEvent::MouseInput { state: ElementState::Pressed, button: MouseButton::Left, .. } => {
                let now = Instant::now();
                if self.last_click.map(|t| now - t < Duration::from_millis(400)).unwrap_or(false) {
                    let full = self.window.as_ref().map(|w| w.fullscreen().is_some()).unwrap_or(false);
                    self.toggle_full(!full);
                    self.last_click = None;
                } else { self.last_click = Some(now); }
            }
            WindowEvent::KeyboardInput { event, .. } if event.state == ElementState::Pressed => match event.logical_key {
                Key::Named(NamedKey::Escape) => self.toggle_full(false),
                Key::Character(c) if c.eq_ignore_ascii_case("i") => { self.show_status = !self.show_status; self.dirty = true; }
                _ => {}
            },
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
    let mut app = App::new(args);
    let el = EventLoop::new().unwrap_or_else(|e| fail(&format!("event loop: {e}")));
    let _ = el.run_app(&mut app);
}
