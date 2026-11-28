import Foundation
import AVFoundation

/// One clip of the seat: its own AVPlayer, following the schedule (the stage 1 logic, per clip).
final class ClipNode {
    let id: String
    let player = AVPlayer()
    private(set) var duration = 0.0
    var errEMA = 0.0
    private(set) var lastErr = 0.0
    private var servedEpoch = -1
    private var starting = false
    private var settleUntil = 0.0
    private(set) var resyncs = 0

    init(id: String, url: URL, muted: Bool) {
        self.id = id
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        player.isMuted = muted
        player.actionAtItemEnd = .pause
        player.automaticallyWaitsToMinimizeStalling = false
        player.sourceClock = CMClockGetHostTimeClock()
        Task { [weak self] in
            if let d = try? await item.asset.load(.duration).seconds, d.isFinite { self?.duration = d }
        }
    }

    func setMuted(_ m: Bool) { player.isMuted = m }
    private var parked = false
    /// No master: stop, and (once) park on the first frame so the seat's picture is visible.
    func idle() {
        if player.rate != 0 { player.pause() }
        servedEpoch = -1
        if !parked { parked = true; player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) }
    }

    private func pos(_ s: Schedule, _ local: Double, _ offset: Double) -> Double {
        s.clipPosition(timeline: s.timeline(local: local, offset: offset), len: duration)
    }

    func follow(_ s: Schedule, offset: @escaping () -> Double, now: Double) {
        guard duration > 0, !starting else { return }
        let off = offset()
        if !s.playing {
            if servedEpoch != s.epoch || player.rate != 0 {
                servedEpoch = s.epoch; player.pause()
                player.seek(to: CMTime(seconds: pos(s, now, off), preferredTimescale: 90000), toleranceBefore: .zero, toleranceAfter: .zero)
            }
            lastErr = 0
            return
        }
        let target = pos(s, now, off)
        // A clip shorter than the common loop holds its last frame: nothing to follow, so don't re-sync it.
        if target >= duration - 0.002, abs(player.currentTime().seconds - duration) < 0.2 {
            lastErr = 0; errEMA = 0; return
        }
        let needStart = servedEpoch != s.epoch || player.rate == 0
        var err = 0.0
        if !needStart && now > settleUntil {
            err = player.currentTime().seconds - target
            if abs(err) > duration / 2 { err += err > 0 ? -duration : duration }
            errEMA = 0.8 * errEMA + 0.2 * err
            lastErr = err
        }
        if needStart || abs(errEMA) > 0.004 || abs(err) > 0.040 { start(s, offset: offset) }
    }

    private func start(_ s: Schedule, offset: @escaping () -> Double) {
        starting = true
        lastErr = 0; errEMA = 0   // the error before a re-start is stale (it showed as 162 ms for 2 s in the log)
        let epoch = s.epoch
        resyncs += 1
        let first = pos(s, hostNow() + 0.25, offset())
        player.seek(to: CMTime(seconds: first, preferredTimescale: 90000), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                // never earlier than the master's anchor (play/jump put it ~0.3 s ahead); Mac: max(startLocal, anchorHost - off)
                let go = max(hostNow() + 0.1, s.anchorHost - offset())
                let p = self.pos(s, go, offset())
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
