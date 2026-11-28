import Foundation
import AVFoundation
import UIKit

/// iOS follower, stage 2: follows a Mac SyncPlayer master (protocol 1, docs/protocol.md), opens a
/// .syncshow from Documents, is one seat of it (chosen and remembered per show), and plays that seat's
/// first Screen: its layers (order, visible, opacity) and sound. No warp / crop / mask / blend yet.
final class FollowerModel: ObservableObject {
    static let version = "0.2.0-ios"

    struct LayerView: Identifiable { let id: String; let player: AVPlayer; let opacity: Double }

    @Published var status = "Waiting for a master…"
    @Published var detail = ""
    @Published var myIPs = ""
    @Published var shows: [URL] = []
    @Published var showTitle = "Test clip"
    @Published var seats: [ShowFile.Seat] = []
    @Published var seatID = ""
    @Published var layers: [LayerView] = []
    /// One line per layer for the info panel (front first), so the seat's content is visible.
    @Published var layerInfo: [String] = []

    private var show: ShowFile?
    private var nodes: [ClipNode] = []
    private var audioNodeID: String?

    private let beaconSock: UDPSocket
    private let clockSock: UDPSocket
    private let queue = DispatchQueue(label: "follower.net", qos: .userInteractive)
    private let lock = NSLock()
    private var f = FollowerCore()          // guarded by lock
    private var masterAddr: sockaddr_in?    // guarded by lock
    private var timer: Timer?
    private var tick = 0
    private var lastErr = 0.0
    private var maxAbsErr = 0.0
    private var loops = 0
    private var lastCycleIndex = -1
    private var logHandle: FileHandle?
    private var lastLog = 0.0

    var seatName: String { seats.first(where: { $0.id == seatID })?.name ?? "test" }

    init() {
        beaconSock = (try? UDPSocket(port: Ports.beacon, reusePort: true)) ?? { fatalError("beacon port") }()
        clockSock = (try? UDPSocket(port: 0)) ?? { fatalError("clock socket") }()
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        UIApplication.shared.isIdleTimerDisabled = true
        openLog()
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
        refreshShows()
        if let u = UserDefaults.standard.string(forKey: "lastShow"), FileManager.default.fileExists(atPath: u) {
            openShow(URL(fileURLWithPath: u))
        } else if let first = shows.first {
            openShow(first)
        } else {
            openTest()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in self?.step() }
        RunLoop.main.add(timer!, forMode: .common)
    }

    // MARK: shows and seats

    func refreshShows() { shows = ShowFile.scanDocuments() }

