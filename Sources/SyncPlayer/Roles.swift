import Foundation
import Darwin

/// Master: owns the schedule, answers clock pings, announces the schedule.
/// Any Mac can become master. If it hears a newer master, it steps down (onDemote).
final class Master {
    let node: SyncNode
    let id = UUID().uuidString
    let since = Date().timeIntervalSince1970
    private let sock: UDPSocket          // clock answers + beacon sending
    private let listen: UDPSocket        // hears other masters' beacons
    private var targets: [sockaddr_in]
    private(set) var schedule: Schedule
    private var timer: Timer?
    var onDemote: (() -> Void)?

    /// initial: the schedule to continue (already in this Mac's clock), so taking over is seamless.
    init(node: SyncNode, broadcast: String, extraTargets: [String], initial: Schedule?) throws {
        self.node = node
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
        } else {
            let pos = node.ready ? node.player.currentTime().seconds : 0
            schedule = Schedule(epoch: Int(Date().timeIntervalSince1970), playing: false,
                                anchorHost: hostNow(), anchorMedia: pos.isFinite ? pos : 0)
        }
        node.clockOffset = { 0 }
        node.schedule = schedule

        sock.onReceive = { [weak self] data, from in
            let t2 = hostNow()
            guard let self, let m = Message.decode(data), m.k == "p" else { return }
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
            self?.announce()
        }
        announce()
    }

    func stop() {
        timer?.invalidate(); timer = nil
        sock.close(); listen.close()
    }

    private func announce() {
        var m = Message(k: "b", s: schedule)
        m.mid = id; m.since = since; m.file = node.url.lastPathComponent
        let data = m.encoded()
        for t in targets { sock.send(data, to: t) }
    }

    private func set(_ s: Schedule) {
        schedule = s
        node.schedule = s
        announce()
    }

    /// Current media position by the schedule.
    func position() -> Double { node.expectedMedia(atLocal: hostNow()) ?? 0 }

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
        let d = node.duration
        s.anchorMedia = d > 0 ? min(max(0, media), d - 0.05) : max(0, media)
        s.anchorHost = hostNow() + 0.3
        set(s)
    }

    func jump(by delta: Double) { jump(to: position() + delta) }
}

/// Follower: listens for the master's beacon, measures the clock, plays the schedule.
/// Follows the newest master; switches to another only if that one is newer or the
/// current one has been silent for more than 1 s.
final class Follower {
    let node: SyncNode
    let clock = ClockSync()
    private let beaconSock: UDPSocket
    private let clockSock: UDPSocket
    private var masterAddr: sockaddr_in?
    private(set) var masterHost = "-"
    private(set) var masterID: String?
    private var masterSince: Double = 0
    private(set) var masterFile: String?
    private var lastBeacon: Double = 0
    private var pingID = 0
    private var timer: Timer?
    private let queue = DispatchQueue(label: "follower.net", qos: .userInteractive)
    private let lock = NSLock()

    init(node: SyncNode) throws {
        self.node = node
        beaconSock = try UDPSocket(port: Ports.beacon, reusePort: true)
        clockSock = try UDPSocket(port: 0)
        node.clockOffset = { [weak self] in
            guard let self else { return nil }
            self.lock.lock(); defer { self.lock.unlock() }
            return self.clock.ready ? self.clock.offset : nil
        }

        beaconSock.onReceive = { [weak self] data, from in
            guard let self, let m = Message.decode(data), m.k == "b", let s = m.s else { return }
            let host = UDPSocket.hostString(from)
            DispatchQueue.main.async {
                let mid = m.mid ?? host, since = m.since ?? 0
                let now = hostNow()
                if mid != self.masterID {
                    let newer = since > self.masterSince
                    let silent = now - self.lastBeacon > 1.0
                    guard self.masterID == nil || newer || silent else { return }
                    self.masterID = mid
                    self.masterSince = since
                    self.lock.lock(); self.clock.reset(); self.lock.unlock()
                }
                self.lastBeacon = now
                self.masterHost = host
                self.masterFile = m.file
                self.masterAddr = UDPSocket.withPort(from, Ports.clock)
                if node.schedule != s { node.schedule = s }
            }
        }
        clockSock.onReceive = { [weak self] data, _ in
            let t4 = hostNow()
            guard let self, let m = Message.decode(data), m.k == "q",
                  let t1 = m.t1, let t2 = m.t2, let t3 = m.t3 else { return }
            self.lock.lock()
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
        guard var s = node.schedule, let off = node.clockOffset() else { return nil }
        s.anchorHost -= off
        return s
    }

    var masterAlive: Bool { masterID != nil && hostNow() - lastBeacon < 1.0 }

    private var tickCount = 0
    private func pingIfDue() {
        guard let addr = masterAddr else { return }
        tickCount += 1
        lock.lock(); let n = clock.count; lock.unlock()
        // Fast pings while learning the clock, then every 0.5 s.
        if n >= 40 && tickCount % 5 != 0 { return }
        pingID += 1
        var m = Message(k: "p")
        m.id = pingID
        m.t1 = hostNow()
        clockSock.send(m.encoded(), to: addr)
    }

    var stats: (offset: Double, rtt: Double, ready: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (clock.offset, clock.rtt, clock.ready)
    }
}
