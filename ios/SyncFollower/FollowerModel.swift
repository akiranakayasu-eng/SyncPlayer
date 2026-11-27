import Foundation
import AVFoundation
import UIKit

/// Stage 1 iOS follower: follows a Mac SyncPlayer master (protocol 1, docs/protocol.md) and plays
/// one bundled movie in step with it. No warp, no seats, simple loop (a short hiccup at the loop
/// point is expected; the Mac's two-player handover is not ported yet).
final class FollowerModel: ObservableObject {
    static let version = "0.1.0-ios"
    let player = AVPlayer()
    @Published var status = "Waiting for a master…"
    @Published var detail = ""
    @Published var myIPs = ""

    private let beaconSock: UDPSocket
    private let clockSock: UDPSocket
    private let queue = DispatchQueue(label: "follower.net", qos: .userInteractive)
    private let lock = NSLock()
    private var f = FollowerCore()          // guarded by lock
    private var masterAddr: sockaddr_in?    // guarded by lock
    private var duration: Double = 0
    private var timer: Timer?
    private var tick = 0

    // playback state (main thread)
    private var servedEpoch = -1
    private var starting = false
    private var settleUntil = 0.0
    private var errEMA = 0.0
    private(set) var lastErr = 0.0
    private var resyncs = 0, loops = 0
    private var lastCycleStart = -1.0

    init() {
        beaconSock = (try? UDPSocket(port: Ports.beacon, reusePort: true)) ?? { fatalError("beacon port") }()
        clockSock = (try? UDPSocket(port: 0)) ?? { fatalError("clock socket") }()
        if let url = Bundle.main.url(forResource: "test", withExtension: "mp4") {
            let item = AVPlayerItem(url: url)
            player.replaceCurrentItem(with: item)
            player.isMuted = true
            player.actionAtItemEnd = .pause
            player.automaticallyWaitsToMinimizeStalling = false
            player.sourceClock = CMClockGetHostTimeClock()
            Task { [weak self] in
                if let d = try? await item.asset.load(.duration).seconds, d.isFinite { self?.duration = d }
            }
        }
        UIApplication.shared.isIdleTimerDisabled = true
        beaconSock.onReceive = { [weak self] data, from in
            guard let self, let m = Message.decode(data), m.k == "b" else { return }
            let host = UDPSocket.hostString(from), now = hostNow()
            self.lock.lock()
            self.f.onBeacon(m, from: host, now: now)
            self.masterAddr = UDPSocket.withPort(from, Ports.clock)
            self.lock.unlock()
        }
        clockSock.onReceive = { [weak self] data, _ in
            let t4 = hostNow()
            guard let self, let m = Message.decode(data), m.k == "q" else { return }
            self.lock.lock(); self.f.onPong(m, t4: t4); self.lock.unlock()
        }
        beaconSock.start(queue: queue)
        clockSock.start(queue: queue)
        myIPs = Self.localIPs().joined(separator: "  ")
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in self?.step() }
        RunLoop.main.add(timer!, forMode: .common)
    }

    static func localIPs() -> [String] {
        var out: [String] = []
        var ifa: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifa) == 0, let first = ifa else { return out }
        defer { freeifaddrs(ifa) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let a = p.pointee.ifa_addr, a.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: p.pointee.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(a, socklen_t(a.pointee.sa_len), &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST)
            out.append(String(cString: buf))
        }
        return out
    }

    private func step() {
        let now = hostNow()
        tick += 1
        // pings (every tick while learning, then every 5th: 0.25 s)
        lock.lock()
        let ping = f.pingDue(now: now, name: UIDevice.current.name, ver: Self.version,
                             errMs: lastErr * 1000, dur: duration, tick: tick)
        let addr = masterAddr
        let alive = f.masterAlive(now: now)
        let ready = f.clock.ready, offset = f.clock.offset, rtt = f.clock.rtt
        let sched = f.schedule
        let mname = f.masterName ?? f.masterHost
        lock.unlock()
        if let ping, let addr { let s = clockSock; queue.async { s.send(ping.encoded(), to: addr) } }

        guard alive else {
            status = "Waiting for a master…"; detail = "Tell the Mac master: --to <this device's IP>   IP: \(myIPs)"
            if player.rate != 0 { player.pause() }
            servedEpoch = -1
            return
        }
        guard ready, let s = sched, duration > 0 else {
            status = "Learning the clock from \(mname)…"; detail = "samples \(f.clock.count)"; return
        }
        status = (s.playing ? "Following " : "Paused by ") + mname
        detail = String(format: "offset %.3f ms  rtt %.1f ms  err %+.2f ms  resyncs %d  loops %d  epoch %d",
                        offset * 1000, rtt * 1000, lastErr * 1000, resyncs, loops, s.epoch)
        follow(s, offset: offset, now: now)
    }

    /// Position inside the clip for a local time.
    private func clipPos(_ s: Schedule, _ local: Double, _ offset: Double) -> Double {
        s.clipPosition(timeline: s.timeline(local: local, offset: offset), len: duration)
    }

    private func follow(_ s: Schedule, offset: Double, now: Double) {
        if starting { return }
        if !s.playing {
            if servedEpoch != s.epoch || player.rate != 0 {
                servedEpoch = s.epoch; player.pause()
                player.seek(to: CMTime(seconds: clipPos(s, now, offset), preferredTimescale: 90000),
                            toleranceBefore: .zero, toleranceAfter: .zero)
            }
            return
        }
        let target = clipPos(s, now, offset)
        // The master's times are in its clock; a start time to the local host clock is "local".
        let needStart = servedEpoch != s.epoch || player.rate == 0
        var err = 0.0
        if !needStart && now > settleUntil {
            let have = player.currentTime().seconds
            err = have - target
            // across a loop point the two positions are a clip length apart
            if abs(err) > duration / 2 { err += err > 0 ? -duration : duration }
            errEMA = 0.8 * errEMA + 0.2 * err
            lastErr = err
        }
        if needStart || abs(errEMA) > 0.004 || abs(err) > 0.040 { start(s, offset: offset) }
    }

    private func start(_ s: Schedule, offset: Double) {
        starting = true
        let epoch = s.epoch
        let lead = 0.25
        let at = hostNow() + lead
        let pos = clipPos(s, at, offset)
        resyncs += 1
        _ = pos
        player.seek(to: CMTime(seconds: pos, preferredTimescale: 90000), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                // Seeking took time: compute the position for the real start moment.
                self.lock.lock(); let off = self.f.clock.offset; self.lock.unlock()
                let go = hostNow() + 0.1
                let p = self.clipPos(s, go, off)
                self.player.setRate(1.0, time: CMTime(seconds: p, preferredTimescale: 90000),
                                    atHostTime: CMTime(seconds: go, preferredTimescale: 1_000_000_000))
                self.servedEpoch = epoch
                self.settleUntil = go + 0.6
                self.errEMA = 0
                self.starting = false
            }
        }
    }
}
