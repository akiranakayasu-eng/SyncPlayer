import SwiftUI
import AVFoundation

struct PlayerView: UIViewRepresentable {
    let player: AVPlayer
    func makeUIView(context: Context) -> UIView {
        let v = LayerView(); v.layer_.player = player; v.layer_.videoGravity = .resizeAspect; return v
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
    final class LayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var layer_: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}

struct ContentView: View {
    @ObservedObject var model: FollowerModel
    @State private var showInfo = true
    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            PlayerView(player: model.player).ignoresSafeArea()
            if showInfo {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.status).font(.headline)
                    Text(model.detail).font(.caption.monospacedDigit())
                    Text("SyncFollower \(FollowerModel.version)").font(.caption2).opacity(0.7)
                }
                .padding(8).background(.black.opacity(0.6)).cornerRadius(8).padding(12)
            }
        }
        .onTapGesture(count: 3) { showInfo.toggle() }   // triple tap: info on/off
        .statusBarHidden(true)
    }
}
