import Foundation
import CoreMedia

/// Ports. Beacon: master -> everyone (broadcast). Clock: follower <-> master (unicast).
enum Ports {
    static let beacon: UInt16 = 47800
    static let clock: UInt16 = 47801
}

/// Seconds on this Mac's host clock (the same clock AVPlayer's atHostTime uses).
func hostNow() -> Double {
    CMClockGetTime(CMClockGetHostTimeClock()).seconds
}

/// The show state the master announces.
/// Media position at master time m (while playing) = anchorMedia + (m - anchorHost), wrapped by the media length.
struct Schedule: Codable, Equatable {
    var epoch: Int          // bumps on every play / pause / jump
    var playing: Bool
    var anchorHost: Double  // master host seconds
    var anchorMedia: Double // media seconds at anchorHost
}

struct Message: Codable {
    var k: String           // "b" beacon, "p" ping, "q" pong
    var s: Schedule? = nil
    var id: Int? = nil
    var t1: Double? = nil   // follower send time (follower clock)
    var t2: Double? = nil   // master receive time (master clock)
    var t3: Double? = nil   // master send time (master clock)

    func encoded() -> Data { (try? JSONEncoder().encode(self)) ?? Data() }
    static func decode(_ d: Data) -> Message? { try? JSONDecoder().decode(Message.self, from: d) }
}
