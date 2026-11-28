import Foundation

extension Schedule {
    /// Timeline position (not wrapped) at local time `local`; offset = master clock - local clock.
    /// Same formula as Mac Transport.timeline.
    func timeline(local: Double, offset: Double) -> Double {
        playing ? anchorMedia + max(0, local + offset - anchorHost) : anchorMedia
    }
    /// Position inside a clip of length `len`: wrapped by the common loop `cycle` (a shorter clip
    /// holds its last frame), else by its own length.
    func clipPosition(timeline t: Double, len: Double) -> Double {
        if let c = cycle, c > 0 { return min(t.truncatingRemainder(dividingBy: c), len - 0.001) }
        return t.truncatingRemainder(dividingBy: len)
    }
}

/// The follower's protocol state (no sockets, no playback), after Mac Roles.swift Follower.
struct FollowerCore {
    var clock = ClockSync()
    var masterID: String?
    var masterHost = "-"
    var masterName: String?
    var schedule: Schedule?
    private var masterSince = 0.0
    private var lastBeacon = -Double.infinity
    private var adopted = false
    private var pending: Schedule?
    private var pingID = 0
    private var generationStart = 0

    /// Returns true when the beacon is from the master being followed (so the caller may aim pings at it).
    @discardableResult
    mutating func onBeacon(_ m: Message, from host: String, now: Double) -> Bool {
        guard let s = m.s else { return false }
        let mid = m.mid ?? host, since = m.since ?? 0
        if mid != masterID {
            let newer = since > masterSince, silent = now - lastBeacon > 1.0
            guard masterID == nil || newer || silent else { return false }
            adopted = false; masterID = mid; masterSince = since
            clock.reset(); generationStart = pingID
        }
        lastBeacon = now; masterHost = host; masterName = m.name
        if !adopted && clock.ready { adopted = true }
        if adopted { schedule = s } else { pending = s }
        return true
    }

    mutating func onPong(_ m: Message, t4: Double) {
        guard let id = m.id, let t1 = m.t1, let t2 = m.t2, let t3 = m.t3, id > generationStart else { return }
        clock.add(t1: t1, t2: t2, t3: t3, t4: t4)
        if !adopted && clock.ready { adopted = true; if let p = pending { schedule = p; pending = nil } }
    }

    func masterAlive(now: Double) -> Bool { masterID != nil && now - lastBeacon < 5.0 }   // like the Windows player: ride out short Wi‑Fi gaps, stop after 5 s

    /// Called every 50 ms (`tick` counts calls): every call while learning, then every 5th (0.25 s).
    mutating func pingDue(now: Double, name: String, ver: String, errMs: Double, dur: Double, seat: String?, tick: Int) -> Message? {
        guard masterID != nil else { return nil }
        if clock.count >= 40 && tick % 5 != 0 { return nil }
        pingID += 1
        var m = Message(k: "p")
        m.id = pingID; m.dur = dur > 0 ? dur : nil
        m.name = name; m.ver = ver; m.seat = seat; m.err = errMs.isFinite ? errMs : nil
        m.t1 = now
        return m
    }
}
