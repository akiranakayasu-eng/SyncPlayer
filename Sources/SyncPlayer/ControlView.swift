import SwiftUI
import AppKit

/// "1:23.5", "0:01:23" or "83.5" → seconds.
func parseTime(_ text: String) -> Double? {
    let half = text.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? text   // １：２３．５ too
    // Digits only read like an After Effects timecode, from the right: the last two are 1/100 s,
    // the two before them seconds, the rest minutes. "200" = 2 s, "1550" = 15.5 s, "10000" = 1:00.
    let digits = half.trimmingCharacters(in: .whitespaces)
    if !digits.isEmpty, digits.count <= 8, digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber), let n = Int(digits) {
        return Double(n / 10000) * 60 + Double((n / 100) % 100) + Double(n % 100) / 100
    }
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
    @AppStorage("ui.sidebarWidth") private var sidebarWidth: Double = 250

    var body: some View {
        VStack(spacing: 0) {
            TopBar(model: model, status: status)
                .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            HStack(spacing: 0) {
                Sidebar(model: model)
                    .frame(width: sidebarWidth)
                // Drag the line to widen or narrow the left column (kept per Mac).
                WidthHandle(width: $sidebarWidth, range: 200...520)
                VSplitView {
                    VStack(alignment: .leading, spacing: 4) {
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
    @State private var editingTime = false
    @State private var editingLoop = false
    @State private var loopText = ""
    @FocusState private var loopFocused: Bool

    /// Loop length typed in the time display: turns on "loop together" with that length (0 = auto).
    private func setLoopTyped(_ text: String) {
        guard let t = parseTime(text) else { model.notify("長さは 2000（20 秒）や 1:30 の形で"); leaveField(); return }
        let x = t <= 0 ? 0 : max(t, Show.minLoop)
        var s = model.show
        s.loopTogether = true
        s.loopLength = x
        if s != model.show { model.show = s }
        model.notify(x == 0 ? "ループの長さ: いちばん長い映像に合わせる" : "ループの長さ: \(timeString(x))")
        leaveField()
    }
    @State private var timeText = ""
    @FocusState private var timeFocused: Bool

    private func leaveField() {
        // Leave the field, so space and the arrows work again at once.
        DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) }
    }

    private func jumpTyped(_ text: String) {
        if let t = parseTime(text) {
            model.master?.jump(to: t)
            if status.duration > 0, t >= status.duration {
                model.notify("尺（\(timeString(status.duration))）を超えたので、ループの中の位置へ折り返しました")
            }
        } else {
            model.notify("位置は 200（2 秒）や 1:23.5 の形で")
        }
        leaveField()
    }

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
                // Which movie's sound, right beside the switch (Akira 2026-11-25).
                Picker("", selection: Binding(get: { model.show.audioClip ?? model.show.clips.first?.id ?? "" },
                                              set: { model.setAudioClip($0) })) {
                    ForEach(model.show.clips) { c in Text(c.name).tag(c.id) }
                }
                .labelsHidden()
                .frame(maxWidth: 160)
                .disabled(!model.audioOn)
                .help("音を出す映像（この Mac で音を出すとき、どの映像の音を出すか）")
                Button("ショーを開く…") { model.openShow() }
                    .help("保存したショー（.syncshow）を開く")
                Button("保存…") { model.saveShowAs() }
                    .help("いまの出力・レイヤー・設定をショーとして保存する")
            }
            HStack(spacing: 10) {
                if status.isMaster {
                    Button { model.master?.jump(to: 0) } label: { Label("頭へ", systemImage: "backward.end.fill") }
                        .help("R か ↑ キー")
                    Button { model.master?.jump(by: -5) } label: { Label("5 秒戻る", systemImage: "gobackward.5") }
                        .help("5 秒戻る（← で 1 コマ、shift+← で 1 秒）")
                    Button { model.master?.togglePlay() } label: {
                        Label(status.playing ? "停止" : "再生", systemImage: status.playing ? "pause.fill" : "play.fill")
                            .frame(minWidth: 56)
                    }
                    .help("space キー。全部の Mac がいっしょに再生・停止する")
                    Button { model.master?.jump(by: 5) } label: { Label("5 秒進む", systemImage: "goforward.5") }
                        .help("5 秒進む（→ で 1 コマ、shift+→ で 1 秒）")
                } else {
                    Text("再生・停止と位置の操作は、マスターの Mac で行う")
                        .foregroundColor(.secondary)
                        .help("この Mac をマスターにするときは、上の「この Mac の役」でマスターを選ぶ")
                        .frame(minHeight: 24)
                }

                HStack(spacing: 0) {
                    if editingTime {
                        TextField("", text: $timeText)
                            .font(.system(size: 12, design: .monospaced))
                            .multilineTextAlignment(.trailing)
                            .frame(width: 56)
                            .focused($timeFocused)
                            .onSubmit { jumpTyped(timeText); editingTime = false }
                            .onExitCommand { editingTime = false; leaveField() }
                            .onChange(of: timeFocused) { f in if !f { editingTime = false } }
                            .onAppear { timeFocused = true }
                    } else {
                        Text(timeString(dragging ? value : status.position))
                            .font(.system(size: 12, design: .monospaced))
                            .frame(width: 56, alignment: .trailing)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                guard status.isMaster else { return }
                                timeText = timeString(status.position); editingTime = true
                            }
                            .help(status.isMaster ? "押すと位置を打てる。After Effects のように数字だけなら右から 1/100 秒・秒・分（200 で 2 秒、10000 で 1 分）。1:23.5 の形でもよい。Return で全部の Mac がその位置へ" : "いまの位置")
                    }
                    Text(" / ").font(.system(size: 12, design: .monospaced))
                    if editingLoop {
                        TextField("", text: $loopText)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(width: 56)
                            .focused($loopFocused)
                            .onSubmit { setLoopTyped(loopText); editingLoop = false }
                            .onExitCommand { editingLoop = false; leaveField() }
                            .onChange(of: loopFocused) { f in if !f { editingLoop = false } }
                            .onAppear { loopFocused = true }
                    } else {
                        Text(timeString(status.duration))
                            .font(.system(size: 12, design: .monospaced))
                            .contentShape(Rectangle())
                            .onTapGesture {
                                guard status.isMaster else { return }
                                loopText = timeString(status.duration); editingLoop = true
                            }
                            .help(status.isMaster ? "ループの長さ。押すと打てる（200 で 2 秒、1:30 で 1 分 30 秒。0 でいちばん長い映像の長さ）。全部の Mac がこの長さで頭へ戻る" : "ループの長さ（マスターの Mac で変える）")
                    }
                }
                .frame(minWidth: 120)
                Slider(value: Binding(get: { dragging ? value : min(status.position, max(0.1, status.duration)) },
                                      set: { value = $0 }),
                       in: 0...max(0.1, status.duration),
                       onEditingChanged: { editing in
                           if editing { dragging = true; value = status.position }
                           else { dragging = false; model.master?.jump(to: value) }
                       })
                    .disabled(!status.isMaster)
                    .help("ドラッグして離すと、全部の Mac がその位置へ")
                // Next to the loop length it governs (Akira 2026-11-25: up here, not at the bottom of the left column).
                Toggle("全部いっしょにループ", isOn: Binding(get: { model.show.loopTogether },
                                                        set: { v in if model.show.loopTogether != v { model.show.loopTogether = v } }))
                    .toggleStyle(.checkbox)
                    .fixedSize()
                    .help("入れると、すべての Mac の映像が同じ長さ（左の / のあとの時刻。押すと打てる）で頭へ戻る。短い映像は最後のコマで待つ。切ると映像ごとに自分の長さでループする（マスターの設定が使われる）")
            }
        }
    }
}

