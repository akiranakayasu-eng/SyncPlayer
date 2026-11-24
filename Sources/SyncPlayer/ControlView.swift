import SwiftUI
import AppKit

/// "1:23.5", "0:01:23" or "83.5" → seconds.
func parseTime(_ text: String) -> Double? {
    let half = text.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? text   // １：２３．５ too
    let parts = half.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "：", with: ":")
        .split(separator: ":", omittingEmptySubsequences: false).map { Double($0.trimmingCharacters(in: .whitespaces)) }
    guard !parts.isEmpty, parts.count <= 3, parts.allSatisfy({ $0 != nil && $0! >= 0 && $0!.isFinite }) else { return nil }
    return parts.reduce(0.0) { $0 * 60 + $1! }
}

func timeString(_ t: Double) -> String {
    let t = max(0, t.isFinite ? t : 0)
    let m = Int(t) / 60
    return String(format: "%d:%04.1f", m, t - Double(m * 60))
}

/// The control window: playback on top; outputs, layers and movies on the left; the selected
/// output's preview in the middle; the selected layer's settings on the right.
struct ControlView: View {
    @ObservedObject var model: AppModel
    let status: StatusModel

    var body: some View {
        VStack(spacing: 0) {
            TopBar(model: model, status: status)
                .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            HStack(spacing: 0) {
                Sidebar(model: model)
                    .frame(width: 250)
                Divider()
                VStack(spacing: 6) {
                    PreviewView(model: model)
                        .frame(minHeight: 220)
                    StatusText(status: status)
                        .frame(height: 120)
                }
                .padding(8)
                Divider()
                Inspector(model: model)
                    .frame(width: 320)
            }
        }
        .frame(minWidth: 900, minHeight: 600)
    }
}

struct StatusText: View {
    @ObservedObject var status: StatusModel
    var body: some View {
        ScrollView {
            Text(status.text)
                .font(.system(size: 11, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }
}

// MARK: top bar

struct TopBar: View {
    @ObservedObject var model: AppModel
    @ObservedObject var status: StatusModel
    @State private var dragging = false
    @State private var value = 0.0
    @State private var jumpText = ""

    var body: some View {
        HStack(spacing: 10) {
            Picker("", selection: Binding(get: { model.isMaster }, set: { model.setRoleByUser(master: $0) })) {
                Text("フォロワー").tag(false)
                Text("マスター").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 180)
            .help("M キー。マスターが再生を決め、ほかの Mac は付いてくる")

            Group {
                Button { model.master?.jump(to: 0) } label: { Image(systemName: "backward.end.fill") }
                    .help("頭へ（R）")
                Button { model.master?.jump(by: -5) } label: { Image(systemName: "gobackward.5") }
                    .help("5 秒戻る（←）")
                Button { model.master?.togglePlay() } label: {
                    Image(systemName: status.playing ? "pause.fill" : "play.fill").frame(width: 20)
                }
                .help("再生／停止（space）")
                Button { model.master?.jump(by: 5) } label: { Image(systemName: "goforward.5") }
                    .help("5 秒進む（→）")
            }
            .disabled(!status.isMaster)

            Text("\(timeString(dragging ? value : status.position)) / \(timeString(status.duration))")
                .font(.system(size: 12, design: .monospaced))
                .frame(width: 120)
            Slider(value: Binding(get: { dragging ? value : min(status.position, max(0.1, status.duration)) },
                                  set: { value = $0 }),
                   in: 0...max(0.1, status.duration),
                   onEditingChanged: { editing in
                       if editing { dragging = true; value = status.position }
                       else { dragging = false; model.master?.jump(to: value) }
                   })
                .disabled(!status.isMaster)
            TextField("0:00.0", text: $jumpText)
                .frame(width: 64)
                .onSubmit {
                    if let t = parseTime(jumpText) {
                        model.master?.jump(to: t)
                        if status.duration > 0, t >= status.duration {
                            model.notify("尺（\(timeString(status.duration))）を超えたので、ループの中の位置へ折り返しました")
                        }
                    } else {
                        model.notify("位置は 1:23.5 か 83.5 の形で")
                    }
                    // Leave the field, so space and the arrows work again at once.
                    DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) }
                }
                .disabled(!status.isMaster)
                .help("位置を打って Return: 全台がその位置へ（分:秒 か 秒）")

            Toggle("音", isOn: Binding(get: { model.audioOn }, set: { model.setAudio($0) }))
                .help("A キー。この Mac で音を出すか")
            Button("ショーを開く…") { model.openShow() }
            Button("保存…") { model.saveShowAs() }
        }
    }
}

// MARK: left side

struct Sidebar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle("出力（画面）")
            List(selection: $model.selectedOutput) {
                ForEach(model.show.outputs) { o in
                    HStack {
                        Text(o.name)
                        Spacer()
                        Text("画面 \(o.screen + 1)\(o.fullscreen ? "・全" : "")").foregroundColor(.secondary).font(.caption)
                    }
                    .tag(Optional(o.id))
                }
            }
            .frame(height: 96)
            HStack {
                Button { model.addOutput() } label: { Image(systemName: "plus") }.help("出力を足す")
                Button { model.removeOutput() } label: { Image(systemName: "minus") }.help("選んだ出力を消す")
                Spacer()
            }
            if model.selectedOutputConfig != nil {
                TextField("名前", text: model.outputBinding(\.name, ""))
                Picker("画面", selection: model.outputBinding(\.screen, 0)) {
                    ForEach(screenChoices, id: \.self) { i in
                        Text(i < model.screenNames.count ? model.screenNames[i] : "\(i + 1):（つながっていない）").tag(i)
                    }
                }
                Toggle("全画面（F）", isOn: model.outputBinding(\.fullscreen, false))
            }

