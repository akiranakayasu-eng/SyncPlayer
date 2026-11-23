import Foundation
import AVFoundation

/// One playback machine. The master runs this too (with clock offset 0).
/// It follows a Schedule: start at a precise host time, then keep the media position
/// on target by nudging the playback rate, and jump if it drifts too far.
final class SyncNode {
    let player: AVPlayer
    let item: AVPlayerItem
    private(set) var duration: Double = 0
    var schedule: Schedule?
    /// master clock - local clock, nil while unknown.
    var clockOffset: () -> Double? = { 0 }

    // Tuning
    let lead = 0.12            // seconds ahead when (re)starting
    let hardLimit = 0.040      // jump when off by more than this (s)
    let gain = 0.5             // rate correction per second of error
    let maxRateDelta = 0.01    // at most ±1% speed change

    private var activeEpoch = -1
    private var needsResync = true
    /// After a scheduled start, do not judge the error until the start has really happened.
    private var settleUntil: Double = 0
    private(set) var errorEMA: Double = 0
    private(set) var resyncCount = 0
    private(set) var lastError: Double = 0
    private var endObserver: NSObjectProtocol?

    init(url: URL, muted: Bool) {
        item = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = false
        player.actionAtItemEnd = .pause
        player.isMuted = muted
        Task { @MainActor in
            let d = (try? await item.asset.load(.duration))?.seconds ?? 0
            self.duration = d
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            self?.needsResync = true   // loop: restart on the schedule
        }
    }

    var ready: Bool { item.status == .readyToPlay && duration > 0 }

    private func wrap(_ t: Double) -> Double {
        guard duration > 0 else { return t }
        let r = t.truncatingRemainder(dividingBy: duration)
        return r < 0 ? r + duration : r
    }

    /// Where the media should be at a local host time.
    func expectedMedia(atLocal h: Double) -> Double? {
        guard let s = schedule, let off = clockOffset() else { return nil }
        if !s.playing { return wrap(s.anchorMedia) }
        let m = h + off
        return wrap(s.anchorMedia + (m - s.anchorHost))
    }

    func tick() {
        guard ready, let s = schedule, clockOffset() != nil else { return }
        if s.epoch != activeEpoch { activeEpoch = s.epoch; needsResync = true }

        if !s.playing {
            if player.rate != 0 { player.pause() }
            if needsResync {
                needsResync = false
                player.seek(to: CMTime(seconds: wrap(s.anchorMedia), preferredTimescale: 600),
                            toleranceBefore: .zero, toleranceAfter: .zero)
            }
            return
        }

        if needsResync { resync(); return }
        let now = hostNow()
        if now < settleUntil { return }          // the scheduled start is still ahead
        if player.rate == 0 { resync(); return }

        guard let expected = expectedMedia(atLocal: now) else { return }
        let actual = player.currentTime().seconds
        var err = actual - expected
        if duration > 0 {   // shortest way around the loop point
            if err > duration / 2 { err -= duration }
            if err < -duration / 2 { err += duration }
        }
        lastError = err
        errorEMA = errorEMA * 0.8 + err * 0.2

        if abs(err) > hardLimit {
            resync()
            return
        }
        // Ahead (err > 0) -> slow down a little, behind -> speed up.
        let delta = max(-maxRateDelta, min(maxRateDelta, -errorEMA * gain))
        let rate = Float(1.0 + delta)
        // Small threshold: a 20 s drift of 0.3 ms needs a rate change of only ~0.00002.
        if abs(player.rate - rate) > 0.00001 { player.rate = rate }
    }

    /// Start (or restart) exactly on schedule: at local host time now+lead, at the media time
    /// the schedule says for that moment.
    func resync() {
        let startLocal = hostNow() + lead
        guard let media = expectedMedia(atLocal: startLocal) else { return }
        // Do not start in the last frames; the end-of-item handler will loop.
        let target = media > duration - 0.02 ? 0 : media
        needsResync = false
        resyncCount += 1
        settleUntil = startLocal + 0.1
        errorEMA = 0
        player.setRate(1.0,
                       time: CMTime(seconds: target, preferredTimescale: 600_000),
                       atHostTime: CMTime(seconds: startLocal, preferredTimescale: 1_000_000_000))
    }
}