// MARK: left side

struct Sidebar: View {
    @ObservedObject var model: AppModel
    @State private var selectedClip: String?


    var body: some View {
        // Scrolls when the window is low, so the top bar is never pushed out. The lists are as tall
        // as their rows (they do not scroll themselves), so the wheel moves this column.
        ScrollView {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle("出力（ディスプレイに出す絵）", help: "outputs")
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
            ListBar {
                IconButton("plus", "出力を足す（別のディスプレイに出すとき）") { model.addOutput() }
                IconButton("minus", "選んだ出力を消す") { model.removeOutput() }
            }
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
            SectionTitle("レイヤー（上が手前、ドラッグで入れ替え）", help: "layers")
            List(selection: $model.selectedLayer) {
                // Numbered from the front (1 = frontmost, like After Effects). Drag a row to change
                // the order, like the tracks in Premiere.
                ForEach(Array((model.selectedOutputConfig?.layers ?? []).reversed().enumerated()), id: \.element.id) { k, l in
                    HStack {
                        Text("\(k + 1)").font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary)
                            .frame(minWidth: 16, alignment: .trailing)
                        Toggle("", isOn: model.visibleBinding(l.id)).labelsHidden().help("入れると見える")
                        LayerClipButton(model: model, layerID: l.id, clipID: l.clipID)
                    }
                    .tag(Optional(l.id))
                    // Drop a movie from the movie list below onto a layer to show it there.
                    .dropDestination(for: String.self) { ids, _ in
                        guard let id = ids.first, id.hasPrefix(ClipDrag.prefix) else { return false }
                        model.setLayerClip(l.id, String(id.dropFirst(ClipDrag.prefix.count)))
                        return true
                    }
                    .help("ドラッグで順番を入れ替える（上が手前）")
                }
                .onMove { model.moveLayers(fromDisplayed: $0, toDisplayed: $1) }
            }
            .frame(height: listHeight(model.selectedOutputConfig?.layers.count ?? 0, max: 12))
            // One row of small icon buttons under the list, like the + − bar under macOS lists.
            ListBar {
                IconButton("plus", "レイヤーを足す") { model.addLayer() }
                IconButton("minus", "選んだレイヤーを消す") { model.removeLayer() }
                Divider().frame(height: 14)
                IconButton("arrow.up", "選んだレイヤーを手前へ（ドラッグでも入れ替えられる）") { model.moveLayer(1) }
                IconButton("arrow.down", "選んだレイヤーを奥へ") { model.moveLayer(-1) }
                Divider().frame(height: 14)
                IconButton("square.grid.2x2", "4 分割などに並べる: この出力のレイヤーを、数に合わせて 2×2 などの格子に並べる") { model.arrangeGrid() }
            }

            Divider().padding(.vertical, 2)
            SectionTitle("映像", help: "clips")
            // One line per movie (the list was 2 lines a movie and made the column long). Replace and
            // remove act on the selected movie, like the layer buttons.
            List(selection: $selectedClip) {
                ForEach(model.show.clips) { c in
                    HStack(spacing: 4) {
                        if model.clipBroken(c.id) {
                            Text("⚠︎ 開けない").font(.caption).foregroundColor(.red)
                        }
                        Text(c.name).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 4)
                        // Replace and remove as small icons on the same line (Akira 2026-11-25).
                        Button { model.replaceClip(c.id) } label: { Image(systemName: "arrow.triangle.2.circlepath") }
                            .buttonStyle(.borderless)
                            .help("差し替え: 別の映像と入れ替える（レイヤーの設定はそのまま）")
                        Button { model.removeClip(c.id) } label: { Image(systemName: "xmark.circle") }
                            .buttonStyle(.borderless)
                            .help("外す: この映像と、それを使うレイヤーをショーから外す（確かめてから。ファイルは消えない）")
                    }
                    .tag(Optional(c.id))
                    .help("\(c.name)\nレイヤーの行へドラッグすると、そのレイヤーの映像になる")
                    .draggable(ClipDrag.prefix + c.id)
                }
            }
            .frame(height: listHeight(model.show.clips.count, max: 6))
            ListBar {
                IconButton("plus", "映像を足す…（ファイルを選ぶ）") { model.addClips() }
            }
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

/// A vertical line that can be dragged sideways to change the width of the column on its left.
struct WidthHandle: View {
    @Binding var width: Double
    let range: ClosedRange<Double>
    @State private var start: Double?
    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .padding(.horizontal, 3)
            .contentShape(Rectangle())
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { g in
                    if start == nil { start = width }
                    width = min(max((start ?? width) + g.translation.width, range.lowerBound), range.upperBound)
                }
                .onEnded { _ in start = nil })
            .help("ドラッグして左の欄の幅を変える")
    }
}

