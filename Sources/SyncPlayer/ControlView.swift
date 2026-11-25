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
/// in three tabs (steps, adjusting the picture, the exhibition settings of this Mac); seats at the top left.
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
                        Text(L("プレビュー: ", "Preview: ") + (model.selectedOutputConfig?.name ?? L("出力がありません", "No outputs")))
                            .font(.caption).foregroundColor(.secondary)
                        PreviewView(model: model)
                            .frame(minHeight: 160)
                    }
                    .padding(8)
                    .frame(minHeight: 200)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                        Text(L("詳しい状態（映像ごと）・緑はよい、橙は見ておく、赤は直す。→ のあとが対処。境の線を上へ動かすと広がる", "Status (per clip) · green OK, orange check, red fix. After → is what to do. Drag the line above to enlarge"))
                            .font(.caption).foregroundColor(.secondary)
                            .lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 4)
                        Button { model.transport.resetCounts() } label: { Label(L("数を 0 に", "Clear"), systemImage: "eraser") }
                            .buttonStyle(.borderless).font(.caption)
                            .help(L("jumps・loops・dropped の数を 0 に戻す（再生には影響しない）。この画面は今の状態を毎回描き直すので、たまるのはこの数だけ", "Set jumps, loops and dropped back to 0 (playback is not affected). The rest is redrawn from the current state, so only these counts add up"))
                        }
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
        .id(model.uiLang)   // redraw every part when the language changes
    }
}

struct StatusText: View {
    @ObservedObject var status: StatusModel
    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(status.lines) { l in
                    StatusRow(line: l)
                        .background(l.id % 2 == 0 ? Color.secondary.opacity(0.08) : Color.clear)
                }
            }
            .frame(minWidth: 400, alignment: .leading)
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: UIColors.panel)))
    }
}

/// One row: a coloured mark, the line (never wrapped), and below it what to do when something is wrong.
struct StatusRow: View {
    let line: StatusLine
    var color: Color {
        switch line.level {
        case 1: return .green
        case 2: return .orange
        case 3: return .red
        default: return .secondary
        }
    }
    var mark: String {
        switch line.level {
        case 1: return "checkmark.circle.fill"
        case 2: return "exclamationmark.triangle.fill"
        case 3: return "xmark.octagon.fill"
        default: return "circle"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Image(systemName: mark).foregroundColor(color)
                    .font(.system(size: 10)).frame(width: 14)
                    .opacity(line.level == 0 ? 0.35 : 1)
                Text(line.text)
                    .font(.system(size: 11, weight: line.level >= 2 ? .semibold : .regular, design: .monospaced))
                    .foregroundColor(line.level == 3 ? .red : .primary)
                    .lineLimit(1).fixedSize()
                    .textSelection(.enabled)
            }
            if let fix = line.fix {
                Text("→ " + fix)
                    .font(.system(size: 11))
                    .foregroundColor(color)
                    .lineLimit(1).fixedSize()
                    .padding(.leading, 20)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 4).padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The key list window: groups with a heading, keys drawn as key caps, rows striped.
struct KeyListView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(AppModel.keyGroups, id: \.title) { g in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(g.title).font(.system(size: 13, weight: .bold))
                            .padding(.bottom, 4)
                        ForEach(Array(g.keys.enumerated()), id: \.offset) { i, k in
                            HStack(spacing: 12) {
                                HStack(spacing: 4) {
                                    ForEach(k.key.components(separatedBy: "  "), id: \.self) { cap in
                                        Text(cap)
                                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                            .padding(.horizontal, 6).padding(.vertical, 2)
                                            .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.18)))
                                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.4)))
                                    }
                                }
                                .frame(width: 150, alignment: .leading)
                                Text(k.what).font(.system(size: 13))
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 6).padding(.vertical, 4)
                            .background(i % 2 == 0 ? Color.secondary.opacity(0.07) : Color.clear)
                        }
                    }
                }
                Text(L("キーは、操作の窓で文字を入れていないときと、出力の画面で効きます。H を押すと出力の画面にもこの一覧が出ます。", "Keys work in the control window (when not typing) and on the outputs. Press H to show this list on the outputs too."))
                    .font(.caption).foregroundColor(.secondary)
            }
            .padding(16)
        }
        .frame(minWidth: 460, minHeight: 360)
    }
}

/// Follower / Master as two joined buttons; the chosen one is filled in its own colour
/// (master blue, follower grey), so the role can be told across the room (Akira 2026-11-25).
/// The role switch's tooltip: what on and off mean.
func isMaster_help(_ on: Bool) -> String {
    (on ? L("いま: マスター（この Mac が再生を決める）。", "Now: master (this Mac controls playback). ")
        : L("いま: フォロワー（マスターに付いていく）。", "Now: follower (follows the master). "))
    + L("入れるとマスター、切るとフォロワー（M キーでも切り替わる）。マスターは全台で 1 台だけ", "On = master, off = follower (M also switches). Only one master.")
}

struct RoleSwitch: View {
    let isMaster: Bool
    let set: (Bool) -> Void
    /// Amber for the master (Akira 2026-11-25: not blue; blue is for numbers to type, green/red for state).
    static let masterColor = Color(red: 0.96, green: 0.70, blue: 0.0)
    /// An on/off switch labelled only "Master" (Akira 2026-11-25): on = this Mac is the master (amber),
    /// off = follower (grey).
    var body: some View {
        HStack(spacing: 6) {
            Toggle("", isOn: Binding(get: { isMaster }, set: { set($0) }))
                .toggleStyle(.switch).labelsHidden().controlSize(.small)
                .tint(RoleSwitch.masterColor)
            // One fixed word: with both names beside a switch it is easy to read it the wrong way (Akira).
            Text(L("マスター", "Master"))
                .font(.system(size: 12, weight: isMaster ? .bold : .regular))
                .foregroundColor(isMaster ? Color(nsColor: UIColors.masterText) : .secondary)
        }
        .fixedSize()
    }
}

/// The layer being adjusted, at the top of the Layer tab: its number (1 = front) in a filled
/// badge, its name large, and the output it is on, so it is clear at a glance (Akira 2026-11-25).
struct SelectedLayerHeader: View {
    @ObservedObject var model: AppModel
    var body: some View {
        if let ix = model.selectedLayerIndex {
            let o = model.show.outputs[ix.o]
            let l = o.layers[ix.l]
            HStack(spacing: 8) {
                Text("\(o.layers.count - ix.l)")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .frame(minWidth: 26, minHeight: 26)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor))
                VStack(alignment: .leading, spacing: 0) {
                    Text(l.name ?? model.clipName(l.clipID))
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1).truncationMode(.middle)
                    Text(L("レイヤー \(o.layers.count - ix.l) ・ \(o.name)", "Layer \(o.layers.count - ix.l) · \(o.name)"))
                        .font(.caption).foregroundColor(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.14)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor.opacity(0.6), lineWidth: 1))
        } else {
            SectionTitle(L("選んだレイヤー", "Selected Layer"))
        }
    }
}

