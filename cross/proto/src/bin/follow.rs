//! Text-only follower: listens for a Mac master, learns its clock, prints the timeline once a second.
//! Windows stage 1 (no video yet). Usage: follow [name] [seat]
use std::net::UdpSocket;
use std::time::{Duration, Instant};
use syncplayer_proto::{follower::Follower, Message, BEACON_PORT, CLOCK_PORT};

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let name = args.get(1).cloned().unwrap_or_else(|| std::env::var("COMPUTERNAME").unwrap_or("Windows".into()));
    let seat = args.get(2).cloned();
    let beacon = UdpSocket::bind(("0.0.0.0", BEACON_PORT)).expect("bind beacon port 47800 (is another follower running?)");
    let clock = UdpSocket::bind(("0.0.0.0", 0)).expect("bind clock socket");
    beacon.set_nonblocking(true).unwrap();
    clock.set_nonblocking(true).unwrap();
    let start = Instant::now();
    let host = || start.elapsed().as_secs_f64();
    let mut f = Follower::new();
    let mut master_ip: Option<std::net::IpAddr> = None;
    let (mut next_ping, mut next_print) = (0.0f64, 0.0f64);
    let mut buf = [0u8; 4096];
    println!("follower '{}' listening on UDP {} (seat {:?})", name, BEACON_PORT, seat);
    loop {
        while let Ok((n, from)) = beacon.recv_from(&mut buf) {
            let now = host();
            if let Some(m) = Message::decode(&buf[..n]) {
                let before = f.master_id.clone();
                f.on_beacon(&m, &from.ip().to_string(), now);
                if f.master_id != before || master_ip.is_none() { master_ip = Some(from.ip()); }
            }
        }
        while let Ok((n, _)) = clock.recv_from(&mut buf) {
            let t4 = host();
            if let Some(m) = Message::decode(&buf[..n]) { f.on_pong(&m, t4); }
        }
        let now = host();
        if now >= next_ping {
            next_ping = now + 0.1;
            if let Some(mut p) = f.ping_due(now, &name, "0.1.0-win", None, 0.0) {
                p.seat = seat.clone();
                if let Some(ip) = master_ip { let _ = clock.send_to(&p.encode(), (ip, CLOCK_PORT)); }
            }
        }
        if now >= next_print {
            next_print = now + 1.0;
            if !f.master_alive(now) {
                println!("[{:7.1}] waiting for a master…", now);
            } else {
                let tl = f.timeline(now).map(|t| format!("{:.3}", t)).unwrap_or("-".into());
                println!("[{:7.1}] master {} ({}) samples {} offset {:+.3} ms rtt {:.2} ms playing {} timeline {}",
                    now, f.master_name.clone().unwrap_or_default(), master_ip.map(|i| i.to_string()).unwrap_or_default(),
                    f.clock.count(), f.clock.offset * 1000.0, f.clock.rtt * 1000.0,
                    f.schedule.as_ref().map(|s| s.playing).unwrap_or(false), tl);
            }
        }
        std::thread::sleep(Duration::from_millis(2));
    }
}