/// A movie dragged from the movie list (a plain string, so other text drops are told apart).
enum ClipDrag { static let prefix = "syncplayer-clip:" }

/// The movie name in a layer row. Clicking it opens a small chooser beside the row: the show's
/// movies (the current one ticked) and "add from a file". Nothing else on screen moves.
struct LayerClipButton: View {
    @ObservedObject var model: AppModel
    let layerID: String
    let clipID: String
    @State private var open = false

    var body: some View {
        Button { open = true } label: {
            HStack(spacing: 2) {
                Text(model.clipName(clipID)).lineLimit(1).truncationMode(.middle)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8)).foregroundColor(.secondary)
            }
        }
        .buttonStyle(.plain)
        .help("押すと、このレイヤーに出す映像を選べる（下の映像の行をドラッグしてきても替わる）")
        .popover(isPresented: $open, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 0) {
                Text("このレイヤーに出す映像").font(.caption).foregroundColor(.secondary)
                    .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 4)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(model.show.clips) { c in
                            Button {
                                model.setLayerClip(layerID, c.id); open = false
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "checkmark").opacity(c.id == clipID ? 1 : 0)
                                    Text(c.name).lineLimit(1).truncationMode(.middle)
                                    if model.clipBroken(c.id) { Text("⚠︎").foregroundColor(.red) }
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                                .padding(.horizontal, 10).padding(.vertical, 4)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 320)
                Divider()
                Button { open = false; model.addClipsForLayer(layerID) } label: {
                    Label("ファイルから選ぶ…", systemImage: "plus").padding(.horizontal, 10).padding(.vertical, 6)
                }
                .buttonStyle(.plain)
            }
            .frame(width: 260)
        }
    }
}

