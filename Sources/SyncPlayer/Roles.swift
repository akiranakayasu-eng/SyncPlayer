import Foundation
import Darwin

/// Master: owns the schedule, answers clock pings, announces the schedule.
/// Any Mac can become master. If it hears a newer master, it steps down (onDemote).
final class Master {
    let transport: Transport
    let id = UUID().uuidString
    /// Priority: the newest master wins. Given by the caller as larger than any master this
    /// Mac has heard of, so a Mac whose wall clock is behind can still take over.
    let since: Double
    private let sock: UDPSocket          // clock answers + beacon sending
    private let listen: UDPSocket        // hears other masters' beacons
    private var targets: [sockaddr_in]
    private(set) var schedule: Schedule
    private var timer: Timer?
    var onDemote: (() -> Void)?
    /// Movie names, announced so followers can warn when theirs differ.
    var fileLabel: () -> String = { "" }
    /// Loop policy from the show: together (common loop) and a fixed length (0 = automatic).
    var loopPolicy: () -> (together: Bool, fixed: Double) = { (true, 0) }
    /// Longest clip any follower reported (guarded by lock). Only grows, so a Mac that drops
    /// out for a while does not change the loop for everyone.
    private var reportedLongest = 0.0
    private var longestSeen = 0.0
    private let lock = NSLock()

    /// initial: the schedule to continue (already in this Mac's clock), so taking over is seamless.
    init(transport: Transport, broadcast: String, extraTargets: [String], initial: Schedule?, since: Double) throws {
        self.transport = transport
        self.since = since
        sock = try UDPSocket(port: Ports.clock, broadcast: true)
        do {
            listen = try UDPSocket(port: Ports.beacon, reusePort: true)
        } catch {
            sock.close(); throw error
        }
        targets = [UDPSocket.address(broadcast, Ports.beacon),
                   UDPSocket.address("127.0.0.1", Ports.beacon)]   // followers on this Mac
        targets += extraTargets.map { UDPSocket.address($0, Ports.beacon) }
        if let initial {
            schedule = initial
            longestSeen = initial.cycle ?? 0
        } else {
            schedule = Schedule(epoch: Int(Date().timeIntervalSince1970), playing: false,
                                anchorHost: hostNow(), anchorMedia: transport.currentPosition())
        }
        transport.clockOffset = { 0 }
        transport.schedule = schedule

        sock.onReceive = { [weak self] data, from in
            let t2 = hostNow()
            guard let self, let m = Message.decode(data), m.k == "p" else { return }
            if let d = m.dur, d.isFinite, d > 0, d < 86_400 {
                self.lock.lock(); self.reportedLongest = max(self.reportedLongest, d); self.lock.unlock()
            }
            var reply = Message(k: "q")
            reply.id = m.id; reply.t1 = m.t1; reply.t2 = t2
            reply.t3 = hostNow()
            self.sock.send(reply.encoded(), to: from)
        }
        // Answer pings off the main thread so the UI never delays them.
        sock.start(queue: DispatchQueue(label: "master.clock", qos: .userInteractive))

        listen.onReceive = { [weak self] data, _ in
            guard let self, let m = Message.decode(data), m.k == "b",
                  let mid = m.mid, mid != self.id, let since = m.since else { return }
            if since > self.since || (since == self.since && mid > self.id) {
                DispatchQueue.main.async { self.onDemote?() }
            }
        }
        listen.start(queue: DispatchQueue(label: "master.listen"))

        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.updateCycle()
            self?.announce()
        }
        updateCycle()
        announce()
    }

    func stop() {
        timer?.invalidate(); timer = nil
        sock.close(); listen.close()
    }

    private func announce() {
        var m = Message(k: "b", s: schedule)
        m.mid = id; m.since = since; m.file = fileLabel()
        let data = m.encoded()
        for t in targets { sock.send(data, to: t) }
    }

    /// Keep the common loop length up to date (the longest clip on any Mac, or the show's fixed
    /// length). When it changes, the loop restarts from the current position on every Mac.
    private func updateCycle() {
        let p = loopPolicy()
        var want: Double? = nil
        if p.together {
            if p.fixed > 0 {
                want = p.fixed
            } else {
                lock.lock(); let r = reportedLongest; lock.unlock()
                longestSeen = max(longestSeen, r, transport.longest)
                want = longestSeen > 0 ? longestSeen : nil
            }
        }
        guard abs((schedule.cycle ?? 0) - (want ?? 0)) > 0.0005 else { return }
        var s = schedule
        s.epoch += 1
        let at = hostNow() + (s.playing ? 0.3 : 0)
        var t = transport.timeline(atLocal: at) ?? 0
        if let c = want, c > 0 { t = t.truncatingRemainder(dividingBy: c) }
        s.anchorMedia = max(0, t)
        s.anchorHost = at
        s.cycle = want
        set(s)
    }

    private func set(_ s: Schedule) {
        schedule = s
        transport.schedule = s
        announce()
    }

    /// Current timeline position by the schedule (not wrapped: each clip wraps by its own length).
    func position() -> Double { transport.timeline(atLocal: hostNow()) ?? 0 }

    func togglePlay() { schedule.playing ? pause() : play() }

    func play() {
        guard !schedule.playing else { return }
        var s = schedule
        s.epoch += 1
        s.anchorMedia = position()
        s.anchorHost = hostNow() + 0.3   // give every follower time to hear it
        s.playing = true
        set(s)
    }

    func pause() {
        guard schedule.playing else { return }
        var s = schedule
        s.epoch += 1
        s.anchorMedia = position()
        s.anchorHost = hostNow()
        s.playing = false
        set(s)
    }

    func jump(to media: Double) {
        var s = schedule
        s.epoch += 1
        // Wrap by the loop length, so a jump past the end lands near the start.
        let d = transport.duration
        var t = max(0, media)
        if d > 0 { t = t.truncatingRemainder(dividingBy: d) }
        s.anchorMedia = t
        s.anchorHost = hostNow() + 0.3
        set(s)
    }

    func jump(by delta: Double) { jump(to: position() + delta) }
}

