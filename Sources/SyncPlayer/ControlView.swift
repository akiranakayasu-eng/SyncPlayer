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

/// The control window: what is happening and playback on top; outputs, layers and movies on the
/// left; the selected output's preview and the detailed state in the middle; settings on the right
/// in three tabs (adjusting the picture, the exhibition settings of this Mac, presets).
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
                VSplitView {
                    VStack(alignment: .leading, spacing: 4) {
                        if model.showFile == nil { FirstSteps() }
                        Text("プレビュー: \(model.selectedOutputConfig?.name ?? "出力がありません")")
                            .font(.caption).foregroundColor(.secondary)
                        PreviewView(model: model)
                            .frame(minHeight: 160)
                    }
                    .padding(8)
                    .frame(minHeight: 200)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("詳しい状態（映像ごと）・すぐ上の境の線を上へ動かすと広がる")
                            .font(.caption).foregroundColor(.secondary)
                        StatusText(status: status)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .frame(minHeight: 70, idealHeight: 170)
                }
                Divider()
                Inspector(model: model)
                    .frame(width: 320)
            }
        }
        .frame(minWidth: 900, minHeight: 600)
    }
}

/// Shown until the show is saved to a file: the steps from the first movie to an exhibition.
struct FirstSteps: View {
    @AppStorage("firstStepsClosed") private var closed = false
    var body: some View {
        if !closed {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("はじめての手順").font(.headline)
                    Text("1. 左の「出力」で、出すディスプレイを選ぶ（2 枚目のディスプレイは「足す」）")
                    Text("2. 「全画面にする（F）」を入れる")
                    Text("3. 映像を増やすときは「映像を足す…」、並べるときは「4 分割などに並べる」")
                    Text("4. 上の「保存…」でショーを保存する（次から開くと、このまま戻る）")
                }
                Spacer()
                Button("閉じる") { closed = true }.controlSize(.small)
            }
            .font(.callout)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.12)))
        }
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

/// The state of this Mac in words, with a coloured dot.
struct StatusBadge: View {
    @ObservedObject var status: StatusModel
    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(status.tone == 1 ? Color.green : status.tone == 2 ? Color.orange : Color.gray)
                .frame(width: 10, height: 10)
            Text(status.headline.isEmpty ? "準備中" : status.headline)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1).truncationMode(.tail)
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(Capsule().fill(Color.secondary.opacity(0.12)))
        .help("\(status.headline)\n（この Mac がいま何をしているか。緑はそろって再生中、灰色は停止中、橙は確かめること。映像ごとの数字は真ん中の下の「詳しい状態」。「マスター待ち」が続くときは、同じネットワークにつながっているか、マスターの Mac で SyncPlayer が開いているか、初めて開いたときのローカルネットワークの許可を確かめる）")
    }
}

