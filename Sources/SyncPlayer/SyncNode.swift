import Foundation
import AVFoundation
import QuartzCore
import CoreVideo

/// One playback machine. The master runs this too (with clock offset 0).
/// It follows a Schedule: start at a precise host time on the host clock, then watch the
/// media position and re-schedule the start if it drifts more than a few ms.
///
/// Two players take turns so the loop point has no gap: about a second before the end,
/// the idle player is scheduled to start at 0 exactly at the loop's host time, and the
/// renderer switches to its frames at that moment.
final class SyncNode {
    let players: [AVPlayer]
    let items: [AVPlayerItem]
    /// Frames for the Metal renderer (one per player).
    /// Added once the movie's format is known (the frame layout follows it), empty until then.
    private(set) var outputs: [AVPlayerItemVideoOutput] = []
    let url: URL
    private(set) var active = 0
    var player: AVPlayer { players[active] }
    var item: AVPlayerItem { items[active] }

    private(set) var duration: Double = 0
    /// Length of one frame (s), 0 until known.
    private(set) var frameDuration: Double = 0
    private(set) var videoSize = CGSize.zero
    var schedule: Schedule?
    /// master clock - local clock, nil while unknown.
    var clockOffset: () -> Double? = { 0 }

    // Tuning
    let lead = 0.12            // seconds ahead when (re)starting
    /// Re-schedule when the smoothed error passes this (s). Writing AVPlayer.rate makes it
    /// hiccup ~10 ms each time, so the rate is never changed; a re-scheduled start lands within ~0.3 ms.
    let softLimit = 0.004
    let hardLimit = 0.040      // re-schedule at once on a single error this large
    let armAhead = 1.0         // schedule the idle player this long before the loop point

    private var activeEpoch = -1
    private var needsResync = true
    /// After a scheduled start, do not judge the error until the start has really happened.
    private var settleUntil: Double = 0
    /// Host time (local) at which the idle player has been scheduled to start, if any.
    private var armedAt: Double?
    private(set) var errorEMA: Double = 0
    private(set) var resyncCount = 0
    private(set) var loopCount = 0
    private(set) var lastError: Double = 0
    private var endObservers: [NSObjectProtocol] = []