/// The row of small buttons under a list.
struct ListBar<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        HStack(spacing: 2) { content; Spacer() }
            .controlSize(.small)
            .padding(.top, -2)
    }
}

/// A small icon-only button; the words are in the tooltip.
struct IconButton: View {
    let icon: String
    let help: String
    let action: () -> Void
    init(_ icon: String, _ help: String, action: @escaping () -> Void) { self.icon = icon; self.help = help; self.action = action }
    var body: some View {
        Button(action: action) { Image(systemName: icon).frame(width: 18, height: 14) }
            .buttonStyle(.bordered)
            .help(help)
    }
}

struct SectionTitle: View {
    let text: String
    let help: String?
    init(_ t: String, help: String? = nil) { text = t; self.help = help }
    var body: some View {
        HStack(spacing: 4) {
            Text(text).font(.headline)
            if let h = help { HelpButton(anchor: h) }
        }
    }
}

/// "?" next to a title: opens that part of the manual in the browser.
struct HelpButton: View {
    let anchor: String
    var body: some View {
        Button { AppModel.openManual(anchor) } label: { Image(systemName: "questionmark.circle") }
            .buttonStyle(.borderless)
            .help("使い方のページのこの部分を開く")
    }
}

// MARK: preview

struct PreviewView: NSViewRepresentable {
    let model: AppModel
    func makeNSView(context: Context) -> NSView { model.previewBox ?? NSView() }
    func updateNSView(_ v: NSView, context: Context) {}
}

// MARK: right side