extension View {
    /// A list row chosen by a click and shown in light blue, also when the list is not focused
    /// (macOS greys out the built-in selection then; Akira 2026-11-25 asked for light blue).
    func selectedRow(_ on: Bool, select: @escaping () -> Void) -> some View {
        self.contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded { select() })
            .listRowBackground(
                RoundedRectangle(cornerRadius: 5)
                    .fill(on ? Color.accentColor.opacity(0.28) : Color.clear)
                    .padding(.horizontal, 4))
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
            Text(status.headline.isEmpty ? L("準備中", "Starting") : status.headline)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1).truncationMode(.tail)
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(Capsule().fill(Color.secondary.opacity(0.12)))
        .help(L("\(status.headline)\n（この Mac がいま何をしているか。緑はそろって再生中、灰色は停止中、橙は確かめること。映像ごとの数字は真ん中の下の「詳しい状態」。「マスター待ち」が続くときは、同じネットワークにつながっているか、マスターの Mac で SyncPlayer が開いているか、初めて開いたときのローカルネットワークの許可を確かめる）", "\(status.headline)\n(What this Mac is doing. Green: playing in sync, grey: stopped, orange: needs a look. Per-clip numbers are in Status below the preview. If it keeps waiting for the master, check the network, that SyncPlayer is open on the master, and the Local Network permission.)"))
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
        guard let t = parseTime(text) else { model.notify(L("長さは 2000（20 秒）や 1:30 の形で", "Type the length like 2000 (20 s) or 1:30")); leaveField(); return }
        // Digits read like After Effects, so "20" is 0.2 s: ask for the right form instead of
        // looping every Mac at half a second.
        if t > 0 && t < 1 {
            model.notify(L("ループが 1 秒より短くなるので入れませんでした。20 秒なら 2000、1 分 30 秒なら 1:30 と打つ",
                           "Not set: shorter than 1 s. Type 2000 for 20 s, or 1:30"))
            leaveField(); return
        }
        let x = t <= 0 ? 0 : max(t, Show.minLoop)
        var s = model.show
        s.loopTogether = true
        s.loopLength = x
        if s != model.show { model.show = s }
        model.notify(x == 0 ? L("ループの長さ: いちばん長い映像に合わせる", "Loop length: the longest clip") : L("ループの長さ: \(timeString(x))", "Loop length: \(timeString(x))"))
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
                model.notify(L("尺（\(timeString(status.duration))）を超えたので、ループの中の位置へ折り返しました", "Past the length (\(timeString(status.duration))), so wrapped into the loop"))
            }
        } else {
            model.notify(L("位置は 200（2 秒）や 1:23.5 の形で", "Type the time like 200 (2 s) or 1:23.5"))
        }
        leaveField()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                StatusBadge(status: status)
                SeatChip(model: model)
                Spacer(minLength: 8)
                RoleSwitch(isMaster: model.isMaster) { model.setRoleByHand(master: $0) }
                .help(isMaster_help(model.isMaster))
                // Sound: a speaker switch and, beside it, which movie's sound (Akira 2026-11-25), in one
                // framed group with the word "Audio" so the menu reads as the sound source (Akira 23:39).
                HStack(spacing: 6) {
                    Toggle(isOn: Binding(get: { model.audioOn }, set: { model.setAudio($0) })) {
                        Image(systemName: model.audioOn ? "speaker.wave.2.fill" : "speaker.slash")
                            .frame(width: 18)
                    }
                    .toggleStyle(.button)
                    .help(model.audioOn ? L("この Mac で音を出している（A キーで消す）", "Sound on for this Mac (A to mute)") : L("この Mac では音を出さない（A キーで出す）", "Sound off for this Mac (A to turn on)"))
                    Text(L("音声", "Audio")).font(.caption.bold()).foregroundColor(.secondary)
                    Picker("", selection: Binding(get: { model.show.audioClip ?? model.show.seatClips.first?.id ?? "" },
                                                  set: { model.setAudioClip($0) })) {
                        ForEach(model.show.clips) { c in Label(c.name, systemImage: "waveform").tag(c.id) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 160)
                    .disabled(!model.audioOn)
                    .help(L("音声のもと: どの映像の音をこの Mac から出すか（音を出しているときだけ選べる）", "Audio source: which clip's sound this Mac plays (when sound is on)"))
                }
                .padding(.horizontal, 6).padding(.vertical, 2)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.35)))
                Divider().frame(height: 18)
                Button { model.openShow() } label: { Image(systemName: "folder") }
                    .help(L("ショーを開く（⌘O）", "Open Show (⌘O)"))
                Button { model.saveShowAs() } label: { Image(systemName: "square.and.arrow.down") }
                    .help(L("ショーとして保存（⌘S）", "Save Show (⌘S)"))
                Button { model.showCollectWindow() } label: { Image(systemName: "shippingbox") }
                    .help(L("素材をまとめる（⇧⌘E）: ショーと映像・マスクを 1 つのフォルダか zip に写す。ほかの Mac へ運ぶとき", "Collect Files (⇧⌘E): copy the show, clips and masks into one folder or zip, to carry to other Macs"))
            }
            HStack(spacing: 10) {
                // Transport as symbols only (Akira 2026-11-25: the icons say enough).
                HStack(spacing: 2) {
                    TransportButton("backward.end.fill", L("頭へ（R か ↑）", "Go to Start (R or ↑)")) { model.master?.jump(to: 0) }
                    TransportButton("gobackward.5", L("5 秒戻る（← で 1 コマ、shift+← で 1 秒）", "Back 5 s (← 1 frame, shift+← 1 s)")) { model.master?.jump(by: -5) }
                    TransportButton(status.playing ? "pause.fill" : "play.fill",
                                    L("再生・停止（space）。全部の Mac がいっしょに", "Play / Stop (space), on all Macs together"), big: true) { model.master?.togglePlay() }
                    TransportButton("goforward.5", L("5 秒進む（→ で 1 コマ、shift+→ で 1 秒）", "Forward 5 s (→ 1 frame, shift+→ 1 s)")) { model.master?.jump(by: 5) }
                }
                .disabled(!status.isMaster)
                .opacity(status.isMaster ? 1 : 0.35)
                .help(status.isMaster ? "" : L("再生と位置はマスターの Mac で操作する", "Playback is controlled on the master Mac"))

                VStack(alignment: .leading, spacing: 0) {
                // Small captions over the two times, like Premiere's current time / duration.
                HStack(spacing: 0) {
                    Text(L("位置", "Current")).frame(width: 56, alignment: .trailing)
                    Text(" / ")
                    Text(L("ループ", "Loop"))
                }
                .font(.system(size: 9)).foregroundColor(.secondary)
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
                            .editableNumber(status.isMaster)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(width: 56, alignment: .trailing)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                guard status.isMaster else { return }
                                timeText = timeString(status.position); editingTime = true
                            }
                            .help(status.isMaster ? L("押すと位置を打てる。After Effects のように数字だけなら右から 1/100 秒・秒・分（200 で 2 秒、10000 で 1 分）。1:23.5 の形でもよい。Return で全部の Mac がその位置へ", "Click to type a time. Digits read from the right as 1/100 s, seconds, minutes, like After Effects (200 = 2 s, 10000 = 1 min). 1:23.5 also works. Return moves all Macs there") : L("いまの位置", "Current time"))
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
                            .editableNumber(status.isMaster)
                            .font(.system(size: 12, design: .monospaced))
                            .contentShape(Rectangle())
                            .onTapGesture {
                                guard status.isMaster else { return }
                                loopText = timeString(status.duration); editingLoop = true
                            }
                            .help(status.isMaster ? L("ループの長さ。押すと打てる（200 で 2 秒、1:30 で 1 分 30 秒。0 でいちばん長い映像の長さ）。全部の Mac がこの長さで頭へ戻る", "Loop length. Click to type (200 = 2 s, 1:30 = 1 min 30 s, 0 = longest clip). All Macs go back to the start at this length") : L("ループの長さ（マスターの Mac で変える）", "Loop length (changed on the master)"))
                    }
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
                    .help(L("ドラッグして離すと、全部の Mac がその位置へ", "Drag and release to move all Macs there"))
                // Next to the loop length it governs (Akira 2026-11-25: up here, not at the bottom of the left column).
                Toggle(L("全部いっしょにループ", "Loop Together"), isOn: Binding(get: { model.show.loopTogether },
                                                        set: { v in if model.show.loopTogether != v { model.show.loopTogether = v } }))
                    .toggleStyle(.checkbox)
                    .fixedSize()
                    .help(L("入れると、すべての Mac の映像が同じ長さ（左の / のあとの時刻。押すと打てる）で頭へ戻る。短い映像は最後のコマで待つ。切ると映像ごとに自分の長さでループする（マスターの設定が使われる）", "On: every clip on every Mac goes back to the start at one length (the time after / at the left; click to type). Shorter clips hold their last frame. Off: each clip loops at its own length (the master's setting is used)"))
            }
        }
    }
}

