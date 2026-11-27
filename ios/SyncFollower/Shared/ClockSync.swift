import Foundation

/// NTP-style clock estimate: offset = master clock - local clock.
/// Keeps about a minute of samples and averages the ones with the shortest round trips.
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
        // Keep about a minute of samples (pings every 0.5 s once settled).
        if samples.count > 120 { samples.removeFirst(samples.count - 120) }
        // Average the offsets of the 5 shortest round trips. Taking only the single best one
        // made the offset step by 3–8 ms over a relayed internet link whenever it aged out.
        let best = samples.sorted { $0.rtt < $1.rtt }.prefix(5)
        offset = best.map(\.offset).reduce(0, +) / Double(best.count)
        self.rtt = best.first?.rtt ?? 0
    }
}
