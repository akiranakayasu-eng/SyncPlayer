import Foundation

/// All clips of the show on one timeline. One SyncNode per clip, all following the same
/// schedule and clock offset. The timeline is not wrapped: each clip wraps it by the common loop
/// length (schedule.cycle) or, without one, by its own length.
final class Transport {
    private(set) var nodes: [String: SyncNode] = [:]
    private(set) var frames: [String: FrameSource] = [:]
    private var paths: [String: String] = [:]
    private(set) var order: [String] = []

    var schedule: Schedule? {
        didSet { for n in nodes.values { n.schedule = schedule } }
    }
    /// master clock - local clock, nil while unknown. Every node asks this.
    var clockOffset: () -> Double? = { 0 }

    /// Make the nodes match the clips. Unchanged clips keep playing.
    func setClips(_ clips: [Clip]) {
        let want = Dictionary(clips.map { ($0.id, $0.path) }, uniquingKeysWith: { a, _ in a })
        for (id, n) in nodes where want[id] != paths[id] {
            n.stop()
            nodes[id] = nil; frames[id] = nil; paths[id] = nil
        }
        for c in clips where nodes[c.id] == nil {
            let n = SyncNode(url: URL(fileURLWithPath: c.path), muted: true)
            n.clockOffset = { [weak self] in self?.clockOffset() }
            n.schedule = schedule
            nodes[c.id] = n
            frames[c.id] = FrameSource(node: n)
            paths[c.id] = c.path
        }
        order = clips.map(\.id)
    }

    var orderedNodes: [(id: String, node: SyncNode)] { order.compactMap { id in nodes[id].map { (id, $0) } } }

    /// The longest clip: its length is the length shown, and the one jumps are measured by.
    var primary: SyncNode? { orderedNodes.map(\.node).max { $0.duration < $1.duration } }
    /// Length of this Mac's longest clip.
    var longest: Double { primary?.duration ?? 0 }
    /// Length of one loop: the common loop length from the master, else the longest clip.
    var duration: Double {
        if let c = schedule?.cycle, c > 0 { return c }
        return longest
    }
    var ready: Bool { nodes.values.contains { $0.ready } }

    func tick() { for n in nodes.values { n.tick() } }

    /// Timeline position (not wrapped) at a local host time.
    func timeline(atLocal h: Double) -> Double? {
        guard let s = schedule, let off = clockOffset() else { return nil }
        if !s.playing { return s.anchorMedia }
        return s.anchorMedia + max(0, h + off - s.anchorHost)
    }

    /// Position to show, wrapped by the longest clip.
    func displayTime() -> Double {
        guard let t = timeline(atLocal: hostNow()) else { return 0 }
        let d = duration
        return d > 0 ? t.truncatingRemainder(dividingBy: d) : t
    }

    /// Where the pictures are now (for a new master that has no schedule yet).
    func currentPosition() -> Double {
        guard let p = primary, p.ready else { return 0 }
        let t = p.position
        return t.isFinite ? t : 0
    }

    func setAudio(clipID: String?, on: Bool) {
        for (id, n) in nodes { n.setMuted(!(on && id == clipID)) }
    }

    func stopAll() {
        for n in nodes.values { n.stop() }
    }

    /// Largest current error among the clips that are playing (s).
    var maxError: Double {
        nodes.values.filter(\.ready).map(\.lastError).max { abs($0) < abs($1) } ?? 0
    }
    var resyncCount: Int { nodes.values.map(\.resyncCount).reduce(0, +) }
    /// Loop starts over all clips that used the early-read player, and ones that did not (check 71 L1).
    var warmStarts: Int { nodes.values.map(\.warmStarts).reduce(0, +) }
    var coldStarts: Int { nodes.values.map(\.coldStarts).reduce(0, +) }
    /// Counters (jumps, loops, dropped frames) back to 0; nothing about playback changes.
    func resetCounts() {
        nodes.values.forEach { $0.resetCounts() }
        frames.values.forEach { $0.resetCounts() }
    }
}
