import Foundation

/// NTP-style clock estimate: offset = master clock - local clock.
/// Keeps recent samples and trusts the one with the shortest round trip.
final class ClockSync {
    private struct Sample { let rtt: Double; let offset: Double; let at: Double }
    private var samples: [Sample] = []
    private(set) var offset: Double = 0
    private(set) var rtt: Double = 0
    var count: Int { samples.count }
    var ready: Bool { samples.count >= 8 }

    func reset() { samples.removeAll(); offset = 0; rtt = 0 }

    /// t1 local send, t2 master receive, t3 master send, t4 local receive.
    func add(t1: Double, t2: Double, t3: Double, t4: Double) {
        let rtt = (t4 - t1) - (t3 - t2)
        let off = ((t2 - t1) + (t3 - t4)) / 2
        guard rtt >= 0, rtt < 0.5 else { return }
        samples.append(Sample(rtt: rtt, offset: off, at: t4))
        if samples.count > 40 { samples.removeFirst(samples.count - 40) }
        // Best = shortest round trip among recent samples (least queueing delay).
        if let best = samples.min(by: { $0.rtt < $1.rtt }) {
            offset = best.offset
            self.rtt = best.rtt
        }
    }
}