    /// Copies a folder picked with the Files app into Documents/shows (so it stays readable) and opens it.
    func importFolder(_ url: URL) {
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let dest = docs.appendingPathComponent("shows").appendingPathComponent(url.lastPathComponent)
        try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: dest)
        do { try fm.copyItem(at: url, to: dest) } catch { status = "Could not copy: \(error.localizedDescription)"; return }
        refreshShows()
        if let sh = ShowFile.scanDocuments().first(where: { $0.path.hasPrefix(dest.path) }) { openShow(sh) }
    }

    private func openTest() {
        show = nil; seats = []; seatID = ""; showTitle = "Test clip"; layerInfo = ["1  test.mp4  100%"]
        guard let url = Bundle.main.url(forResource: "test", withExtension: "mp4") else { return }
        let n = ClipNode(id: "test", url: url, muted: true)
        setNodes([n]); layers = [LayerView(id: "test", player: n.player, opacity: 1)]
    }

    func openShow(_ url: URL) {
        guard let sh = ShowFile.read(url) else { status = "Not a SyncPlayer show: \(url.lastPathComponent)"; return }
        show = sh; showTitle = sh.title; seats = sh.seats
        UserDefaults.standard.set(url.path, forKey: "lastShow")
        var remembered = (UserDefaults.standard.dictionary(forKey: "seats") as? [String: String]) ?? [:]
        let sid = remembered[sh.id].flatMap { id in sh.seats.contains { $0.id == id } ? id : nil } ?? sh.seats[0].id
        remembered[sh.id] = sid
        UserDefaults.standard.set(remembered, forKey: "seats")
        chooseSeat(sid)
    }

    func chooseSeat(_ id: String) {
        guard let sh = show, let seat = sh.seats.first(where: { $0.id == id }) else { return }
        seatID = id
        var remembered = (UserDefaults.standard.dictionary(forKey: "seats") as? [String: String]) ?? [:]
        remembered[sh.id] = id
        UserDefaults.standard.set(remembered, forKey: "seats")
        let out = seat.outputs.first
        let used = (out?.layers ?? []).map(\.clipID)
        var ids: [String] = []
        for c in used + (seat.audioClip.map { [$0] } ?? []) where !ids.contains(c) { ids.append(c) }
        if ids.isEmpty, let c = sh.clips.first { ids = [c.id] }
        // sound: only when the seat has it on, from its audio clip (else its first clip)
        let soundID = (seat.audioOn == true) ? (seat.audioClip ?? ids.first) : nil
        var made: [ClipNode] = []
        var missing: [String] = []
        for cid in ids {
            if let u = sh.clipURL(cid) { made.append(ClipNode(id: cid, url: u, muted: cid != soundID)) }
            else { missing.append(sh.clips.first { $0.id == cid }?.path ?? cid) }
        }
        setNodes(made)
        layers = (out?.layers ?? []).filter(\.visible).compactMap { l in
            made.first { $0.id == l.clipID }.map { LayerView(id: UUID().uuidString, player: $0.player, opacity: l.opacity) }
        }
        let all = out?.layers ?? []
        layerInfo = all.enumerated().reversed().map { i, l in
            let nm = l.name ?? sh.clips.first { $0.id == l.clipID }.map { ($0.path as NSString).lastPathComponent } ?? l.clipID
            return "\(i + 1)  \(nm)  \(Int((l.opacity * 100).rounded()))%" + (l.visible ? "" : "  (hidden)")
        }
        if !missing.isEmpty { status = "Missing movies: " + missing.joined(separator: ", ") }
    }

    private func setNodes(_ n: [ClipNode]) {
        nodes.forEach { $0.player.pause() }
        nodes = n; loops = 0; lastCycleIndex = -1; lastErr = 0
    }

    // MARK: network and following

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
            let ip = String(cString: buf)
            if !ip.hasPrefix("169.254") { out.append(ip) }
        }
        return out
    }

    private func step() {
        let now = hostNow()
        tick += 1
        let longest = nodes.map(\.duration).max() ?? 0
        lock.lock()
        let ping = f.pingDue(now: now, name: UIDevice.current.name, ver: Self.version,
                             errMs: lastErr * 1000, dur: longest, seat: show == nil ? nil : seatName, tick: tick)
        let addr = masterAddr
        let alive = f.masterAlive(now: now)
        let ready = f.clock.ready, offset = f.clock.offset, rtt = f.clock.rtt, count = f.clock.count
        let sched = f.schedule
        let mname = f.masterName ?? f.masterHost
        lock.unlock()
        if let ping, let addr { let s = clockSock; queue.async { s.send(ping.encoded(), to: addr) } }

        guard alive else {
            status = "Waiting for a master…"
            detail = "Tell the Mac master: --to <this device's IP>   IP: \(myIPs)"
            nodes.forEach { $0.idle() }
            return
        }
        guard ready, let s = sched, longest > 0 else {
            status = "Learning the clock from \(mname)…"; detail = "samples \(count)"; return
        }
        let off = { [weak self] () -> Double in
            guard let self else { return 0 }
            self.lock.lock(); defer { self.lock.unlock() }
            return self.f.clock.offset
        }
        for n in nodes { n.follow(s, offset: off, now: now) }
        // worst error among the clips
        lastErr = nodes.map(\.lastErr).max { abs($0) < abs($1) } ?? 0
        let span = (s.cycle ?? 0) > 0 ? s.cycle! : longest
        let idx = Int(s.timeline(local: now, offset: offset) / span)
        if lastCycleIndex >= 0 && idx > lastCycleIndex { loops += 1 }
        lastCycleIndex = idx
        let resyncs = nodes.map(\.resyncs).reduce(0, +)
        status = (s.playing ? "Following " : "Paused by ") + mname + (show == nil ? "" : " — seat \(seatName)")
        detail = String(format: "offset %.3f ms  rtt %.1f ms  err %+.2f ms  resyncs %d  loops %d  clips %d  epoch %d",
                        offset * 1000, rtt * 1000, lastErr * 1000, resyncs, loops, nodes.count, s.epoch)
        writeLog(now: now, offset: offset, rtt: rtt, s: s, resyncs: resyncs)
    }

    // MARK: log

    /// Documents/follow-log.csv, one line per second (new file per launch). Read it from a Mac:
    /// xcrun devicectl device copy from --device <id> --domain-type appDataContainer
    ///   --domain-identifier com.nakayasu.syncfollower --source Documents/follow-log.csv --destination <path>
    private func openLog() {
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let url = dir.appendingPathComponent("follow-log.csv")
        let head = "wall,host,offset_ms,rtt_ms,err_ms,max_abs_err_ms,resyncs,loops,epoch,playing,seat,clips\n"
        try? head.write(to: url, atomically: true, encoding: .utf8)
        logHandle = try? FileHandle(forWritingTo: url)
        _ = logHandle?.seekToEndOfFile()
    }

    private func writeLog(now: Double, offset: Double, rtt: Double, s: Schedule, resyncs: Int) {
        maxAbsErr = max(maxAbsErr, abs(lastErr))
        guard now - lastLog >= 1.0 else { return }
        lastLog = now
        let line = String(format: "%@,%.3f,%.3f,%.2f,%.3f,%.3f,%d,%d,%d,%d,%@,%d\n",
                          ISO8601DateFormatter().string(from: Date()), now, offset * 1000, rtt * 1000,
                          lastErr * 1000, maxAbsErr * 1000, resyncs, loops, s.epoch, s.playing ? 1 : 0,
                          seatName, nodes.count)
        if let d = line.data(using: .utf8) { logHandle?.write(d) }
        maxAbsErr = 0
    }
}
