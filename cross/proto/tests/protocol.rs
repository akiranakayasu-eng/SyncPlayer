use syncplayer_proto::{clock::ClockSync, follower::Follower, Message, Schedule};

fn beacon(mid: &str, since: f64, playing: bool) -> Message {
    let mut m = Message::new("b");
    m.mid = Some(mid.into());
    m.since = Some(since);
    m.s = Some(Schedule { epoch: 7, playing, anchor_host: 100.0, anchor_media: 2.0, cycle: Some(13.0) });
    m
}

#[test]
fn message_roundtrip_and_unknown_fields() {
    let m = beacon("a", 1.0, true);
    assert_eq!(Message::decode(&m.encode()), Some(m));
    let d = br#"{"k":"q","id":3,"t1":1.0,"t2":2.0,"t3":2.001,"future":"x"}"#;
    let q = Message::decode(d).unwrap();
    assert_eq!((q.k.as_str(), q.id), ("q", Some(3)));
}

#[test]
fn clock_offset_and_rejects() {
    // master clock = local + 5 s, one-way delay 1 ms each way
    let mut c = ClockSync::new();
    for i in 0..10 {
        let t1 = i as f64;
        c.add(t1, t1 + 5.001, t1 + 5.0015, t1 + 0.0025);
    }
    assert!(c.ready());
    assert!((c.offset - 5.0).abs() < 1e-6, "{}", c.offset);
    let n = c.count();
    c.add(0.0, 5.0, 5.0, 0.6); // rtt 0.6 s: rejected
    c.add(1.0, 5.0, 5.5, 1.1); // rtt < 0: rejected
    assert_eq!(c.count(), n);
}

#[test]
fn timeline_and_clip_position() {
    let s = Schedule { epoch: 1, playing: true, anchor_host: 100.0, anchor_media: 2.0, cycle: Some(13.0) };
    assert_eq!(s.timeline(90.0, 5.0), 2.0); // before the anchor: held at anchor_media
    assert!((s.timeline(100.0, 5.0) - 7.0).abs() < 1e-9);
    assert!((s.clip_position(14.0, 10.0) - 1.0).abs() < 1e-9); // 14 mod 13
    assert_eq!(s.clip_position(12.0, 10.0), 10.0); // shorter clip holds its last frame
    let paused = Schedule { playing: false, ..s.clone() };
    assert_eq!(paused.timeline(500.0, 0.0), 2.0);
    let nocycle = Schedule { cycle: None, ..s };
    assert!((nocycle.clip_position(25.0, 10.0) - 5.0).abs() < 1e-9);
}

#[test]
fn follower_adopts_after_eight_samples() {
    let mut f = Follower::new();
    f.on_beacon(&beacon("m1", 1.0, true), "10.0.0.2", 0.0);
    assert!(f.master_alive(0.5));
    assert!(!f.master_alive(1.5));
    assert!(f.timeline(1.0).is_none()); // clock not learned yet
    for i in 0..8 {
        let p = f.ping_due(i as f64 * 0.1, "w", "0", None, 0.0).unwrap();
        let t1 = p.t1.unwrap();
        let mut q = Message::new("q");
        q.id = p.id; q.t1 = Some(t1); q.t2 = Some(t1 + 5.001); q.t3 = Some(t1 + 5.0015);
        f.on_pong(&q, t1 + 0.0025);
    }
    assert!(f.adopted);
    let t = f.timeline(100.0).unwrap();
    assert!((t - 7.0).abs() < 1e-3, "{}", t);
}

#[test]
fn follower_prefers_newer_master_but_waits_out_silence() {
    let mut f = Follower::new();
    f.on_beacon(&beacon("old", 5.0, true), "10.0.0.2", 0.0);
    f.on_beacon(&beacon("older", 1.0, true), "10.0.0.3", 0.2); // older, current master alive: ignored
    assert_eq!(f.master_id.as_deref(), Some("old"));
    f.on_beacon(&beacon("newer", 9.0, true), "10.0.0.4", 0.4);
    assert_eq!(f.master_id.as_deref(), Some("newer"));
    f.on_beacon(&beacon("older", 1.0, true), "10.0.0.3", 3.0); // newer silent > 1 s: switch allowed
    assert_eq!(f.master_id.as_deref(), Some("older"));
}
