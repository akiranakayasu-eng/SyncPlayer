import Foundation
import Darwin

/// Master: owns the schedule, answers clock pings, announces the schedule.
final class Master {
    let node: SyncNode
    private let sock: UDPSocket
    private var targets: [sockaddr_in]
    private(set) var schedule: Schedule
    private var timer: Timer?

    init(node: SyncNode, broadcast: String, extraTargets: [String]) throws {
        self.node = node
        sock = try UDPSocket(port: Ports.clock, broadcast: true)
        targets = [UDPSocket.address(broadcast, Ports.beacon),
                   UDPSocket.address("127.0.0.1", Ports.beacon)]   // followers on this Mac
        targets += extraTargets.map { UDPSocket.address($0, Ports.beacon) }
        schedule = Schedule(epoch: 1, playing: false, anchorHost: hostNow(), anchorMedia: 0)
        node.schedule = schedule
        node.clockOffset = { 0 }

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

        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.announce()
        }
    }

    private func announce() {
        let data = Message(k: "b", s: schedule).encoded()
        for t in targets { sock.send(data, to: t) }
    }

    private func set(_ s: Schedule) {
        schedule = s
        node.schedule = s
        announce()
    }

    /// Current media position by the schedule.
    private func position() -> Double { node.expectedMedia(atLocal: hostNow()) ?? 0 }

    func togglePlay() {
        var s = schedule
        s.epoch += 1
        if s.playing {
            s.anchorMedia = position()
            s.anchorHost = hostNow()
            s.playing = false
        } else {
            s.anchorMedia = position()
            s.anchorHost = hostNow() + 0.3   // give every follower time to hear it
            s.playing = true
        }
        set(s)
    }

    func jump(to media: Double) {
        var s = schedule
        s.epoch += 1
        s.anchorMedia = max(0, media)
        s.anchorHost = hostNow() + 0.3
        set(s)
    }

    func jump(by delta: Double) { jump(to: position() + delta) }
}

/// Follower: listens for the master's beacon, measures the clock, plays the schedule.
final class Follower {
    let node: SyncNode
    let clock = ClockSync()
    private let beaconSock: UDPSocket
    private let clockSock: UDPSocket
    private var masterAddr: sockaddr_in?
    private(set) var masterHost = "-"
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
                // The same master can arrive by two routes (broadcast and 127.0.0.1).
                // Switch only when the current master has been silent for more than 1 s.
                let now = hostNow()
                if host != self.masterHost && now - self.lastBeacon < 1.0 { return }
                self.lastBeacon = now
                if host != self.masterHost {       // new master: start the clock over
                    self.masterHost = host
                    self.masterAddr = UDPSocket.withPort(from, Ports.clock)
                    self.lock.lock(); self.clock.reset(); self.lock.unlock()
                }
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