    init(url: URL, muted: Bool) {
        self.url = url
        var ps: [AVPlayer] = [], its: [AVPlayerItem] = []
        for _ in 0..<2 {
            let it = AVPlayerItem(url: url)
            let p = AVPlayer(playerItem: it)
            p.automaticallyWaitsToMinimizeStalling = false
            p.actionAtItemEnd = .pause
            p.isMuted = muted
            // Run playback on the host clock (the same clock the schedule uses), not the audio
            // device clock. Otherwise every player slowly drifts from the schedule (~1 ms / 90 s on Air).
            p.sourceClock = CMClockGetHostTimeClock()
            ps.append(p); its.append(it)
        }
        players = ps; items = its

        Task { @MainActor in
            var subtype: FourCharCode? = nil
            if let track = try? await its[0].asset.loadTracks(withMediaType: .video).first {
                let fps = (try? await track.load(.nominalFrameRate)) ?? 0
                if fps > 0 { self.frameDuration = 1 / Double(fps) }
                if let sz = try? await track.load(.naturalSize) { self.videoSize = sz }
                if let f = (try? await track.load(.formatDescriptions))?.first { subtype = CMFormatDescriptionGetMediaSubType(f) }
            }
            // Preferred layout first; the others in case this Mac cannot deliver it.
            // (macOS picks among them; the format that arrived is shown in the status and log.)
            var fmts = [FrameFormat.pixelFormat(forCodec: subtype)]
            if !FrameFormat.bgra {   // --bgra: BGRA only, so the comparison is real
                for f in [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_32BGRA] where !fmts.contains(f) {
                    fmts.append(f)
                }
            }
            self.outputs = its.map { it in
                let out = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: fmts.map { NSNumber(value: $0) },
                    kCVPixelBufferMetalCompatibilityKey as String: true])
                it.add(out)
                return out
            }
            // An output added later gets frames once the position moves: show the current one now.
            for p in self.players { p.seek(to: p.currentTime(), toleranceBefore: .zero, toleranceAfter: .zero) }
            // Ready (duration > 0) only once the outputs exist.
            self.duration = (try? await its[0].asset.load(.duration))?.seconds ?? 0
        }
        for (i, it) in its.enumerated() {
            endObservers.append(NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime, object: it, queue: .main) { [weak self] _ in
                guard let self else { return }
                // If the other player is armed, the swap handles the loop. Otherwise restart on schedule.
                if i == self.active && self.armedAt == nil { self.needsResync = true }
            })
        }
    }

    var ready: Bool { items.allSatisfy { $0.status == .readyToPlay } && duration > 0 }

    /// Length of one loop. With a common loop (schedule.cycle, set by the master) every clip on
    /// every Mac restarts together; a shorter clip holds its last frame until then.
    /// Without it each clip loops by its own length.
    var period: Double {
        if let c = schedule?.cycle, c > 0 { return c }
        return duration
    }

    private func phase(_ t: Double) -> Double {
        let p = period
        guard p > 0 else { return t }
        let r = t.truncatingRemainder(dividingBy: p)
        return r < 0 ? r + p : r
    }

    /// Position in the current loop at a local host time (may be past the clip's end: holding).
    func loopPosition(atLocal h: Double) -> Double? {
        guard let s = schedule, let off = clockOffset() else { return nil }
        if !s.playing { return phase(s.anchorMedia) }
        // Before the scheduled start the media waits at the anchor.
        return phase(s.anchorMedia + max(0, h + off - s.anchorHost))
    }

    /// Where the media should be at a local host time.
    func expectedMedia(atLocal h: Double) -> Double? {
        loopPosition(atLocal: h).map { min($0, duration) }
    }

    /// At (or within the last frames before) the clip's end: the last frame is shown until the next loop.
    private func holding(_ pos: Double) -> Bool { pos >= duration - 0.05 }

    private var endTime: CMTime { CMTime(seconds: max(0, duration - 0.001), preferredTimescale: 600_000) }

    /// Which player's frames to show at a local host time. The armed player takes over exactly
    /// at the loop point, not at the next 20 Hz tick (the old one is frozen on its last frame).
    func displayIndex(atLocal h: Double) -> Int {
        if let at = armedAt, h >= at { return 1 - active }
        return active
    }

    /// Schedule the idle player to start at 0 at the loop point (local host time).
    private func arm(loopAt at: Double) {
        players[1 - active].setRate(1.0, time: .zero,
                                    atHostTime: CMTime(seconds: at, preferredTimescale: 1_000_000_000))
        armedAt = at
    }

    private func disarm() {
        if armedAt != nil { players[1 - active].pause() }
        armedAt = nil
    }

    func stop() {
        disarm()
        players.forEach { $0.pause() }
        endObservers.forEach { NotificationCenter.default.removeObserver($0) }
        endObservers = []
    }

    func setMuted(_ m: Bool) { players.forEach { $0.isMuted = m } }

    func tick() {
        guard ready, let s = schedule, clockOffset() != nil else { return }
        if s.epoch != activeEpoch { activeEpoch = s.epoch; needsResync = true }

        if !s.playing {
            disarm()
            if player.rate != 0 { player.pause() }
            if needsResync {
                needsResync = false
                let pos = loopPosition(atLocal: hostNow()) ?? 0
                player.seek(to: holding(pos) ? endTime : CMTime(seconds: pos, preferredTimescale: 600),
                            toleranceBefore: .zero, toleranceAfter: .zero)
            }
            return
        }

        if needsResync { resync(); return }
        let now = hostNow()

        // Loop: hand over to the armed player once its start time has passed.
        if let at = armedAt, now >= at + 0.005 {
            let old = active
            active = 1 - active
            players[old].pause()
            armedAt = nil
            loopCount += 1
            settleUntil = now + 0.1
            errorEMA = 0
            return
        }

        if now < settleUntil { return }          // the scheduled start is still ahead
        guard let pos = loopPosition(atLocal: now) else { return }

        // Arm the idle player to start at 0 exactly at the next loop point.
        let remaining = period - pos
        if armedAt == nil && remaining < armAhead && remaining > 0.03 { arm(loopAt: now + remaining) }

        // Holding the last frame until the loop point: nothing to correct.
        if holding(pos) { lastError = 0; return }
        if player.rate == 0 {
            if armedAt == nil { resync() } else { lastError = 0 }   // held on the last frame, next one armed
            return
        }

        // Compare with where the media should be at the moment it was read (reading takes time;
        // comparing with the tick's start would bias the error positive).
        let t0 = hostNow()
        let actual = player.currentTime().seconds
        let t1 = hostNow()
        guard let want = loopPosition(atLocal: (t0 + t1) / 2), !holding(want) else { return }
        var err = actual - want
        if duration > 0 {   // shortest way around the loop point
            if err > duration / 2 { err -= duration }
            if err < -duration / 2 { err += duration }
        }
        lastError = err
        errorEMA = errorEMA * 0.8 + err * 0.2

        if armedAt == nil && (abs(err) > hardLimit || abs(errorEMA) > softLimit) {
            resync()
        }
    }

    /// Start (or restart) exactly on schedule: at local host time now+lead, at the media time
    /// the schedule says for that moment.
    func resync() {
        disarm()
        var startLocal = hostNow() + lead
        // If the schedule starts later than that (play / jump announce ~0.3 s ahead),
        // start exactly at the scheduled moment instead of playing early.
        if let s = schedule, let off = clockOffset() { startLocal = max(startLocal, s.anchorHost - off) }
        guard let pos = loopPosition(atLocal: startLocal) else { return }
        needsResync = false
        errorEMA = 0
        if holding(pos) {
            // Show the last frame until the loop point. Not counted as a jump: a shorter clip
            // does this every loop. Arm the other player now if the loop point is close
            // (tick() would be too late), otherwise tick() arms it.
            player.pause()
            player.seek(to: endTime, toleranceBefore: .zero, toleranceAfter: .zero)
            let at = startLocal + (period - pos), ahead = at - hostNow()
            if ahead > 0.03 && ahead < armAhead + lead { arm(loopAt: at) }
            settleUntil = hostNow()
            return
        }
        resyncCount += 1
        settleUntil = startLocal + 0.1
        // Near the end: tick() waits until settleUntil, which may be past the loop point, so arm now.
        let at = startLocal + (period - pos), ahead = at - hostNow()
        if ahead > 0.03 && ahead < armAhead + lead + 0.1 { arm(loopAt: at) }
        player.setRate(1.0,
                       time: CMTime(seconds: pos, preferredTimescale: 600_000),
                       atHostTime: CMTime(seconds: startLocal, preferredTimescale: 1_000_000_000))
    }
}
