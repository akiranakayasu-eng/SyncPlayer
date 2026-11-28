//! A stand-in master on this PC, for testing win-player without a Mac: beacons to 127.0.0.1 every
//! 0.2 s, answers clock pings, and walks through play / jump / pause / play / cycle / no cycle.
//! Run: cargo run --release --example fake_master [beacon port, default 47800]
//!      (with another port, start win-player with the same --beacon-port)
use std::net::UdpSocket;
use std::time::{Duration, Instant};
use syncplayer_proto::{Message, Schedule, BEACON_PORT, CLOCK_PORT};

fn main() {
    let clock = UdpSocket::bind(("127.0.0.1", CLOCK_PORT)).expect("bind 127.0.0.1:47801");
    clock.set_nonblocking(true).unwrap();
    let out = UdpSocket::bind(("127.0.0.1", 0)).unwrap();
    let start = Instant::now();
    // A different origin than the follower's clock, so the offset is really learned.
    let host = || start.elapsed().as_secs_f64() + 1000.0;
    let since = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs_f64();
    let mut s = Schedule { epoch: 1, playing: true, anchor_host: host(), anchor_media: 0.0, cycle: None };
    // (seconds after start, what happens)
    let steps: Vec<(f64, &str)> = vec![(10.0, "jump 3"), (15.0, "pause"), (18.0, "play"), (23.0, "cycle 6"), (38.0, "cycle 0"), (45.0, "end")];
    let mut k = 0;
    let port: u16 = std::env::args().nth(1).and_then(|p| p.parse().ok()).unwrap_or(BEACON_PORT);
    let mut next_beacon = 0.0;
    let mut buf = [0u8; 4096];
    loop {
        let el = start.elapsed().as_secs_f64();
        if k < steps.len() && el >= steps[k].0 {
            let now = host();
            let tl = s.timeline(now, 0.0);
            let (cmd, arg) = steps[k].1.split_once(' ').unwrap_or((steps[k].1, ""));
            match cmd {
                "jump" => { s.anchor_media = arg.parse().unwrap(); s.anchor_host = now; }
                "pause" => { s.anchor_media = tl; s.anchor_host = now; s.playing = false; }
                "play" => { s.anchor_media = tl; s.anchor_host = now; s.playing = true; }
                "cycle" => { let c: f64 = arg.parse().unwrap(); s.cycle = (c > 0.0).then_some(c); s.anchor_media = tl; s.anchor_host = now; }
                _ => { println!("done"); return; }
            }
            s.epoch += 1;
            println!("[{el:5.1}] {} -> epoch {} timeline {:.3}", steps[k].1, s.epoch, s.timeline(host(), 0.0));
            k += 1;
        }
        while let Ok((n, from)) = clock.recv_from(&mut buf) {
            let t2 = host();
            if let Some(p) = Message::decode(&buf[..n]) {
                if p.k != "p" { continue; }
                let mut q = Message::new("q");
                q.id = p.id; q.t1 = p.t1; q.t2 = Some(t2); q.t3 = Some(host());
                let _ = clock.send_to(&q.encode(), from);
            }
        }
        if el >= next_beacon {
            next_beacon = el + 0.2;
            let mut b = Message::new("b");
            b.s = Some(s.clone()); b.mid = Some("fake".into()); b.since = Some(since); b.name = Some("fake-master".into());
            b.ver = Some("test".into());
            let _ = out.send_to(&b.encode(), ("127.0.0.1", port));
        }
        std::thread::sleep(Duration::from_millis(1));
    }
}