// MARK: left side

struct Sidebar: View {
    @ObservedObject var model: AppModel
    @State private var selectedSeat: String?
    @State private var renamingSeat: String?
    // List heights set by dragging the line under each list (0 = as tall as its rows; kept per Mac).
    @AppStorage("ui.h.seats") private var hSeats: Double = 0
    @AppStorage("ui.h.outputs") private var hOutputs: Double = 0
    @AppStorage("ui.h.layers") private var hLayers: Double = 0
    @AppStorage("ui.h.clips") private var hClips: Double = 0

    private func finishSeatRename(_ id: String) {
        renamingSeat = nil
        model.renameSeat(id, renameText)
        DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) }
    }

    /// Seats: the places of the exhibition (a Mac and its projectors). The one marked is this Mac.
    @ViewBuilder private var seatSection: some View {
        SectionTitle(L("席", "Seats"), help: "seats")
        List {
            ForEach(Array(model.show.seats.enumerated()), id: \.element.id) { k, st in
                HStack(spacing: 6) {
                    SeatBadge(index: k, on: st.id == model.show.seatID)
                    if renamingSeat == st.id {
                        TextField("", text: $renameText)
                            .focused($renameFocused)
                            .onSubmit { finishSeatRename(st.id) }
                            .onExitCommand { renamingSeat = nil }
                            .onChange(of: renameFocused) { f in if !f && renamingSeat == st.id { if FieldEsc.recent { renamingSeat = nil } else { finishSeatRename(st.id) } } }
                            .onAppear { renameFocused = true }
                    } else {
                        Text(st.name).lineLimit(1).truncationMode(.middle)
                            .onTapGesture(count: 2) { renameText = st.name; renamingSeat = st.id }
                            .simultaneousGesture(TapGesture().onEnded { selectedSeat = st.id })
                            .help(L("ダブルクリックで名前を変える", "Double-click to rename"))
                    }
                    Spacer(minLength: 4)
                    if st.id == model.show.seatID {
                        Text(L("この Mac", "This Mac")).font(.caption2.bold())
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor)).foregroundColor(.white)
                    } else {
                        let who = model.peers.filter { $0.seat == st.name }.map(\.name)
                        Text(who.isEmpty ? (model.isMaster ? L("空き", "free") : "") : who.joined(separator: ", "))
                            .font(.caption).foregroundColor(who.count > 1 ? .orange : .secondary).lineLimit(1)
                    }
                }
                .selectedRow((selectedSeat ?? model.show.seatID) == st.id) { selectedSeat = st.id; model.deleteTarget = { [weak m = model] in m?.deleteSeat(st.id) } }
                .contextMenu {
                    Button(L("名前を変える", "Rename")) { renameText = st.name; renamingSeat = st.id }
                    Button(L("複製", "Duplicate")) { model.duplicateSeat(st.id) }
                    Button(L("この Mac をこの席にする", "Make This Mac This Seat")) { model.switchSeat(st.id) }
                        .disabled(st.id == model.show.seatID)
                    Divider()
                    Button(L("席を消す…", "Delete Seat…"), role: .destructive) { model.deleteSeat(st.id) }
                        .disabled(model.show.seats.count < 2)
                }
            }
        }
        .frame(height: listH(hSeats, model.show.seats.count, max: 6))
        .scrollContentBackground(.hidden)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: UIColors.panel)))
        let sel = selectedSeat.flatMap { id in model.show.seats.first { $0.id == id } } ?? model.show.seat
        ListBar {
            IconButton("plus", L("席を足す（Mac をもう 1 台使うとき）", "Add a seat (for another Mac)")) { model.addSeat() }
            IconButton("plus.square.on.square", L("選んだ席を複製（出力とレイヤーごと）", "Duplicate the selected seat (with its outputs and layers)")) { model.duplicateSeat(sel.id) }
            IconButton("minus", L("選んだ席を消す", "Delete the selected seat")) { model.deleteSeat(sel.id) }
                .disabled(model.show.seats.count < 2)
            Divider().frame(height: 14)
            IconButton("desktopcomputer", L("この Mac を選んだ席にする（出力・レイヤー・音がその席のものになる）", "Make this Mac the selected seat (its outputs, layers and sound)")) { model.switchSeat(sel.id) }
                .disabled(sel.id == model.show.seatID)
        }
        HeightHandle(height: $hSeats, auto: listHeight(model.show.seats.count, max: 6))
    }
    @State private var renamingOutput: String?
    @State private var renamingLayer: String?

    private func finishLayerRename(_ id: String) {
        let t = renameText.trimmingCharacters(in: .whitespaces)
        renamingLayer = nil
        for o in model.show.outputs.indices {
            if let i = model.show.outputs[o].layers.firstIndex(where: { $0.id == id }) {
                let v: String? = t.isEmpty ? nil : t
                if model.show.outputs[o].layers[i].name != v { model.show.outputs[o].layers[i].name = v }
            }
        }
        DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) }
    }
    @State private var renameText = ""
    @FocusState private var renameFocused: Bool

    private func finishRename(_ id: String) {
        let t = renameText.trimmingCharacters(in: .whitespaces)
        renamingOutput = nil
        if !t.isEmpty, let i = model.show.outputs.firstIndex(where: { $0.id == id }), model.show.outputs[i].name != t {
            model.show.outputs[i].name = t
        }
        DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) }
    }


    // MARK: picking rows and the right-click menus

    private func clickLayer(_ id: String) {
        let order = (model.selectedOutputConfig?.layers ?? []).reversed().map(\.id)
        model.clickLayerRow(id, order: order)
        model.deleteTarget = { [weak m = model] in m?.removeLayer() }
    }

    private func clickClip(_ id: String) {
        model.clickClipRow(id)
        model.deleteTarget = { [weak m = model] in m?.removeSelectedClips() }
    }

    /// A right-click on a row that is not among the picked ones acts on that row only (like Finder).
    private func layerTarget(_ id: String) {
        if !model.layerPicks.contains(id) { model.layerPicks = []; model.selectedLayer = id }
    }
    private func clipTarget(_ id: String) {
        if !model.clipPicks.contains(id) { model.clipPicks = []; model.selectedClip = id }
    }

    @ViewBuilder private func layerMenu(_ l: Layer) -> some View {
        let many = model.layerPicks.contains(l.id) && model.layerPicks.count > 1
        if !many {
            Button(L("名前を変える", "Rename")) { layerTarget(l.id); renameText = l.name ?? ""; renamingLayer = l.id }
            Menu(L("映像を替える", "Replace Clip")) {
                ForEach(model.show.clips) { c in
                    Button { model.setLayerClip(l.id, c.id) } label: {
                        if c.id == l.clipID { Label(c.name, systemImage: "checkmark") } else { Text(c.name) }
                    }
                }
                Divider()
                Button(L("ファイルから選ぶ…", "Choose a File…")) { model.addClipsForLayer(l.id) }
            }
            Button(l.visible ? L("隠す", "Hide") : L("見せる", "Show")) { model.visibleBinding(l.id).wrappedValue.toggle() }
            Button(L("複製", "Duplicate")) { layerTarget(l.id); model.duplicateLayer() }
            Divider()
            Button(L("手前へ", "Bring Forward")) { layerTarget(l.id); model.moveLayer(1) }
            Button(L("奥へ", "Send Backward")) { layerTarget(l.id); model.moveLayer(-1) }
            Divider()
        }
        Button(many ? L("レイヤー \(model.layerPicks.count) つを消す…", "Delete \(model.layerPicks.count) Layers…") : L("レイヤーを消す…", "Delete Layer…"), role: .destructive) {
            layerTarget(l.id); model.removeLayer()
        }
    }

    @ViewBuilder private func clipMenu(_ c: Clip) -> some View {
        let many = model.clipPicks.contains(c.id) && model.clipPicks.count > 1
        if !many {
            Button(L("差し替え…（レイヤーの設定はそのまま）", "Replace Footage… (layer settings kept)")) { clipTarget(c.id); model.replaceClip(c.id) }
            if let lid = model.selectedLayer {
                Button(L("選んだレイヤーに出す", "Use in Selected Layer")) { model.setLayerClip(lid, c.id) }
            }
            Button(L("この映像の音を出す", "Play This Clip's Sound")) { model.setAudioClip(c.id) }
            Button(L("Finder で表示", "Reveal in Finder")) { model.revealClip(c.id) }
            Divider()
        }
        Button(many ? L("映像 \(model.clipPicks.count) 本をショーから外す…", "Remove \(model.clipPicks.count) Clips from Show…") : L("ショーから外す…", "Remove from Show…"), role: .destructive) {
            clipTarget(c.id); model.removeSelectedClips()
        }
    }

    var body: some View {
        // Scrolls when the window is low, so the top bar is never pushed out. The lists are as tall
        // as their rows (they do not scroll themselves), so the wheel moves this column.
        ScrollView {
        VStack(alignment: .leading, spacing: 6) {
            seatSection
            SectionTitle(L("出力", "Outputs") + (model.show.seats.count > 1 ? " — " + model.show.seat.name : ""), help: "outputs")
            List {
                ForEach(model.show.outputs) { o in
                    HStack {
                        // Rename in place: double-click the name (Return sets, esc cancels), like Adobe.
                        if renamingOutput == o.id {
                            TextField("", text: $renameText)
                                .focused($renameFocused)
                                .onSubmit { finishRename(o.id) }
                                .onExitCommand { renamingOutput = nil }
                                .onChange(of: renameFocused) { f in if !f && renamingOutput == o.id { if FieldEsc.recent { renamingOutput = nil } else { finishRename(o.id) } } }
                                .onAppear { renameFocused = true }
                        } else {
                            Text(o.name)
                                .onTapGesture(count: 2) { renameText = o.name; renamingOutput = o.id }
                                .simultaneousGesture(TapGesture().onEnded { model.selectedOutput = o.id })
                                .help(L("ダブルクリックで名前を変える", "Double-click to rename"))
                        }
                        Spacer()
                        Text(L("ディスプレイ", "Display") + " \(o.screen + 1)" + (o.fullscreen ? L("・全画面", " · full screen") : "")).foregroundColor(.secondary).font(.caption)
                    }
                    .tag(Optional(o.id))
                    .selectedRow(model.selectedOutput == o.id) { model.selectedOutput = o.id; model.deleteTarget = { [weak m = model] in m?.removeOutput() } }
                    .contextMenu {
                        Button(L("名前を変える", "Rename")) { renameText = o.name; renamingOutput = o.id }
                        Divider()
                        Button(L("出力を消す…", "Delete Output…"), role: .destructive) { model.selectedOutput = o.id; model.removeOutput() }
                            .disabled(model.show.outputs.count < 2)
                    }
                }
            }
            .frame(height: listH(hOutputs, model.show.outputs.count, max: 8))
            .scrollContentBackground(.hidden)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: UIColors.panel)))
            ListBar {
                IconButton("plus", L("出力を足す（別のディスプレイに出すとき）", "Add an output (for another display)")) { model.addOutput() }
                IconButton("minus", L("選んだ出力を消す", "Delete the selected output")) { model.removeOutput() }
            }
            HeightHandle(height: $hOutputs, auto: listHeight(model.show.outputs.count, max: 8))
            if model.selectedOutputConfig != nil {
                Picker("", selection: model.outputBinding(\.screen, 0)) {
                    ForEach(screenChoices, id: \.self) { i in
                        Text(i < model.screenShort.count ? model.screenShort[i] : L("ディスプレイ \(i + 1)（つながっていない）", "Display \(i + 1) (not connected)")).tag(i)
                    }
                }
                .labelsHidden()
                .help(model.screenNames.joined(separator: "\n"))
                Toggle(L("全画面にする（F）", "Full Screen (F)"), isOn: model.outputBinding(\.fullscreen, false))
                    .help(L("このディスプレイいっぱいに出す。操作の窓とカーソルはそのディスプレイから消える", "Fill this display. The control window and pointer leave that display"))
            }

            Divider().padding(.vertical, 2)
            SectionTitle(L("レイヤー", "Layers"), help: "layers")
            List {
                // Numbered from the front (1 = frontmost, like After Effects). Drag a row to change
                // the order, like the tracks in Premiere.
                ForEach(Array((model.selectedOutputConfig?.layers ?? []).reversed().enumerated()), id: \.element.id) { k, l in
                    HStack {
                        Text("\(k + 1)").font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary)
                            .frame(minWidth: 16, alignment: .trailing)
                        // An eye, like Adobe's layer panels (Akira 2026-11-25).
                        let vis = model.visibleBinding(l.id)
                        Button { vis.wrappedValue.toggle() } label: {
                            Image(systemName: vis.wrappedValue ? "eye" : "eye.slash")
                                .foregroundColor(vis.wrappedValue ? .primary : .secondary)
                                .frame(width: 18)
                        }
                        .buttonStyle(.borderless)
                        .help(vis.wrappedValue ? L("見えている（押すと隠す）", "Visible (click to hide)") : L("隠している（押すと見せる）", "Hidden (click to show)"))
                        // The layer's own name: double-click to type it (empty = the movie's name).
                        if renamingLayer == l.id {
                            TextField(model.clipName(l.clipID), text: $renameText)
                                .focused($renameFocused)
                                .onSubmit { finishLayerRename(l.id) }
                                .onExitCommand { renamingLayer = nil }
                                .onChange(of: renameFocused) { f in if !f && renamingLayer == l.id { if FieldEsc.recent { renamingLayer = nil } else { finishLayerRename(l.id) } } }
                                .onAppear { renameFocused = true }
                        } else {
                            Text(l.name ?? model.clipName(l.clipID))
                                .lineLimit(1).truncationMode(.middle)
                                .onTapGesture(count: 2) { renameText = l.name ?? ""; renamingLayer = l.id }
                                .simultaneousGesture(TapGesture().onEnded { clickLayer(l.id) })
                                .help(L("ダブルクリックで名前を付ける（空にすると映像の名前に戻る）", "Double-click to name (empty = the clip's name)"))
                        }
                        Spacer(minLength: 2)
                        // A named layer also shows its movie (the movie is changed from the right-click menu).
                        if l.name != nil {
                            Text(model.clipName(l.clipID)).font(.caption).foregroundColor(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                    }
                    .tag(Optional(l.id))
                    .selectedRow(model.layerPicks.isEmpty ? model.selectedLayer == l.id : model.layerPicks.contains(l.id)) { clickLayer(l.id) }
                    .contextMenu { layerMenu(l) }
                    // Drop a movie from the movie list below onto a layer to show it there.
                    .dropDestination(for: String.self) { ids, _ in
                        guard let id = ids.first, id.hasPrefix(ClipDrag.prefix) else { return false }
                        model.setLayerClip(l.id, String(id.dropFirst(ClipDrag.prefix.count)))
                        return true
                    }
                    .help(L("ドラッグで順番を入れ替える（上が手前）", "Drag to reorder (top = front)"))
                }
                .onMove { model.moveLayers(fromDisplayed: $0, toDisplayed: $1) }
            }
            .frame(height: listH(hLayers, model.selectedOutputConfig?.layers.count ?? 0, max: 12))
            .scrollContentBackground(.hidden)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: UIColors.panel)))
            // One row of small icon buttons under the list, like the + − bar under macOS lists.
            ListBar {
                IconButton("plus", L("レイヤーを足す", "Add a layer")) { model.addLayer() }
                IconButton("minus", L("選んだレイヤーを消す", "Delete the selected layer")) { model.removeLayer() }
                Divider().frame(height: 14)
                IconButton("arrow.up", L("選んだレイヤーを手前へ（ドラッグでも入れ替えられる）", "Bring the selected layer forward (or drag)")) { model.moveLayer(1) }
                IconButton("arrow.down", L("選んだレイヤーを奥へ", "Send the selected layer backward")) { model.moveLayer(-1) }
                Divider().frame(height: 14)
                IconButton("square.grid.2x2", L("4 分割などに並べる: この出力のレイヤーを、数に合わせて 2×2 などの格子に並べる", "Tile: arrange this output's layers in a grid such as 2×2")) { model.arrangeGrid() }
            }

            HeightHandle(height: $hLayers, auto: listHeight(model.selectedOutputConfig?.layers.count ?? 0, max: 12))
            SectionTitle(L("映像ライブラリ", "Footage"), help: "clips")
            // One line per movie (the list was 2 lines a movie and made the column long). Replace and
            // remove act on the selected movie, like the layer buttons.
            List {
                ForEach(model.show.clips) { c in
                    HStack(spacing: 4) {
                        if model.clipBroken(c.id) {
                            Text(L("⚠︎ 開けない", "⚠︎ can't open")).font(.caption).foregroundColor(.red)
                        }
                        Text(c.name).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 4)
                        // Replace and remove are in the right-click menu (Akira 2026-11-25, instead of icons).
                    }
                    .tag(Optional(c.id))
                    .selectedRow(model.clipPicks.isEmpty ? model.selectedClip == c.id : model.clipPicks.contains(c.id)) { clickClip(c.id) }
                    .contextMenu { clipMenu(c) }
                    .help(L("\(c.name)\nレイヤーの行へドラッグすると、そのレイヤーの映像になる。右クリックで差し替え・外すなど。⌘・⇧ クリックで複数選べる", "\(c.name)\nDrag onto a layer row to show it on that layer. Right-click to replace, remove and more. ⌘ / ⇧ click to pick several"))
                    .draggable(ClipDrag.prefix + c.id)
                }
            }
            .frame(height: listH(hClips, model.show.clips.count, max: 6))
            .scrollContentBackground(.hidden)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: UIColors.panel)))
            ListBar {
                IconButton("plus", L("映像を足す…（ファイルを選ぶ）", "Add clips… (choose files)")) { model.addClips() }
            }
            HeightHandle(height: $hClips, auto: listHeight(model.show.clips.count, max: 6))
        }
        .padding(8)
        }
        .scrollIndicators(.visible)
    }

    /// The height dragged for a list, or (0) just tall enough for its rows.
    private func listH(_ dragged: Double, _ rows: Int, max m: Int) -> CGFloat {
        dragged > 0 ? CGFloat(dragged) : listHeight(rows, max: m)
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

/// A borderless transport symbol (play is larger).
struct TransportButton: View {
    let icon: String
    let help: String
    var big = false
    let action: () -> Void
    init(_ icon: String, _ help: String, big: Bool = false, action: @escaping () -> Void) {
        self.icon = icon; self.help = help; self.big = big; self.action = action
    }
    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: big ? 20 : 15, weight: .medium))
                .frame(width: big ? 34 : 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
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
            .help(L("ドラッグして左の欄の幅を変える", "Drag to change the width of the left column"))
    }
}

