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
    @State private var picking = false
    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            // first layer is at the back
            ForEach(model.layers) { l in
                PlayerView(player: l.player).opacity(l.opacity).ignoresSafeArea()
            }
            if showInfo && !model.seats.isEmpty {
                // big seat name, like N on the Mac
                Text(model.seatName).font(.system(size: 120, weight: .heavy, design: .rounded))
                    .foregroundColor(.white.opacity(0.35)).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(24).allowsHitTesting(false)
            }
            if let t = model.identText {
                // N on the master: shown even when the info panel is hidden (the master decides)
                Text(t).font(.system(size: 56, weight: .bold)).multilineTextAlignment(.center)
                    .foregroundColor(.white).padding(24).background(.black.opacity(0.7)).cornerRadius(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).allowsHitTesting(false)
            }
            if showInfo {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.status).font(.headline)
                    Text(model.detail).font(.caption.monospacedDigit())
                    HStack {
                        Menu {
                            ForEach(model.shows, id: \.self) { u in
                                Button(u.deletingPathExtension().lastPathComponent) { model.openShow(u) }
                            }
                            Button("Import folder…") { picking = true }
                            Button("Refresh") { model.refreshShows() }
                        } label: { Label(model.showTitle, systemImage: "film.stack") }
                        if !model.seats.isEmpty {
                            Menu {
                                ForEach(model.seats, id: \.id) { s in
                                    Button { model.chooseSeat(s.id) } label: {
                                        if s.id == model.seatID { Label(s.name, systemImage: "checkmark") } else { Text(s.name) }
                                    }
                                }
                            } label: { Label("Seat \(model.seatName)", systemImage: "rectangle.on.rectangle") }
                        }
                    }.font(.subheadline)
                    ForEach(Array(model.layerInfo.enumerated()), id: \.offset) { _, t in
                        Text("Layer " + t).font(.caption.monospacedDigit())
                    }
                    Text("SyncFollower \(FollowerModel.version)  (triple-tap: hide)").font(.caption2).opacity(0.7)
                }
                .padding(8).background(.black.opacity(0.6)).cornerRadius(8).padding(12)
            }
        }
        .onTapGesture(count: 3) { showInfo.toggle() }
        .statusBarHidden(true)
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { r in
            if case .success(let u) = r { model.importFolder(u) }
        }
    }
}