/// How a slider's value is shown and typed: shown = value * scale, with the suffix.
struct ValueUnit {
    let scale: Double
    let digits: Int
    let suffix: String
    var signed = false
    func text(_ v: Double) -> String {
        String(format: signed ? "%+.\(digits)f" : "%.\(digits)f", v * scale) + suffix
    }
    /// Typed text → value ("50", "50%", "+12.5", full-width digits too). Nil when not a number.
    func parse(_ t: String) -> Double? {
        var h = t.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? t
        for x in ["%", "°", "+", " "] { h = h.replacingOccurrences(of: x, with: "") }
        h = h.replacingOccurrences(of: "−", with: "-")
        guard let n = Double(h), n.isFinite else { return nil }
        return n / scale
    }
}

/// The units the sliders use.
enum ValueText {
    static let percent = ValueUnit(scale: 100, digits: 0, suffix: "%")
    static let signedPercent = ValueUnit(scale: 100, digits: 0, suffix: "%", signed: true)
    static let degrees = ValueUnit(scale: 1, digits: 1, suffix: "°")
    static let plain = ValueUnit(scale: 1, digits: 2, suffix: "")
}

/// A slider with its value. Like After Effects: click the number to type a value (Return to set,
/// esc to cancel), and the ↺ button (or a double-click on the name) puts the default back.
struct SliderRow: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var defaultValue: Double? = nil
    var unit: ValueUnit = ValueText.plain
    var help = ""

    @State private var editing = false
    @State private var text = ""
    @FocusState private var focused: Bool

    private var atDefault: Bool { defaultValue.map { abs(value - $0) < 1e-9 } ?? true }

    var body: some View {
        HStack(spacing: 6) {
            Text(label).frame(width: 64, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { reset() }
            Slider(value: $value, in: range)
            if editing {
                TextField("", text: $text)
                    .font(.system(size: 11, design: .monospaced))
                    .multilineTextAlignment(.trailing)
                    .frame(width: 52)
                    .focused($focused)
                    .onSubmit { commit() }
                    .onExitCommand { editing = false }
                    .onChange(of: focused) { f in if !f && editing { commit() } }
                    .onAppear { focused = true }
            } else {
                Text(unit.text(value))
                    .font(.system(size: 11, design: .monospaced))
                    .frame(width: 52, alignment: .trailing)
                    .contentShape(Rectangle())
                    .onTapGesture { text = unit.text(value); editing = true }
                    .help("押すと数字を打てる（Return で決める、esc でやめる）")
            }
            if defaultValue != nil {
                Button { reset() } label: { Image(systemName: "arrow.counterclockwise") }
                    .buttonStyle(.borderless)
                    .disabled(atDefault)
                    .opacity(atDefault ? 0.3 : 1)
                    .help("最初の値（\(unit.text(defaultValue ?? 0))）に戻す。名前のダブルクリックでも戻る")
            }
        }
        .help(help)
    }

    private func reset() { if let d = defaultValue { value = d } }

    private func commit() {
        editing = false
        if let v = unit.parse(text) { value = min(max(v, range.lowerBound), range.upperBound) }
        // Leave the field so the keys (space, arrows) work again at once.
        DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) }
    }
}

/// A fold's title that opens and closes when the words are clicked too (not only the triangle).
struct FoldLabel: View {
    let title: String
    @Binding var isOpen: Bool
    var warn = false
    var help: String? = nil
    var body: some View {
        HStack(spacing: 4) {
            Text(title).font(.subheadline).bold()
            if warn { Text("⚠︎ 読めない").font(.caption).foregroundColor(.red) }
            Spacer()
            if let h = help { HelpButton(anchor: h) }
        }
        .contentShape(Rectangle())
        .onTapGesture { withAnimation { isOpen.toggle() } }
    }
}

struct StepHeader: View {
    let title: String
    let anchor: String
    var body: some View {
        HStack(spacing: 4) {
            Text(title).font(.headline)
            HelpButton(anchor: anchor)
        }
        .padding(.top, 6)
    }
}