            Divider().padding(.vertical, 2)
            SectionTitle("レイヤー（上が手前）")
            List(selection: $model.selectedLayer) {
                ForEach(Array((model.selectedOutputConfig?.layers ?? []).reversed())) { l in
                    HStack {
                        Toggle("", isOn: model.visibleBinding(l.id)).labelsHidden()
                        Text(model.clipName(l.clipID)).lineLimit(1).truncationMode(.middle)
                    }
                    .tag(Optional(l.id))
                }
            }
            .frame(minHeight: 96)
            HStack {
                Button { model.addLayer() } label: { Image(systemName: "plus") }.help("レイヤーを足す")
                Button { model.removeLayer() } label: { Image(systemName: "minus") }.help("選んだレイヤーを消す")
                Button { model.moveLayer(1) } label: { Image(systemName: "arrow.up") }.help("手前へ")
                Button { model.moveLayer(-1) } label: { Image(systemName: "arrow.down") }.help("奥へ")
                Spacer()
                Button("格子に並べる") { model.arrangeGrid() }.help("この出力のレイヤーを 2×2 などに並べる")
            }

            Divider().padding(.vertical, 2)
            SectionTitle("映像")
            List {
                ForEach(model.show.clips) { c in
                    HStack {
                        Text(c.name).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button { model.replaceClip(c.id) } label: { Image(systemName: "arrow.triangle.2.circlepath") }
                            .buttonStyle(.borderless).help("別の映像と入れ替える")
                        Button { model.removeClip(c.id) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).help("この映像と、それを使うレイヤーを消す")
                    }
                }
            }
            .frame(minHeight: 80)
            HStack {
                Button("映像を足す…") { model.addClips() }
                Spacer()
            }
            Toggle("全部いっしょにループ", isOn: Binding(get: { model.show.loopTogether },
                                                    set: { v in if model.show.loopTogether != v { model.show.loopTogether = v } }))
                .help("すべての Mac の映像が同じ長さで頭へ戻る。短い映像は最後のコマで待つ（マスターの設定が使われる）")
            if model.show.loopTogether {
                HStack {
                    Text("長さ")
                    TextField("自動", value: Binding(get: { model.show.loopLength },
                                                   set: { v in let x = v <= 0 ? 0 : max(v, Show.minLoop)
                                                          if model.show.loopLength != x { model.show.loopLength = x } }),
                              format: .number)
                        .frame(width: 70)
                    Text("秒（0 = いちばん長い映像）").font(.caption).foregroundColor(.secondary)
                }
            }
            Picker("音を出す映像", selection: Binding(get: { model.show.audioClip ?? model.show.clips.first?.id ?? "" },
                                                 set: { model.setAudioClip($0) })) {
                ForEach(model.show.clips) { c in Text(c.name).tag(c.id) }
            }
        }
        .padding(8)
    }

    private var screenChoices: [Int] {
        let n = max(model.screenNames.count, (model.selectedOutputConfig?.screen ?? 0) + 1)
        return Array(0..<n)
    }
}

