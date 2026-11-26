import AVFoundation
import AVKit
import Combine
import SwiftUI

/// The selected footage's picture with a small player (play, pause, scrub), like the footage
/// thumbnail at the top of After Effects' Project panel (Akira 2026-11-26). Its own player, apart
/// from the show: it does not move the show's time or the other Macs.
///
/// Sound is off unless `sound` is on. Off means the audio tracks are disabled, not just muted, so no
/// AudioQueue is made (muted players running AudioQueues caused the v0.3.3 freeze).
struct ClipPreview: NSViewRepresentable {
    let path: String
    let sound: Bool

    final class Coordinator {
        let player: AVPlayer
        var sound = false
        private var watch: AnyCancellable?

        init(path: String, sound: Bool) {
            let item = AVPlayerItem(url: URL(fileURLWithPath: path))
            player = AVPlayer(playerItem: item)
            player.actionAtItemEnd = .pause
            self.sound = sound
            // Tracks arrive once the item has read the file; set them then, and again on a toggle.
            watch = item.publisher(for: \.tracks).receive(on: DispatchQueue.main).sink { [weak self] _ in self?.applySound() }
            applySound()
        }

        func applySound() {
            guard let item = player.currentItem else { return }
            for t in item.tracks where t.assetTrack?.mediaType == .audio { t.isEnabled = sound }
            player.isMuted = !sound
        }

        func stop() {
            player.pause()
            watch = nil
            player.replaceCurrentItem(with: nil)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(path: path, sound: sound) }

    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = context.coordinator.player
        v.controlsStyle = .inline
        v.showsFullScreenToggleButton = false
        v.showsSharingServiceButton = false
        v.videoGravity = .resizeAspect
        return v
    }

    func updateNSView(_ v: AVPlayerView, context: Context) {
        let c = context.coordinator
        if c.sound != sound { c.sound = sound; c.applySound() }
    }

    static func dismantleNSView(_ v: AVPlayerView, coordinator: Coordinator) {
        v.player = nil
        coordinator.stop()
    }
}

/// While the show plays, the footage preview is one still picture instead of a player: a player
/// beside the show cost about 1000 dropped frames a minute in the Pro test (2026-11-26, 16 clips:
/// 4089 vs 2000 in 4 min, draw 38 vs 55 fps at the lowest). The picture is read once, in the background.
struct ClipStill: View {
    let path: String
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Color.black
            if let image { Image(nsImage: image).resizable().aspectRatio(contentMode: .fit) }
            VStack {
                Spacer()
                Text(L("再生中は静止画（止めるとプレビューできる）", "Still while playing (stop to preview)"))
                    .font(.caption2).foregroundColor(.white.opacity(0.8))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 3))
                    .padding(4)
            }
        }
        .task(id: path) {
            let g = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: path)))
            g.appliesPreferredTrackTransform = true
            g.maximumSize = CGSize(width: 640, height: 640)
            if let cg = try? await g.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image {
                image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }
        }
    }
}
