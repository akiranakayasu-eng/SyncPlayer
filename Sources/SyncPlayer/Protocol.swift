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
/// Media position at master time m (while playing) = anchorMedia + (m - anchorHost), wrapped by
/// cycle (the common loop) or, when cycle is nil, by each clip's own length.
struct Schedule: Codable, Equatable {
    var epoch: Int          // bumps on every play / pause / jump
    var playing: Bool
    var anchorHost: Double  // master host seconds
    var anchorMedia: Double // media seconds at anchorHost
    /// Common loop length (s): every clip on every Mac restarts together each cycle; a shorter
    /// clip holds its last frame until then. nil: each clip loops by its own length (v0.2).
    var cycle: Double? = nil
}

struct Message: Codable {
    var k: String           // "b" beacon, "p" ping, "q" pong
    var s: Schedule? = nil
    var id: Int? = nil
    var t1: Double? = nil   // follower send time (follower clock)
    var t2: Double? = nil   // master receive time (master clock)
    var t3: Double? = nil   // master send time (master clock)
    var mid: String? = nil  // master id (beacon)
    var since: Double? = nil // when this master took over (wall clock); the newest master wins
    var file: String? = nil // movie file name the master plays (beacon)
    var dur: Double? = nil  // longest clip of the follower (ping), for the common loop length
    var ident: Bool? = nil  // beacon: every Mac shows its name and screen numbers (N on the master)
    var name: String? = nil // beacon / ping: the sending Mac's name
    var ver: String? = nil  // beacon / ping: the app version ("0.3.3 (abc1234)")
    var err: Double? = nil  // ping: the follower's current offset (ms)
    var warn: String? = nil // ping: the follower's first problem in a few words

    func encoded() -> Data { (try? JSONEncoder().encode(self)) ?? Data() }
    static func decode(_ d: Data) -> Message? { try? JSONDecoder().decode(Message.self, from: d) }
}