/// The line under a list: drag it up or down to make the list shorter or taller (like the panel
/// edges in After Effects). Double-click goes back to "as tall as its rows". Kept per Mac.
struct HeightHandle: View {
    @Binding var height: Double
    let auto: CGFloat
    var range: ClosedRange<Double> = 40...900
    @State private var start: Double?
    @State private var hover = false
    var body: some View {
        Rectangle()
            .fill(hover || start != nil ? Color.accentColor : Color(nsColor: .separatorColor))
            .frame(height: hover || start != nil ? 2 : 1)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .onHover { inside in
                hover = inside
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { g in
                    if start == nil { start = height > 0 ? height : Double(auto) }
                    height = min(max((start ?? height) + g.translation.height, range.lowerBound), range.upperBound)
                }
                .onEnded { _ in start = nil })
            .onTapGesture(count: 2) { height = 0 }
            .help(L("ドラッグして上の一覧の高さを変える（ダブルクリックで行の数に合わせた高さに戻る）", "Drag to change the height of the list above (double-click: fit to its rows)"))
    }
}

/// A movie dragged from the movie list (a plain string, so other text drops are told apart).
enum ClipDrag { static let prefix = "syncplayer-clip:" }

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
            .help(L("使い方のページのこの部分を開く", "Open this part of the guide"))
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
                    .onChange(of: focused) { f in if !f && editing { if FieldEsc.recent { editing = false } else { commit() } } }
                    .onAppear { focused = true }
            } else {
                Text(unit.text(value))
                    .editableNumber()
                    .font(.system(size: 11, design: .monospaced))
                    .frame(width: 52, alignment: .trailing)
                    .contentShape(Rectangle())
                    .onTapGesture { text = unit.text(value); editing = true }
                    .help(L("押すと数字を打てる（Return で決める、esc でやめる）", "Click to type a value (Return to set, esc to cancel)"))
            }
            if defaultValue != nil {
                Button { reset() } label: { Image(systemName: "arrow.counterclockwise") }
                    .buttonStyle(.borderless)
                    .disabled(atDefault)
                    .opacity(atDefault ? 0.3 : 1)
                    .help(L("最初の値（\(unit.text(defaultValue ?? 0))）に戻す。名前のダブルクリックでも戻る", "Reset to the default (\(unit.text(defaultValue ?? 0))). Double-clicking the name also resets"))
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
            if warn { Text(L("⚠︎ 読めない", "⚠︎ can't read")).font(.caption).foregroundColor(.red) }
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
                Text(L("手順", "Steps")).tag(3)
                Text(L("画面の調整", "Layer")).tag(0)
                Text(L("展示の設定", "Exhibit")).tag(1)
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
                    default:
                        if model.selectedLayerIndex == nil {
                            Text(L("左の「レイヤー」で 1 つ選ぶと、ここで位置・大きさ・切り取り・マスク・エッジブレンド・四隅を調整できる", "Select a layer at the left to adjust its transform, crop, mask, edge blend and corner pin here"))
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
        Text(L("上から順に進めると、1 台で試すところから展示の形まで覚えられる。できたら ✓ が付く（この Mac で見えたことだけ）。", "Work from the top to learn everything from one Mac to an exhibition. A ✓ appears when done (only what this Mac can see)."))
            .font(.caption).foregroundColor(.secondary)
        Button(L("練習用のショーを開く", "Open the Practice Show")) { model.openPractice() }
            .help(L("番号入りの映像 4 本と丸いマスクの見本。保存したショーはファイルに残る（保存前のショーは、替える前に確かめる）", "4 numbered clips and a round mask. Saved shows stay in their files (an unsaved show asks first)"))
        Button(L("サンプル（映像と設定）をダウンロード…", "Download Samples (clips and shows)…")) {
            if let u = URL(string: "https://github.com/akiranakayasu-eng/sync-player/releases/latest") { NSWorkspace.shared.open(u) }
        }
        .help(L("音入りの映像と、そのまま開けるショーの一式（アプリとは別の zip、samples と付いたもの）を配っているページを開く。展開したら中の使い方.txt を見る", "Opens the page with clips with sound and ready-made shows (the zip named samples, separate from the app). Read the text file inside after unzipping"))

        StepHeader(title: L("1. 1 台で動かす", "1. Play on one Mac"), anchor: "step1")
        StepLine(done: !model.show.clips.isEmpty, text: L("映像を開く（練習用でも自分の映像でも）", "Open clips (practice or your own)"))
        StepLine(done: model.learnedSet.contains("played"), text: L("再生・停止する（space か上の「再生」）", "Play and stop (space or ▶ at the top)"))
        StepLine(done: model.learnedSet.contains("fullscreen"), text: L("左の「全画面にする（F）」を入れ、S で操作の窓を出し入れする", "Turn on Full Screen (F) at the left; S shows and hides the control window"))

        StepHeader(title: L("2. 画面を作る", "2. Build the picture"), anchor: "step2")
        StepLine(done: model.learnedSet.contains("added"), text: L("左の「映像ライブラリ」の ＋ か、右クリックの「差し替え」で自分の映像を入れる", "Add your clips with + or right-click › Replace Footage in Footage"))
        StepLine(done: model.learnedSet.contains("adjusted"), text: L("「画面の調整」で位置・大きさ・四隅などを変える（⌘Z で戻せる）", "Change position, scale, corners in the Layer tab (⌘Z undoes)"))
        StepLine(done: model.learnedSet.contains("mask"), text: L("自分のマスク画像を使う（なくてもよい）", "Use your own mask image (optional)"))
        StepLine(done: model.showFile != nil, text: L("上の「保存…」でショーを保存する", "Save the show with the save button at the top"))

        StepHeader(title: L("3. 何台かでそろえる", "3. Sync several Macs"), anchor: "step3")
        StepLine(done: model.learnedSet.contains("ident"), text: L("N で Mac の名前とディスプレイの番号を出す", "Press N to show Mac names and display numbers"))
        StepLine(done: model.learnedSet.contains("synced"), text: L("同じネットワークの別の Mac をフォロワーにして、札が緑になる（フォロワーの Mac で ✓）", "Make another Mac on the same network a follower; its badge turns green (✓ on the follower)"))

        StepHeader(title: L("4. 展示の形にする", "4. Set up the exhibition"), anchor: "step4")
        StepLine(done: model.openAtLogin, text: L("「展示の設定」で「ログインしたら開く」を入れる（全台）", "In Exhibit, turn on Open at Login (all Macs)"))
        StepLine(done: model.exhibitMaster, text: L("「展示のマスター」を 1 台だけに入れる（マスターの Mac で ✓）", "Turn on Exhibition Master on one Mac only (✓ on the master)"))
        Toggle(L("電源を切って入れ直し、同じ状態に戻るのを見た", "Restarted and saw it come back the same"), isOn: $rebootChecked)
            .font(.callout)

        Divider()
        Button(L("✓ の記録を消す", "Clear ✓ Marks")) { model.forgetLearned(); rebootChecked = false }
            .controlSize(.small)
            .help(L("次の人が最初から練習するとき", "For the next person to start from the beginning"))
    }

    /// Settings for an exhibition: after a restart the Mac comes back as it was.
    @ViewBuilder private var exhibitSection: some View {
        SectionTitle(L("展示の前の点検", "Pre-show Check"), help: "check")
        Button(L("点検する", "Check")) { model.runExhibitCheck() }
            .help(L("展示に入る前に、この Mac の設定とつながりを一度に確かめる", "Check this Mac's settings and connections at once before the exhibition"))
        if let at = model.checkedAt {
            Text(L("点検した時刻 \(at.formatted(date: .omitted, time: .shortened))（直したら、もう一度押す）", "Checked at \(at.formatted(date: .omitted, time: .shortened)) (press again after fixing)"))
                .font(.caption).foregroundColor(.secondary)
            ForEach(model.checks) { c in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: c.ok == true ? "checkmark.circle.fill" : c.ok == false ? "exclamationmark.triangle.fill" : "questionmark.circle")
                        .foregroundColor(c.ok == true ? .green : c.ok == false ? .orange : .secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(c.text).font(.callout).fixedSize(horizontal: false, vertical: true)
                        if c.ok != true {
                            Text(c.ok == nil ? L("アプリからは確かめられない。", "Can't be checked from the app.") + c.fix : c.fix)
                                .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }

        if model.isMaster {
            Divider()
            SectionTitle(L("つながっている Mac", "Connected Macs"), help: "macs")
            if model.peers.isEmpty {
                Text(L("フォロワーはまだ見えない。ほかの Mac で SyncPlayer を開くと、ここに並ぶ。", "No followers yet. Open SyncPlayer on other Macs and they appear here."))
                    .font(.caption).foregroundColor(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 3) {
                    GridRow {
                        Text(L("名前", "Name")).foregroundColor(.secondary)
                        Text(L("席", "Seat")).foregroundColor(.secondary)
                        Text(L("ずれ", "Error")).foregroundColor(.secondary)
                        Text(L("版・注意", "Version / Notes")).foregroundColor(.secondary)
                    }
                    ForEach(Array(model.peers.enumerated()), id: \.offset) { _, p in
                        GridRow {
                            Text(p.name).lineLimit(1).truncationMode(.middle)
                            let clash = model.seatClash(p.seat)
                            Text(p.seat.map { clash ? "⚠︎ " + $0 : $0 } ?? "—").lineLimit(1)
                                .foregroundColor(clash ? .orange : .primary)
                                .help(clash ? L("同じ席の Mac がほかにもあります。どちらかの席を変えてください", "Another Mac is the same seat. Change the seat on one of them") : "")
                            Text(p.err.map { String(format: "%.1f ms", abs($0)) } ?? "—")
                                .font(.system(size: 11, design: .monospaced))
                            let other = p.ver != AppModel.version
                            Text(other ? (p.ver == "?" ? L("⚠︎ 古い版", "⚠︎ old version") : L("⚠︎ 版 \(p.ver)", "⚠︎ version \(p.ver)")) : (p.warn.map { "⚠︎ " + $0 } ?? "OK"))
                                .foregroundColor(other || p.warn != nil ? .orange : .secondary)
                                .lineLimit(2).help(p.warn ?? p.ver)
                        }
                    }
                }
                .font(.caption)
            }
        }

        Divider()
        SectionTitle(L("いまのこの Mac", "This Mac"), help: "exhibit")
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
            GridRow { Text(L("操作の窓の色", "Appearance")).foregroundColor(.secondary)
                      Picker("", selection: Binding(get: { model.uiTheme }, set: { model.uiTheme = $0 })) {
                          ForEach(AppModel.UITheme.allCases) { Text($0.label).tag($0) }
                      }
                      .labelsHidden().pickerStyle(.segmented).fixedSize()
                      .help(L("ライトかダーク。この Mac だけの設定", "Light or dark. This Mac only")) }
            GridRow { Text("Language / 言語").foregroundColor(.secondary)
                      Picker("", selection: Binding(get: { model.uiLang }, set: { model.uiLang = $0 })) {
                          ForEach(UILang.allCases) { Text($0.label).tag($0) }
                      }
                      .labelsHidden().pickerStyle(.segmented).fixedSize()
                      .help("English / 日本語 (this Mac only・この Mac だけ)") }
            GridRow { Text(L("名前", "Name")).foregroundColor(.secondary); Text(model.opts.name) }
            GridRow { Text(L("版", "Version")).foregroundColor(.secondary); Text(AppModel.version) }
            GridRow { Text(L("役", "Role")).foregroundColor(.secondary); Text(model.isMaster ? L("マスター", "Master") : L("フォロワー", "Follower")) }
            GridRow { Text(L("展示のマスター", "Exhibition master")).foregroundColor(.secondary); Text(model.exhibitMaster ? L("はい（開くとマスターで始まる）", "Yes (starts as master)") : L("いいえ", "No")) }
            GridRow { Text(L("ログインで開く", "Open at login")).foregroundColor(.secondary); Text(model.openAtLogin ? L("はい", "Yes") : L("いいえ", "No")) }
            GridRow { Text(L("ショー", "Show")).foregroundColor(.secondary)
                      Text(model.showFile.map { ($0 as NSString).lastPathComponent } ?? L("まだ保存していない", "Not saved yet")).lineLimit(1).truncationMode(.middle) }
        }
        .font(.callout)

        Divider()
        SectionTitle(L("展示の設定（設営のとき 1 度だけ）", "Exhibition Setup (once, when installing)"))
        Toggle(L("ログインしたら SyncPlayer を開く", "Open SyncPlayer at Login"), isOn: Binding(get: { model.openAtLogin }, set: { model.openAtLogin = $0 }))
        Text(L("全台で入れる。再起動のあとログインするだけで、前と同じ全画面・音・マスクに戻る。", "Turn on for all Macs. After a restart, logging in brings back the same full screen, sound and masks."))
            .font(.caption).foregroundColor(.secondary)
        Toggle(L("この Mac を展示のマスターにする", "Make This Mac the Exhibition Master"), isOn: Binding(get: { model.exhibitMaster }, set: { model.setExhibitMaster($0) }))
        Text(L("全台のうち 1 台だけに入れる。入れるとすぐマスターになり、次から開くとマスターで始まって 3 秒後に自動で再生する。ほかの Mac は何もしなくてもフォロワーになり、どちらが先に開いても数秒でそろう。マスターを開き直すと、全台が頭から始め直す（2〜3 秒止まる）。", "One Mac only. It becomes master now, and from then on starts as master and plays 3 s after opening. The other Macs become followers by themselves and sync within seconds in any order. Reopening the master restarts all Macs from the top (2–3 s pause)."))
            .font(.caption).foregroundColor(.secondary)

        Divider()
        SectionTitle(L("確かめる・困ったとき", "Checks and Troubleshooting"), help: "trouble")
        if model.netBlocked {
            Text(L("⚠︎ この Mac からネットワークに届いていない。ローカルネットワークの許可が切れているか、ネットワークにつながっていない。", "⚠︎ This Mac can't reach the network. Local Network permission is off, or it isn't connected."))
                .font(.caption).foregroundColor(.orange)
            Button(L("ローカルネットワークの設定を開く", "Open Local Network Settings")) { model.openLocalNetworkSettings() }
        }
        Toggle(L("名前とディスプレイの番号を大きく出す（N）", "Show Names and Display Numbers (N)"), isOn: $model.showIdent)
        Text(L("どの Mac のどのディスプレイかを確かめる。マスターで入れると全台に出る。", "Find which Mac and display is which. On the master it shows on all Macs.")).font(.caption).foregroundColor(.secondary)
        Toggle(L("動作確認の文字を出す（I）", "Show Info Text (I)"), isOn: Binding(get: { model.infoShownNow }, set: { model.setInfoShown($0) }))
        Text(L("出力の窓に、ずれなどの数字を出す。展示中は消しておく。", "Shows sync numbers on the outputs. Turn off during the exhibition.")).font(.caption).foregroundColor(.secondary)
        if model.isMaster {
            Button(L("全台を頭からやり直す（R）", "Restart All from the Top (R)")) { model.master?.jump(to: 0) }
        }
        Text(L("1 台だけ映らない・ずれるときは、その Mac で Q キーを押して SyncPlayer を終了し、開き直す（数秒でそろう）。全部止まったときは、展示のマスターの Mac を開き直す。", "If one Mac is blank or off, press Q on it to quit SyncPlayer and reopen it (syncs in seconds). If all stopped, reopen the exhibition master."))
            .font(.caption).foregroundColor(.secondary)
    }

    @ViewBuilder private var layerSection: some View {
        SelectedLayerHeader(model: model)
        Picker(L("映像", "Source"), selection: model.layerBinding(\.clipID, "")) {
            ForEach(model.show.clips) { c in Text(c.name).tag(c.id) }
        }
        SliderRow(label: L("不透明度", "Opacity"), value: model.layerBinding(\.opacity, 1), range: 0...1, defaultValue: 1, unit: ValueText.percent)

        DisclosureGroup(isExpanded: $openPlace) {
            VStack(alignment: .leading, spacing: 6) {
                SliderRow(label: L("横の位置", "Position X"), value: model.lookBinding(\.posX, 0), range: -1...1, defaultValue: 0, unit: ValueText.signedPercent,
                          help: L("レイヤーの枠（4 分割なら 1 ます）の幅に対する割合。＋で右へ", "Fraction of the layer frame's width (one cell when tiled). + is right"))
                SliderRow(label: L("縦の位置", "Position Y"), value: model.lookBinding(\.posY, 0), range: -1...1, defaultValue: 0, unit: ValueText.signedPercent,
                          help: L("レイヤーの枠の高さに対する割合", "Fraction of the layer frame's height"))
                SliderRow(label: L("大きさ", "Scale"), value: model.lookBinding(\.scale, 1), range: 0.1...4, defaultValue: 1, unit: ValueText.percent,
                          help: L("100% でレイヤーの枠いっぱい", "100% fills the layer frame"))
                SliderRow(label: L("回転", "Rotation"), value: model.lookBinding(\.rotation, 0), range: -180...180, defaultValue: 0, unit: ValueText.degrees)
                Button(L("位置・大きさ・回転を戻す（0）", "Reset Transform (0)")) {
                    guard var s = model.selectedLook else { return }
                    s.resetTransform(); model.updateLook(s)
                }
            }
            .padding(.top, 4)
        } label: { FoldLabel(title: L("位置・大きさ・回転", "Transform"), isOpen: $openPlace, help: "place") }

        DisclosureGroup(isExpanded: $openCrop) {
            VStack(alignment: .leading, spacing: 6) {
                SliderRow(label: L("左", "Left"), value: model.lookBinding(\.cropL, 0), range: 0...0.5, defaultValue: 0, unit: ValueText.percent)
                SliderRow(label: L("右", "Right"), value: model.lookBinding(\.cropR, 0), range: 0...0.5, defaultValue: 0, unit: ValueText.percent)
                SliderRow(label: L("上", "Top"), value: model.lookBinding(\.cropT, 0), range: 0...0.5, defaultValue: 0, unit: ValueText.percent)
                SliderRow(label: L("下", "Bottom"), value: model.lookBinding(\.cropB, 0), range: 0...0.5, defaultValue: 0, unit: ValueText.percent)
            }
            .padding(.top, 4)
        } label: { FoldLabel(title: L("切り取り（映像の端を削る）", "Crop"), isOpen: $openCrop, help: "crop") }

        DisclosureGroup(isExpanded: $openMask) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Button(L("画像を選ぶ…", "Choose Image…")) { model.pickMask() }
                    Button(L("外す", "Remove")) { model.layerBinding(\.mask, nil as String?).wrappedValue = nil }
                        .disabled(model.selectedLayerIndex.map { model.show.outputs[$0.o].layers[$0.l].mask == nil } ?? true)
                }
                let maskPath = model.selectedLayerIndex.flatMap { model.show.outputs[$0.o].layers[$0.l].mask }
                let maskOK = maskPath.map { FileManager.default.fileExists(atPath: $0) && GPU.shared?.maskReady($0) != false } ?? true
                Text(maskPath.map { ($0 as NSString).lastPathComponent + (maskOK ? "" : L("（見つからない・読めない）", " (missing or unreadable)")) } ?? L("なし", "None"))
                    .font(.caption).foregroundColor(maskOK ? .secondary : .red)
                Toggle(L("白黒を入れ替える", "Invert"), isOn: model.layerBinding(\.maskInvert, false))
                Text(L("白は見え、黒は隠れる（灰色は半分）。画像は映像の枠全体に重なり、レイヤーといっしょに動く。映像と同じ縦横比の画像にする。", "White shows, black hides (grey is half). The image covers the whole clip and moves with the layer. Use the clip's aspect ratio."))
                    .font(.caption).foregroundColor(.secondary)
            }
            .padding(.top, 4)
        } label: { FoldLabel(title: L("マスク（白黒の画像で形を抜く）", "Mask"), isOpen: $openMask, warn: maskBroken, help: "mask") }

        DisclosureGroup(isExpanded: $openBlend) {
            VStack(alignment: .leading, spacing: 6) {
                SliderRow(label: L("左", "Left"), value: model.lookBinding(\.blendL, 0), range: 0...0.5, defaultValue: 0, unit: ValueText.percent)
                SliderRow(label: L("右", "Right"), value: model.lookBinding(\.blendR, 0), range: 0...0.5, defaultValue: 0, unit: ValueText.percent)
                SliderRow(label: L("上", "Top"), value: model.lookBinding(\.blendT, 0), range: 0...0.5, defaultValue: 0, unit: ValueText.percent)
                SliderRow(label: L("下", "Bottom"), value: model.lookBinding(\.blendB, 0), range: 0...0.5, defaultValue: 0, unit: ValueText.percent)
                SliderRow(label: L("ガンマ", "Gamma"), value: model.lookBinding(\.blendGamma, 2.2), range: 0.5...4, defaultValue: 2.2,
                          help: L("重なりの明るさの合い方。ふつうは 2.2", "How brightness matches in the overlap. Usually 2.2"))
                Text(L("重なる幅を、画面の幅（高さ）に対する割合で。", "Overlap width as a fraction of the picture's width (height).")).font(.caption).foregroundColor(.secondary)
            }
            .padding(.top, 4)
        } label: { FoldLabel(title: L("エッジブレンド（プロジェクターの重なり）", "Edge Blend"), isOpen: $openBlend, help: "blend") }

        DisclosureGroup(isExpanded: $openWarp) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Button(model.editMode == .corners ? L("四隅の編集を終える", "Done") : L("四隅を動かす（E）", "Corner Pin (E)")) { model.toggleEdit(.corners) }
                    Button(model.editMode == .mesh ? L("曲面の編集を終える", "Done") : L("曲面メッシュ（W）", "Mesh (W)")) { model.toggleEdit(.mesh) }
                }
                Stepper(L("メッシュの点 \(model.selectedLook?.meshCols ?? 4)×\(model.selectedLook?.meshRows ?? 4)", "Mesh Points \(model.selectedLook?.meshCols ?? 4)×\(model.selectedLook?.meshRows ?? 4)"),
                        onIncrement: { meshSize(+1) }, onDecrement: { meshSize(-1) })
                HStack {
                    Button(L("四隅を戻す", "Reset Corners")) { guard var s = model.selectedLook else { return }; s.resetCorners(); model.updateLook(s) }
                    Button(L("メッシュを戻す", "Reset Mesh")) { guard var s = model.selectedLook else { return }; s.resetMesh(); model.updateLook(s) }
                }
                Toggle(L("確認用の格子（G）", "Grid (G)"), isOn: model.lookBinding(\.showGrid, false))
                Text(L("点はプレビューか出力の窓でドラッグ。Tab で次の点、矢印で 1 px（shift で 10 px）。", "Drag points in the preview or an output. Tab: next point, arrows: 1 px (shift: 10 px)."))
                    .font(.caption).foregroundColor(.secondary)
            }
            .padding(.top, 4)
        } label: { FoldLabel(title: L("四隅・曲面（台形や曲がりを直す）", "Corner Pin & Mesh"), isOpen: $openWarp, help: "warp") }
        .id("warp")
    }

    private func meshSize(_ d: Int) {
        guard var s = model.selectedLook else { return }
        let n = min(8, max(2, s.meshCols + d))
        guard n != s.meshCols || s.meshRows != n else { return }
        s.setMeshSize(n)
        model.updateLook(s)
    }

}

extension Text {
    /// A number that can be clicked and typed: blue with a dotted underline, like After Effects
    /// (Akira 2026-11-25). Plain when it cannot be changed here (e.g. on a follower).
    func editableNumber(_ on: Bool = true) -> Text {
        guard on else { return self }
        return self.foregroundColor(Color(nsColor: UIColors.editable))
            .underline(true, pattern: .dot, color: Color(nsColor: UIColors.editable).opacity(0.8))
    }
}

/// SyncPlayer ▸ Settings… (⌘,): this Mac's own preferences. The same look and language are also in
/// Exhibit › This Mac.
struct SettingsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Form {
            Section(L("見た目", "Appearance")) {
                Picker(L("操作の窓の色", "Appearance"), selection: Binding(get: { model.uiTheme }, set: { model.uiTheme = $0 })) {
                    ForEach(AppModel.UITheme.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Language / 言語", selection: Binding(get: { model.uiLang }, set: { model.uiLang = $0 })) {
                    ForEach(UILang.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Section(L("確かめの窓を出す（切っても ⌘Z で戻せます）", "Ask before (⌘Z undoes either way)")) {
                ForEach(AppModel.ConfirmKind.allCases) { k in
                    Toggle(k.label, isOn: model.asksBinding(k))
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }
}