struct TopBar: View {
    @ObservedObject var model: AppModel
    @ObservedObject var status: StatusModel
    @State private var dragging = false
    @State private var value = 0.0
    @State private var jumpText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                StatusBadge(status: status)
                Spacer(minLength: 8)
                Text("この Mac の役").foregroundColor(.secondary)
                Picker("", selection: Binding(get: { model.isMaster }, set: { model.setRoleByHand(master: $0) })) {
                    Text("フォロワー").tag(false)
                    Text("マスター").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 170)
                .help("M キー。マスターが再生を決め、ほかの Mac（フォロワー）は付いてくる。マスターは全台で 1 台だけ")
                Toggle("この Mac で音を出す", isOn: Binding(get: { model.audioOn }, set: { model.setAudio($0) }))
                    .fixedSize()
                    .help("A キー")
                Button("ショーを開く…") { model.openShow() }
                    .help("保存したショー（.syncshow）を開く")
                Button("保存…") { model.saveShowAs() }
                    .help("いまの出力・レイヤー・設定をショーとして保存する")
            }
            HStack(spacing: 10) {
                if status.isMaster {
                    Button { model.master?.jump(to: 0) } label: { Label("頭へ", systemImage: "backward.end.fill") }
                        .help("R キー")
                    Button { model.master?.jump(by: -5) } label: { Label("5 秒戻る", systemImage: "gobackward.5") }
                        .help("← キー")
                    Button { model.master?.togglePlay() } label: {
                        Label(status.playing ? "停止" : "再生", systemImage: status.playing ? "pause.fill" : "play.fill")
                            .frame(minWidth: 56)
                    }
                    .help("space キー。全部の Mac がいっしょに再生・停止する")
                    Button { model.master?.jump(by: 5) } label: { Label("5 秒進む", systemImage: "goforward.5") }
                        .help("→ キー")
                } else {
                    Text("再生・停止と位置の操作は、マスターの Mac で行う")
                        .foregroundColor(.secondary)
                        .help("この Mac をマスターにするときは、上の「この Mac の役」でマスターを選ぶ")
                }

                Text("\(timeString(dragging ? value : status.position)) / \(timeString(status.duration))")
                    .font(.system(size: 12, design: .monospaced))
                    .frame(width: 120)
                    .help("いまの位置 / ループの長さ")
                Slider(value: Binding(get: { dragging ? value : min(status.position, max(0.1, status.duration)) },
                                      set: { value = $0 }),
                       in: 0...max(0.1, status.duration),
                       onEditingChanged: { editing in
                           if editing { dragging = true; value = status.position }
                           else { dragging = false; model.master?.jump(to: value) }
                       })
                    .disabled(!status.isMaster)
                    .help("ドラッグして離すと、全部の Mac がその位置へ")
                if status.isMaster {
                    Text("ここへ飛ぶ").foregroundColor(.secondary)
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
                        .help("分:秒 か 秒を打って Return。全部の Mac がその位置へ")
                }
            }
        }
    }
}

// MARK: left side