/// Follower: listens for the master's beacon, measures the clock, plays the schedule.
/// Follows the newest master; switches to another only if that one is newer or the
/// current one has been silent for more than 1 s.
final class Follower {
    let transport: Transport
    let clock = ClockSync()
    private let beaconSock: UDPSocket
    private let clockSock: UDPSocket
    private var masterAddr: sockaddr_in?
    private(set) var masterHost = "-"
    private(set) var masterID: String?
    private var masterSince: Double = 0
    private(set) var masterFile: String?
    private var lastBeacon: Double = 0
    private var pingID = 0              // guarded by lock
    /// Pongs with an id at or below this belong to an earlier master (guarded by lock).
    private var generationStart = 0
    /// Largest master priority heard from any beacon (to outrank it when taking over).
    private(set) var highestSince: Double = 0
    /// False until the clock to the current master is learned and its schedule taken on.
    /// Until then the previous schedule keeps playing with the previous offset (main thread).
    private var adopted = false
    private var provisional: Double?
    private var timer: Timer?
    private let queue = DispatchQueue(label: "follower.net", qos: .userInteractive)
    private let lock = NSLock()

    /// provisionalOffset: the offset the node's current schedule is in (0 when this Mac was
    /// the master), so playback continues while the clock to the new master is learned.
    init(transport: Transport, provisionalOffset: Double?) throws {
        self.transport = transport
        provisional = provisionalOffset
        beaconSock = try UDPSocket(port: Ports.beacon, reusePort: true)
        clockSock = try UDPSocket(port: 0)
        transport.clockOffset = { [weak self] in
            guard let self else { return nil }
            if !self.adopted { return self.provisional }
            self.lock.lock(); defer { self.lock.unlock() }
            return self.clock.ready ? self.clock.offset : nil
        }

        beaconSock.onReceive = { [weak self] data, from in
            guard let self, let m = Message.decode(data), m.k == "b", let s = m.s else { return }
            let host = UDPSocket.hostString(from)
            DispatchQueue.main.async {
                let mid = m.mid ?? host, since = m.since ?? 0
                let now = hostNow()
                self.highestSince = max(self.highestSince, since)
                if mid != self.masterID {
                    let newer = since > self.masterSince
                    let silent = now - self.lastBeacon > 1.0
                    guard self.masterID == nil || newer || silent else { return }
                    // Keep playing the current schedule with the offset it is in until the
                    // clock to the new master is known.
                    self.provisional = transport.schedule != nil ? transport.clockOffset() : nil
                    self.adopted = false
                    self.masterID = mid
                    self.masterSince = since
                    self.lock.lock()
                    self.clock.reset()
                    self.generationStart = self.pingID
                    self.lock.unlock()
                }
                self.lastBeacon = now
                self.masterHost = host
                self.masterFile = m.file
                self.masterAddr = UDPSocket.withPort(from, Ports.clock)
                if !self.adopted {
                    self.lock.lock(); let ready = self.clock.ready; self.lock.unlock()
                    if ready { self.adopted = true; self.provisional = nil }
                }
                if self.adopted && transport.schedule != s { transport.schedule = s }
            }
        }
        clockSock.onReceive = { [weak self] data, _ in
            let t4 = hostNow()
            guard let self, let m = Message.decode(data), m.k == "q", let id = m.id,
                  let t1 = m.t1, let t2 = m.t2, let t3 = m.t3 else { return }
            self.lock.lock()
            // Drop late answers from the previous master: their times are in another clock.
            guard id > self.generationStart else { self.lock.unlock(); return }
            self.clock.add(t1: t1, t2: t2, t3: t3, t4: t4)
            self.lock.unlock()
        }
        beaconSock.start(queue: queue)
        clockSock.start(queue: queue)

        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.pingIfDue()
        }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        beaconSock.close(); clockSock.close()
    }

    /// The master's schedule converted to this Mac's clock (to take over as master).
    func localSchedule() -> Schedule? {
        guard var s = transport.schedule, let off = transport.clockOffset() else { return nil }
        s.anchorHost -= off
        return s
    }

    var masterAlive: Bool { masterID != nil && hostNow() - lastBeacon < 1.0 }

    private var tickCount = 0
    private func pingIfDue() {
        guard let addr = masterAddr else { return }
        tickCount += 1
        lock.lock()
        let n = clock.count
        // Fast pings while learning the clock, then every 0.5 s.
        if n >= 40 && tickCount % 5 != 0 { lock.unlock(); return }
        pingID += 1
        let id = pingID
        lock.unlock()
        var m = Message(k: "p")
        m.id = id
        m.dur = transport.longest > 0 ? transport.longest : nil
        m.t1 = hostNow()
        clockSock.send(m.encoded(), to: addr)
    }

    var stats: (offset: Double, rtt: Double, ready: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (clock.offset, clock.rtt, clock.ready)
    }
}