struct SectionTitle: View {
    let text: String
    init(_ t: String) { text = t }
    var body: some View { Text(text).font(.headline) }
}

// MARK: preview

struct PreviewView: NSViewRepresentable {
    let model: AppModel
    func makeNSView(context: Context) -> NSView { model.previewBox ?? NSView() }
    func updateNSView(_ v: NSView, context: Context) {}
}

// MARK: right side

struct SliderRow: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var format = "%.2f"

    var body: some View {
        HStack(spacing: 6) {
            Text(label).frame(width: 64, alignment: .leading)
            Slider(value: $value, in: range)
            Text(String(format: format, value))
                .font(.system(size: 11, design: .monospaced))
                .frame(width: 48, alignment: .trailing)
        }
    }
}

struct Inspector: View {
    @ObservedObject var model: AppModel
    @State private var presetName = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                exhibitSection
                Divider()
                if model.selectedLayerIndex == nil {
                    Text("レイヤーを選んでください").foregroundColor(.secondary)
                } else {
                    layerSection
                }
                Divider()
                presetSection
            }
            .padding(10)
        }
    }

    /// Settings for an exhibition: after a restart the Mac comes back as it was.
    @ViewBuilder private var exhibitSection: some View {
        SectionTitle("展示（この Mac）")
        Toggle("名前とディスプレイの番号を大きく出す（N）", isOn: $model.showIdent)
            .help("設営のとき用。マスターで入れると全台に出る")
        Toggle("動作確認の文字を出す（I）", isOn: Binding(get: { model.infoShownNow }, set: { model.setInfoShown($0) }))
        Toggle("ログインしたら SyncPlayer を開く", isOn: Binding(get: { model.openAtLogin }, set: { model.openAtLogin = $0 }))
        Toggle("この Mac はマスターで始める", isOn: Binding(get: { model.show.startAsMaster ?? false },
                                                    set: { model.setRoleByUser(master: $0) }))
        Toggle("開いたらすぐ再生（マスター）", isOn: Binding(get: { model.show.autoPlay }, set: { model.show.autoPlay = $0 }))
        Text("ショーの全画面・音・マスクなどは、開くと前のまま戻る。再起動のあと電源を入れてログインするだけで、前と同じ展示の状態になる。マスターとフォロワーはどちらが先に開いても数秒でそろう。「マスターで始める」は全台のうち 1 台だけに入れる。")
            .font(.caption).foregroundColor(.secondary)
    }

    @ViewBuilder private var layerSection: some View {
        SectionTitle("選んだレイヤー")
        Picker("映像", selection: model.layerBinding(\.clipID, "")) {
            ForEach(model.show.clips) { c in Text(c.name).tag(c.id) }
        }
        SliderRow(label: "不透明度", value: model.layerBinding(\.opacity, 1), range: 0...1)

        Text("位置・大きさ・回転").font(.subheadline).bold()
        SliderRow(label: "横", value: model.lookBinding(\.posX, 0), range: -1...1)
        SliderRow(label: "縦", value: model.lookBinding(\.posY, 0), range: -1...1)
        SliderRow(label: "大きさ", value: model.lookBinding(\.scale, 1), range: 0.1...4)
        SliderRow(label: "回転", value: model.lookBinding(\.rotation, 0), range: -180...180, format: "%.1f°")
        Button("位置・大きさ・回転を戻す（0）") {
            guard var s = model.selectedLook else { return }
            s.resetTransform(); model.updateLook(s)
        }

        Text("切り取り").font(.subheadline).bold()
        SliderRow(label: "左", value: model.lookBinding(\.cropL, 0), range: 0...0.5)
        SliderRow(label: "右", value: model.lookBinding(\.cropR, 0), range: 0...0.5)
        SliderRow(label: "上", value: model.lookBinding(\.cropT, 0), range: 0...0.5)
        SliderRow(label: "下", value: model.lookBinding(\.cropB, 0), range: 0...0.5)

        Text("マスク").font(.subheadline).bold()
        HStack {
            Button("画像を選ぶ…") { model.pickMask() }
            Button("外す") { model.layerBinding(\.mask, nil as String?).wrappedValue = nil }
                .disabled(model.selectedLayerIndex.map { model.show.outputs[$0.o].layers[$0.l].mask == nil } ?? true)
        }
        let maskPath = model.selectedLayerIndex.flatMap { model.show.outputs[$0.o].layers[$0.l].mask }
        let maskOK = maskPath.map { FileManager.default.fileExists(atPath: $0) && GPU.shared?.maskReady($0) != false } ?? true
        Text(maskPath.map { ($0 as NSString).lastPathComponent + (maskOK ? "" : "（見つからない・読めない）") } ?? "なし")
            .font(.caption).foregroundColor(maskOK ? .secondary : .red)
        Toggle("白黒を入れ替える", isOn: model.layerBinding(\.maskInvert, false))
        Text("白は見え、黒は隠れる（灰色は半分）。画像は映像の枠全体に重なり、レイヤーといっしょに動く。映像と同じ縦横比の画像にする。")
            .font(.caption).foregroundColor(.secondary)

        Text("エッジブレンド").font(.subheadline).bold()
        SliderRow(label: "左", value: model.lookBinding(\.blendL, 0), range: 0...0.5)
        SliderRow(label: "右", value: model.lookBinding(\.blendR, 0), range: 0...0.5)
        SliderRow(label: "上", value: model.lookBinding(\.blendT, 0), range: 0...0.5)
        SliderRow(label: "下", value: model.lookBinding(\.blendB, 0), range: 0...0.5)
        SliderRow(label: "ガンマ", value: model.lookBinding(\.blendGamma, 2.2), range: 0.5...4)

        Text("変形").font(.subheadline).bold()
        HStack {
            Button(model.editMode == .corners ? "四隅の編集を終える" : "四隅（E）") { model.toggleEdit(.corners) }
            Button(model.editMode == .mesh ? "曲面の編集を終える" : "曲面メッシュ（W）") { model.toggleEdit(.mesh) }
        }
        Stepper("メッシュの点 \(model.selectedLook?.meshCols ?? 4)×\(model.selectedLook?.meshRows ?? 4)",
                onIncrement: { meshSize(+1) }, onDecrement: { meshSize(-1) })
        HStack {
            Button("四隅を戻す") { guard var s = model.selectedLook else { return }; s.resetCorners(); model.updateLook(s) }
            Button("メッシュを戻す") { guard var s = model.selectedLook else { return }; s.resetMesh(); model.updateLook(s) }
        }
        Toggle("確認用の格子（G）", isOn: model.lookBinding(\.showGrid, false))
        Text("点はプレビューか出力の窓でドラッグ。Tab で次の点、矢印で 1 px（shift で 10 px）。")
            .font(.caption).foregroundColor(.secondary)
    }

    private func meshSize(_ d: Int) {
        guard var s = model.selectedLook else { return }
        let n = min(8, max(2, s.meshCols + d))
        guard n != s.meshCols || s.meshRows != n else { return }
        s.setMeshSize(n)
        model.updateLook(s)
    }

    @ViewBuilder private var presetSection: some View {
        SectionTitle("プリセット（ショー全体）")
        HStack {
            TextField("名前", text: $presetName)
            Button("この名前で保存") { model.savePreset(presetName) }
                .disabled(presetName.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        Text("キー: 1〜9 で呼び出し、⌘1〜⌘9 で保存").font(.caption).foregroundColor(.secondary)
        ForEach(model.presetNames, id: \.self) { n in
            HStack {
                Text(n).bold(n == model.lastPreset)
                Spacer()
                Button("読み込む") { model.loadPreset(n) }
                Button("消す") { model.deletePreset(n) }
            }
        }
    }
}