struct Sidebar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        // Scrolls when the window is low, so the top bar is never pushed out. The lists are as tall
        // as their rows (they do not scroll themselves), so the wheel moves this column.
        ScrollView {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle("出力（ディスプレイに出す絵）")
            List(selection: $model.selectedOutput) {
                ForEach(model.show.outputs) { o in
                    HStack {
                        Text(o.name)
                        Spacer()
                        Text("ディスプレイ \(o.screen + 1)\(o.fullscreen ? "・全画面" : "")").foregroundColor(.secondary).font(.caption)
                    }
                    .tag(Optional(o.id))
                }
            }
            .frame(height: listHeight(model.show.outputs.count, max: 8))
            HStack {
                Button { model.addOutput() } label: { Label("足す", systemImage: "plus") }.help("出力を足す（別のディスプレイに出すとき）")
                Button { model.removeOutput() } label: { Label("消す", systemImage: "minus") }.help("選んだ出力を消す")
                Spacer()
            }
            .controlSize(.small)
            if model.selectedOutputConfig != nil {
                HStack {
                    Text("名前").foregroundColor(.secondary)
                    TextField("名前", text: model.outputBinding(\.name, ""))
                }
                Picker("", selection: model.outputBinding(\.screen, 0)) {
                    ForEach(screenChoices, id: \.self) { i in
                        Text(i < model.screenShort.count ? model.screenShort[i] : "ディスプレイ \(i + 1)（つながっていない）").tag(i)
                    }
                }
                .labelsHidden()
                .help(model.screenNames.joined(separator: "\n"))
                Toggle("全画面にする（F）", isOn: model.outputBinding(\.fullscreen, false))
                    .help("このディスプレイいっぱいに出す。操作の窓とカーソルはそのディスプレイから消える")
            }

            Divider().padding(.vertical, 2)
            SectionTitle("レイヤー（上が手前）")
            List(selection: $model.selectedLayer) {
                ForEach(Array((model.selectedOutputConfig?.layers ?? []).reversed())) { l in
                    HStack {
                        Toggle("", isOn: model.visibleBinding(l.id)).labelsHidden().help("入れると見える")
                        Text(model.clipName(l.clipID)).lineLimit(1).truncationMode(.middle)
                    }
                    .tag(Optional(l.id))
                }
            }
            .frame(height: listHeight(model.selectedOutputConfig?.layers.count ?? 0, max: 12))
            HStack(spacing: 4) {
                Button { model.addLayer() } label: { Label("足す", systemImage: "plus") }.help("レイヤーを足す")
                Button { model.removeLayer() } label: { Label("消す", systemImage: "minus") }.help("選んだレイヤーを消す")
                Spacer()
            }
            .controlSize(.small)
            HStack(spacing: 4) {
                Button { model.moveLayer(1) } label: { Label("手前へ", systemImage: "arrow.up") }.help("選んだレイヤーを手前へ")
                Button { model.moveLayer(-1) } label: { Label("奥へ", systemImage: "arrow.down") }.help("選んだレイヤーを奥へ")
                Spacer()
            }
            .controlSize(.small)
            Button("4 分割などに並べる") { model.arrangeGrid() }
                .controlSize(.small)
                .fixedSize()
                .help("この出力のレイヤーを、数に合わせて 2×2 などの格子に並べる")

            Divider().padding(.vertical, 2)
            SectionTitle("映像")
            List {
                ForEach(model.show.clips) { c in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.name).lineLimit(1).truncationMode(.middle).help(c.name)
                        HStack(spacing: 4) {
                            Spacer()
                            Button("差し替え") { model.replaceClip(c.id) }
                                .help("別の映像と入れ替える（レイヤーの設定はそのまま）")
                            Button("外す") { model.removeClip(c.id) }
                                .help("この映像と、それを使うレイヤーをショーから外す（確かめてから。ファイルは消えない）")
                        }
                        .controlSize(.small)
                    }
                }
            }
            .frame(height: listHeight(model.show.clips.count, max: 12, row: 46))
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
            .help("この Mac で音を出すとき、どの映像の音を出すか")
        }
        .padding(8)
        }
        .scrollIndicators(.visible)
    }

    /// A list just tall enough for its rows (up to max rows; more scroll inside the list).
    private func listHeight(_ rows: Int, max m: Int, row: CGFloat = 28) -> CGFloat {
        CGFloat(Swift.min(Swift.max(rows, 2), m)) * row + 12
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

/// value → the text shown at the right of a slider, with its unit.
enum ValueText {
    static func percent(_ v: Double) -> String { String(format: "%.0f%%", v * 100) }
    static func signedPercent(_ v: Double) -> String { String(format: "%+.0f%%", v * 100) }
    static func degrees(_ v: Double) -> String { String(format: "%.1f°", v) }
    static func plain(_ v: Double) -> String { String(format: "%.2f", v) }
}

struct SliderRow: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var unit: (Double) -> String = ValueText.plain
    var help = ""

    var body: some View {
        HStack(spacing: 6) {
            Text(label).frame(width: 64, alignment: .leading)
            Slider(value: $value, in: range)
            Text(unit(value))
                .font(.system(size: 11, design: .monospaced))
                .frame(width: 52, alignment: .trailing)
        }
        .help(help)
    }
}