struct StepLine: View {
    let done: Bool
    let text: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundColor(done ? .green : .secondary)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct Inspector: View {
    @ObservedObject var model: AppModel
    @State private var presetName = ""
    /// Opens on 画面の調整 (or on 手順 until the show is saved), never on 展示の設定, which is
    /// touched once while setting up.
    @State private var tab = 0
    @AppStorage("learn.reboot") private var rebootChecked = false
    @State private var openPlace = true
    @State private var openCrop = false
    @State private var openMask = false
    @State private var openBlend = false
    @State private var openWarp = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("", selection: $tab) {
                Text("手順").tag(3)
                Text("画面の調整").tag(0)
                Text("展示の設定").tag(1)
                Text("プリセット").tag(2)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)
            .onAppear { if model.showFile == nil { tab = 3 } }
            Divider()
            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    switch tab {
                    case 3: stepsSection
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
            // Editing corners or the mesh: show where it is controlled.
            .onChange(of: model.editMode) { m in
                guard m != .none else { return }
                tab = 0; openWarp = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    withAnimation { proxy.scrollTo("warp", anchor: .bottom) }
                }
            }
            }
        }
    }

    /// The selected layer's mask is set but missing or unreadable.
    private var maskBroken: Bool {
        guard let p = model.selectedLayerIndex.flatMap({ model.show.outputs[$0.o].layers[$0.l].mask }) else { return false }
        return !FileManager.default.fileExists(atPath: p) || GPU.shared?.maskReady(p) == false
    }

    /// The steps for learning alone: each line is ticked by the app when it sees it done on this Mac.
    @ViewBuilder private var stepsSection: some View {
        Text("上から順に進めると、1 台で試すところから展示の形まで覚えられる。できたら ✓ が付く（この Mac で見えたことだけ）。")
            .font(.caption).foregroundColor(.secondary)
        Button("練習用のショーを開く") { model.openPractice() }
            .help("番号入りの映像 4 本と丸いマスクの見本。保存したショーはファイルに残る（保存前のショーは、替える前に確かめる）")
        Button("サンプル（映像と設定）をダウンロード…") {
            if let u = URL(string: "https://github.com/akiranakayasu-eng/sync-player/releases/latest") { NSWorkspace.shared.open(u) }
        }
        .help("音入りの映像と、そのまま開けるショーの一式（アプリとは別の zip、samples と付いたもの）を配っているページを開く。展開したら中の使い方.txt を見る")

        StepHeader(title: "1. 1 台で動かす", anchor: "step1")
        StepLine(done: !model.show.clips.isEmpty, text: "映像を開く（練習用でも自分の映像でも）")
        StepLine(done: model.learnedSet.contains("played"), text: "再生・停止する（space か上の「再生」）")
        StepLine(done: model.learnedSet.contains("fullscreen"), text: "左の「全画面にする（F）」を入れ、S で操作の窓を出し入れする")

        StepHeader(title: "2. 画面を作る", anchor: "step2")
        StepLine(done: model.learnedSet.contains("added"), text: "左の「映像」の ＋ か ⟳（差し替え）で自分の映像を入れる")
        StepLine(done: model.learnedSet.contains("adjusted"), text: "「画面の調整」で位置・大きさ・四隅などを変える（⌘Z で戻せる）")
        StepLine(done: model.learnedSet.contains("mask"), text: "自分のマスク画像を使う（なくてもよい）")
        StepLine(done: model.showFile != nil, text: "上の「保存…」でショーを保存する")

        StepHeader(title: "3. 何台かでそろえる", anchor: "step3")
        StepLine(done: model.learnedSet.contains("ident"), text: "N で Mac の名前とディスプレイの番号を出す")
        StepLine(done: model.learnedSet.contains("synced"), text: "同じネットワークの別の Mac をフォロワーにして、札が緑になる（フォロワーの Mac で ✓）")

        StepHeader(title: "4. 展示の形にする", anchor: "step4")
        StepLine(done: model.openAtLogin, text: "「展示の設定」で「ログインしたら開く」を入れる（全台）")
        StepLine(done: model.exhibitMaster, text: "「展示のマスター」を 1 台だけに入れる（マスターの Mac で ✓）")
        Toggle("電源を切って入れ直し、同じ状態に戻るのを見た", isOn: $rebootChecked)
            .font(.callout)

        Divider()
        Button("✓ の記録を消す") { model.forgetLearned(); rebootChecked = false }
            .controlSize(.small)
            .help("次の人が最初から練習するとき")
    }

    /// Settings for an exhibition: after a restart the Mac comes back as it was.
    @ViewBuilder private var exhibitSection: some View {
        SectionTitle("展示の前の点検", help: "check")
        Button("点検する") { model.runExhibitCheck() }
            .help("展示に入る前に、この Mac の設定とつながりを一度に確かめる")
        if let at = model.checkedAt {
            Text("点検した時刻 \(at.formatted(date: .omitted, time: .shortened))（直したら、もう一度押す）")
                .font(.caption).foregroundColor(.secondary)
            ForEach(model.checks) { c in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: c.ok == true ? "checkmark.circle.fill" : c.ok == false ? "exclamationmark.triangle.fill" : "questionmark.circle")
                        .foregroundColor(c.ok == true ? .green : c.ok == false ? .orange : .secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(c.text).font(.callout).fixedSize(horizontal: false, vertical: true)
                        if c.ok != true {
                            Text(c.ok == nil ? "アプリからは確かめられない。" + c.fix : c.fix)
                                .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }

        if model.isMaster {
            Divider()
            SectionTitle("つながっている Mac", help: "macs")
            if model.peers.isEmpty {
                Text("フォロワーはまだ見えない。ほかの Mac で SyncPlayer を開くと、ここに並ぶ。")
                    .font(.caption).foregroundColor(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 3) {
                    GridRow {
                        Text("名前").foregroundColor(.secondary)
                        Text("ずれ").foregroundColor(.secondary)
                        Text("版・注意").foregroundColor(.secondary)
                    }
                    ForEach(Array(model.peers.enumerated()), id: \.offset) { _, p in
                        GridRow {
                            Text(p.name).lineLimit(1).truncationMode(.middle)
                            Text(p.err.map { String(format: "%.1f ms", abs($0)) } ?? "—")
                                .font(.system(size: 11, design: .monospaced))
                            let other = p.ver != AppModel.version
                            Text(other ? (p.ver == "?" ? "⚠︎ 古い版" : "⚠︎ 版 \(p.ver)") : (p.warn.map { "⚠︎ " + $0 } ?? "OK"))
                                .foregroundColor(other || p.warn != nil ? .orange : .secondary)
                                .lineLimit(2).help(p.warn ?? p.ver)
                        }
                    }
                }
                .font(.caption)
            }
        }

        Divider()
        SectionTitle("いまのこの Mac", help: "exhibit")
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
            GridRow { Text("操作の窓の色").foregroundColor(.secondary)
                      Picker("", selection: Binding(get: { model.uiTheme }, set: { model.uiTheme = $0 })) {
                          ForEach(AppModel.UITheme.allCases) { Text($0.label).tag($0) }
                      }
                      .labelsHidden().pickerStyle(.segmented).fixedSize()
                      .help("ライトかダーク。この Mac だけの設定") }
            GridRow { Text("名前").foregroundColor(.secondary); Text(model.opts.name) }
            GridRow { Text("版").foregroundColor(.secondary); Text(AppModel.version) }
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
        SectionTitle("確かめる・困ったとき", help: "trouble")
        if model.netBlocked {
            Text("⚠︎ この Mac からネットワークに届いていない。ローカルネットワークの許可が切れているか、ネットワークにつながっていない。")
                .font(.caption).foregroundColor(.orange)
            Button("ローカルネットワークの設定を開く") { model.openLocalNetworkSettings() }
        }
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
        SliderRow(label: "不透明度", value: model.layerBinding(\.opacity, 1), range: 0...1, defaultValue: 1, unit: ValueText.percent)

        DisclosureGroup(isExpanded: $openPlace) {
            VStack(alignment: .leading, spacing: 6) {
                SliderRow(label: "横の位置", value: model.lookBinding(\.posX, 0), range: -1...1, defaultValue: 0, unit: ValueText.signedPercent,
                          help: "レイヤーの枠（4 分割なら 1 ます）の幅に対する割合。＋で右へ")
                SliderRow(label: "縦の位置", value: model.lookBinding(\.posY, 0), range: -1...1, defaultValue: 0, unit: ValueText.signedPercent,
                          help: "レイヤーの枠の高さに対する割合")
                SliderRow(label: "大きさ", value: model.lookBinding(\.scale, 1), range: 0.1...4, defaultValue: 1, unit: ValueText.percent,
                          help: "100% でレイヤーの枠いっぱい")
                SliderRow(label: "回転", value: model.lookBinding(\.rotation, 0), range: -180...180, defaultValue: 0, unit: ValueText.degrees)
                Button("位置・大きさ・回転を戻す（0）") {
                    guard var s = model.selectedLook else { return }
                    s.resetTransform(); model.updateLook(s)
                }
            }
            .padding(.top, 4)
        } label: { FoldLabel(title: "位置・大きさ・回転", isOpen: $openPlace, help: "place") }

        DisclosureGroup(isExpanded: $openCrop) {
            VStack(alignment: .leading, spacing: 6) {
                SliderRow(label: "左", value: model.lookBinding(\.cropL, 0), range: 0...0.5, defaultValue: 0, unit: ValueText.percent)
                SliderRow(label: "右", value: model.lookBinding(\.cropR, 0), range: 0...0.5, defaultValue: 0, unit: ValueText.percent)
                SliderRow(label: "上", value: model.lookBinding(\.cropT, 0), range: 0...0.5, defaultValue: 0, unit: ValueText.percent)
                SliderRow(label: "下", value: model.lookBinding(\.cropB, 0), range: 0...0.5, defaultValue: 0, unit: ValueText.percent)
            }
            .padding(.top, 4)
        } label: { FoldLabel(title: "切り取り（映像の端を削る）", isOpen: $openCrop, help: "crop") }

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
        } label: { FoldLabel(title: "マスク（白黒の画像で形を抜く）", isOpen: $openMask, warn: maskBroken, help: "mask") }

        DisclosureGroup(isExpanded: $openBlend) {
            VStack(alignment: .leading, spacing: 6) {
                SliderRow(label: "左", value: model.lookBinding(\.blendL, 0), range: 0...0.5, defaultValue: 0, unit: ValueText.percent)
                SliderRow(label: "右", value: model.lookBinding(\.blendR, 0), range: 0...0.5, defaultValue: 0, unit: ValueText.percent)
                SliderRow(label: "上", value: model.lookBinding(\.blendT, 0), range: 0...0.5, defaultValue: 0, unit: ValueText.percent)
                SliderRow(label: "下", value: model.lookBinding(\.blendB, 0), range: 0...0.5, defaultValue: 0, unit: ValueText.percent)
                SliderRow(label: "ガンマ", value: model.lookBinding(\.blendGamma, 2.2), range: 0.5...4, defaultValue: 2.2,
                          help: "重なりの明るさの合い方。ふつうは 2.2")
                Text("重なる幅を、画面の幅（高さ）に対する割合で。").font(.caption).foregroundColor(.secondary)
            }
            .padding(.top, 4)
        } label: { FoldLabel(title: "エッジブレンド（プロジェクターの重なり）", isOpen: $openBlend, help: "blend") }

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
        } label: { FoldLabel(title: "四隅・曲面（台形や曲がりを直す）", isOpen: $openWarp, help: "warp") }
        .id("warp")
    }

    private func meshSize(_ d: Int) {
        guard var s = model.selectedLook else { return }
        let n = min(8, max(2, s.meshCols + d))
        guard n != s.meshCols || s.meshRows != n else { return }
        s.setMeshSize(n)
        model.updateLook(s)
    }

    @ViewBuilder private var presetSection: some View {
        SectionTitle("プリセット（ショー全体の配置を名前で残す）", help: "presets")
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