/// A fold's title that opens and closes when the words are clicked too (not only the triangle).
struct FoldLabel: View {
    let title: String
    @Binding var isOpen: Bool
    var warn = false
    var body: some View {
        HStack(spacing: 4) {
            Text(title).font(.subheadline).bold()
            if warn { Text("⚠︎ 読めない").font(.caption).foregroundColor(.red) }
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture { withAnimation { isOpen.toggle() } }
    }
}

struct Inspector: View {
    @ObservedObject var model: AppModel
    @State private var presetName = ""
    /// Opens on 画面の調整 every time (the exhibition settings are touched once, while setting up).
    @State private var tab = 0
    @State private var openPlace = true
    @State private var openCrop = false
    @State private var openMask = false
    @State private var openBlend = false
    @State private var openWarp = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("", selection: $tab) {
                Text("画面の調整").tag(0)
                Text("展示の設定").tag(1)
                Text("プリセット").tag(2)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    switch tab {
                    case 1: exhibitSection
                    case 2: presetSection
                    default:
                        if model.selectedLayerIndex == nil {
                            Text("左の「レイヤー」で 1 つ選ぶと、ここで位置・大きさ・切り取り・マスク・エッジブレンド・四隅を調整できる")
                                .foregroundColor(.secondary)
                        } else {
                            layerSection
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        // Editing corners or the mesh: show where it is controlled.
        .onChange(of: model.editMode) { m in if m != .none { tab = 0; openWarp = true } }
    }

    /// The selected layer's mask is set but missing or unreadable.
    private var maskBroken: Bool {
        guard let p = model.selectedLayerIndex.flatMap({ model.show.outputs[$0.o].layers[$0.l].mask }) else { return false }
        return !FileManager.default.fileExists(atPath: p) || GPU.shared?.maskReady(p) == false
    }

    /// Settings for an exhibition: after a restart the Mac comes back as it was.
    @ViewBuilder private var exhibitSection: some View {
        SectionTitle("いまのこの Mac")
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
            GridRow { Text("名前").foregroundColor(.secondary); Text(model.opts.name) }
            GridRow { Text("役").foregroundColor(.secondary); Text(model.isMaster ? "マスター" : "フォロワー") }
            GridRow { Text("展示のマスター").foregroundColor(.secondary); Text(model.exhibitMaster ? "はい（開くとマスターで始まる）" : "いいえ") }
            GridRow { Text("ログインで開く").foregroundColor(.secondary); Text(model.openAtLogin ? "はい" : "いいえ") }
            GridRow { Text("ショー").foregroundColor(.secondary)
                      Text(model.showFile.map { ($0 as NSString).lastPathComponent } ?? "まだ保存していない").lineLimit(1).truncationMode(.middle) }
        }
        .font(.callout)

        Divider()
        SectionTitle("展示の設定（設営のとき 1 度だけ）")
        Toggle("ログインしたら SyncPlayer を開く", isOn: Binding(get: { model.openAtLogin }, set: { model.openAtLogin = $0 }))
        Text("全台で入れる。再起動のあとログインするだけで、前と同じ全画面・音・マスクに戻る。")
            .font(.caption).foregroundColor(.secondary)
        Toggle("この Mac を展示のマスターにする", isOn: Binding(get: { model.exhibitMaster }, set: { model.setExhibitMaster($0) }))
        Text("全台のうち 1 台だけに入れる。入れるとすぐマスターになり、次から開くとマスターで始まって 3 秒後に自動で再生する。ほかの Mac は何もしなくてもフォロワーになり、どちらが先に開いても数秒でそろう。マスターを開き直すと、全台が頭から始め直す（2〜3 秒止まる）。")
            .font(.caption).foregroundColor(.secondary)

        Divider()
        SectionTitle("確かめる・困ったとき")
        Toggle("名前とディスプレイの番号を大きく出す（N）", isOn: $model.showIdent)
        Text("どの Mac のどのディスプレイかを確かめる。マスターで入れると全台に出る。").font(.caption).foregroundColor(.secondary)
        Toggle("動作確認の文字を出す（I）", isOn: Binding(get: { model.infoShownNow }, set: { model.setInfoShown($0) }))
        Text("出力の窓に、ずれなどの数字を出す。展示中は消しておく。").font(.caption).foregroundColor(.secondary)
        if model.isMaster {
            Button("全台を頭からやり直す（R）") { model.master?.jump(to: 0) }
        }
        Text("1 台だけ映らない・ずれるときは、その Mac で Q キーを押して SyncPlayer を終了し、開き直す（数秒でそろう）。全部止まったときは、展示のマスターの Mac を開き直す。")
            .font(.caption).foregroundColor(.secondary)
    }

    @ViewBuilder private var layerSection: some View {
        SectionTitle("選んだレイヤー")
        Picker("映像", selection: model.layerBinding(\.clipID, "")) {
            ForEach(model.show.clips) { c in Text(c.name).tag(c.id) }
        }
        SliderRow(label: "不透明度", value: model.layerBinding(\.opacity, 1), range: 0...1, unit: ValueText.percent)

        DisclosureGroup(isExpanded: $openPlace) {
            VStack(alignment: .leading, spacing: 6) {
                SliderRow(label: "横の位置", value: model.lookBinding(\.posX, 0), range: -1...1, unit: ValueText.signedPercent,
                          help: "レイヤーの枠（4 分割なら 1 ます）の幅に対する割合。＋で右へ")
                SliderRow(label: "縦の位置", value: model.lookBinding(\.posY, 0), range: -1...1, unit: ValueText.signedPercent,
                          help: "レイヤーの枠の高さに対する割合")
                SliderRow(label: "大きさ", value: model.lookBinding(\.scale, 1), range: 0.1...4, unit: ValueText.percent,
                          help: "100% でレイヤーの枠いっぱい")
                SliderRow(label: "回転", value: model.lookBinding(\.rotation, 0), range: -180...180, unit: ValueText.degrees)
                Button("位置・大きさ・回転を戻す（0）") {
                    guard var s = model.selectedLook else { return }
                    s.resetTransform(); model.updateLook(s)
                }
            }
            .padding(.top, 4)
        } label: { FoldLabel(title: "位置・大きさ・回転", isOpen: $openPlace) }

        DisclosureGroup(isExpanded: $openCrop) {
            VStack(alignment: .leading, spacing: 6) {
                SliderRow(label: "左", value: model.lookBinding(\.cropL, 0), range: 0...0.5, unit: ValueText.percent)
                SliderRow(label: "右", value: model.lookBinding(\.cropR, 0), range: 0...0.5, unit: ValueText.percent)
                SliderRow(label: "上", value: model.lookBinding(\.cropT, 0), range: 0...0.5, unit: ValueText.percent)
                SliderRow(label: "下", value: model.lookBinding(\.cropB, 0), range: 0...0.5, unit: ValueText.percent)
            }
            .padding(.top, 4)
        } label: { FoldLabel(title: "切り取り（映像の端を削る）", isOpen: $openCrop) }

        DisclosureGroup(isExpanded: $openMask) {
            VStack(alignment: .leading, spacing: 6) {
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
            }
            .padding(.top, 4)
        } label: { FoldLabel(title: "マスク（白黒の画像で形を抜く）", isOpen: $openMask, warn: maskBroken) }

        DisclosureGroup(isExpanded: $openBlend) {
            VStack(alignment: .leading, spacing: 6) {
                SliderRow(label: "左", value: model.lookBinding(\.blendL, 0), range: 0...0.5, unit: ValueText.percent)
                SliderRow(label: "右", value: model.lookBinding(\.blendR, 0), range: 0...0.5, unit: ValueText.percent)
                SliderRow(label: "上", value: model.lookBinding(\.blendT, 0), range: 0...0.5, unit: ValueText.percent)
                SliderRow(label: "下", value: model.lookBinding(\.blendB, 0), range: 0...0.5, unit: ValueText.percent)
                SliderRow(label: "ガンマ", value: model.lookBinding(\.blendGamma, 2.2), range: 0.5...4,
                          help: "重なりの明るさの合い方。ふつうは 2.2")
                Text("重なる幅を、画面の幅（高さ）に対する割合で。").font(.caption).foregroundColor(.secondary)
            }
            .padding(.top, 4)
        } label: { FoldLabel(title: "エッジブレンド（プロジェクターの重なり）", isOpen: $openBlend) }

        DisclosureGroup(isExpanded: $openWarp) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Button(model.editMode == .corners ? "四隅の編集を終える" : "四隅を動かす（E）") { model.toggleEdit(.corners) }
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
            .padding(.top, 4)
        } label: { FoldLabel(title: "四隅・曲面（台形や曲がりを直す）", isOpen: $openWarp) }
    }

    private func meshSize(_ d: Int) {
        guard var s = model.selectedLook else { return }
        let n = min(8, max(2, s.meshCols + d))
        guard n != s.meshCols || s.meshRows != n else { return }
        s.setMeshSize(n)
        model.updateLook(s)
    }

    @ViewBuilder private var presetSection: some View {
        SectionTitle("プリセット（ショー全体の配置を名前で残す）")
        HStack {
            TextField("名前", text: $presetName)
            Button("この名前で保存") { model.savePreset(presetName) }
                .disabled(presetName.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        Text("キー: 1〜9 で呼び出し、⌘1〜⌘9 で保存").font(.caption).foregroundColor(.secondary)
        if model.presetNames.isEmpty {
            Text("まだありません").foregroundColor(.secondary)
        }
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
