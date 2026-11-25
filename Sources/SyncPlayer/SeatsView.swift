import AppKit
import SwiftUI

/// The seat's letter (A, B, C … by its place in the list), filled when it is this Mac's seat.
struct SeatBadge: View {
    let index: Int
    var on = false
    var size: CGFloat = 20
    static func letter(_ i: Int) -> String {
        i < 26 ? String(Character(UnicodeScalar(UInt8(65 + i)))) : "\(i + 1)"
    }
    var body: some View {
        Text(SeatBadge.letter(index))
            .font(.system(size: size * 0.6, weight: .bold, design: .rounded))
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.25)
                .fill(on ? Color.accentColor : Color(nsColor: .quaternaryLabelColor)))
            .foregroundColor(on ? .white : .primary)
    }
}

/// Top bar: which seat this Mac is, as a menu to change it (only when the show has several seats).
struct SeatChip: View {
    @ObservedObject var model: AppModel
    var body: some View {
        if model.show.seats.count > 1 {
            Menu {
                ForEach(Array(model.show.seats.enumerated()), id: \.element.id) { k, st in
                    Button {
                        model.switchSeat(st.id)
                    } label: {
                        if st.id == model.show.seatID { Label("\(SeatBadge.letter(k))  \(st.name)", systemImage: "checkmark") }
                        else { Text("\(SeatBadge.letter(k))  \(st.name)") }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    SeatBadge(index: model.show.seatIndex, on: true, size: 18)
                    Text(model.show.seat.name).font(.callout.bold()).lineLimit(1)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(L("この Mac の席（押して変える）。出力・レイヤー・音はこの席のもの", "This Mac's seat (click to change). Outputs, layers and sound are this seat's"))
        }
    }
}

/// Shown when a show with several seats is opened on a Mac that has not chosen its seat yet.
struct SeatChooserView: View {
    let show: Show
    let current: String?
    let done: (String?) -> Void
    @State private var picked: String?

    private func summary(_ st: Seat) -> String {
        let layers = st.outputs.flatMap(\.layers)
        let names = layers.reversed().map { l in l.name ?? show.clip(l.clipID)?.name ?? "" }.filter { !$0.isEmpty }
        let head = L("出力 \(st.outputs.count) · レイヤー \(layers.count)", "\(st.outputs.count) output(s) · \(layers.count) layer(s)")
        return names.isEmpty ? head : head + "\n" + names.prefix(4).joined(separator: L("、", ", ")) + (names.count > 4 ? "…" : "")
    }

    var body: some View {
        let sel = picked ?? current ?? show.seats.first?.id
        VStack(alignment: .leading, spacing: 12) {
            Text(L("この Mac はどの席ですか", "Which seat is this Mac?")).font(.title2.bold())
            Text(L("この展示には \(show.seats.count) つの席があります。席は Mac 1 台とそのプロジェクターの組です。選んだ席はこの Mac が覚え、次からは聞きません（あとから上の席の札で変えられます）。",
                   "This show has \(show.seats.count) seats. A seat is one Mac and its projectors. This Mac remembers the seat you choose and won't ask again (change it later with the seat label at the top)."))
                .font(.callout).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 10)], spacing: 10) {
                    ForEach(Array(show.seats.enumerated()), id: \.element.id) { k, st in
                        let on = st.id == sel
                        VStack(alignment: .leading, spacing: 4) {
                            Text(SeatBadge.letter(k)).font(.system(size: 26, weight: .bold, design: .rounded))
                            Text(st.name).font(.headline).lineLimit(1)
                            Text(summary(st)).font(.caption).foregroundColor(.secondary)
                                .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 9).fill(on ? Color.accentColor.opacity(0.22) : Color(nsColor: UIColors.panel)))
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(on ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: on ? 2 : 1))
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { done(st.id) }
                        .onTapGesture { picked = st.id }
                    }
                }
            }
            HStack {
                Spacer()
                Button(L("あとで（最初の席にする）", "Later (use the first seat)")) { done(nil) }
                    .keyboardShortcut(.cancelAction)
                Button(L("\(show.seats.first { $0.id == sel }?.name ?? "") にする", "Use \(show.seats.first { $0.id == sel }?.name ?? "")")) { done(sel) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(sel == nil)
            }
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 320)
    }
}

/// File > 素材をまとめる: what will be copied, then where.
struct CollectView: View {
    @ObservedObject var model: AppModel
    @State private var zip = false
    @State private var seatOnly = false
    @State private var reveal = true

    private func sizeText(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }

    var body: some View {
        let s = Collect.scoped(model.show, seat: seatOnly ? model.show.seatID : nil)
        let items = Collect.items(s)
        let found = items.filter { $0.size != nil }
        let total = found.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
        let missing = items.filter { $0.size == nil }
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text(L("形", "Format")).foregroundColor(.secondary)
                    Picker("", selection: $zip) {
                        Text(L("フォルダ", "Folder")).tag(false)
                        Text("zip").tag(true)
                    }.pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                if model.show.seats.count > 1 {
                    GridRow {
                        Text(L("含める席", "Seats")).foregroundColor(.secondary)
                        Picker("", selection: $seatOnly) {
                            Text(L("全席", "All seats")).tag(false)
                            Text(L("この Mac の席だけ（\(model.show.seat.name)）", "This Mac's seat only (\(model.show.seat.name))")).tag(true)
                        }.pickerStyle(.segmented).labelsHidden().fixedSize()
                    }
                }
            }
            Table(items) {
                TableColumn("") { i in
                    Text(i.size == nil ? "!" : "✓").bold().foregroundColor(i.size == nil ? .orange : .green)
                }.width(16)
                TableColumn(L("ファイル", "File")) { i in
                    HStack(spacing: 4) {
                        Image(systemName: i.kind == "mask" ? "circle.lefthalf.filled" : "film").foregroundColor(.secondary)
                        Text(i.name).lineLimit(1).truncationMode(.middle).help(i.path)
                        if i.size == nil { Text(L("見つからない", "Missing")).foregroundColor(.orange).font(.caption.bold()) }
                    }
                }
                TableColumn(L("使う席", "Seats")) { i in
                    Text(i.seats.isEmpty ? "—" : i.seats.joined(separator: " · ")).foregroundColor(.secondary)
                }.width(min: 60, ideal: 110)
                TableColumn(L("大きさ", "Size")) { i in
                    if let b = i.size { Text(sizeText(b)).monospacedDigit() }
                    else { Button(L("探す…", "Locate…")) { model.relink(i) }.controlSize(.small) }
                }.width(min: 70, ideal: 90)
            }
            .frame(minHeight: 200)
            HStack(alignment: .top, spacing: 16) {
                Text(L("中身: ショー（.syncshow）、movies/、masks/、report.txt。ショーの中の場所は、このフォルダからの相対の場所になります。運んだ先の Mac では .syncshow を開いて席を選ぶだけです。",
                       "Inside: the show (.syncshow), movies/, masks/, report.txt. Paths in the show become relative to the folder. On the other Mac, just open the .syncshow and choose the seat."))
                    .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(L("合計 \(sizeText(total))（\(items.count) 件中 \(found.count) 件）", "Total \(sizeText(total)) (\(found.count) of \(items.count))")).bold()
                    if !missing.isEmpty {
                        Text(L("\(missing.count) 件見つかりません。このまま書き出すと、その映像・マスクは空になります。",
                               "\(missing.count) not found. If you collect now, they will be empty."))
                            .font(.caption).foregroundColor(.orange).multilineTextAlignment(.trailing)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }.frame(width: 260, alignment: .trailing)
            }
            Divider()
            HStack {
                Toggle(L("書き出したあと Finder で表示", "Show in Finder afterwards"), isOn: $reveal)
                Spacer()
                Button(L("キャンセル", "Cancel")) { model.closeCollectWindow() }
                    .keyboardShortcut(.cancelAction)
                Button(model.collecting ? L("まとめています…", "Collecting…") : L("書き出す…", "Collect…")) {
                    model.collect(zip: zip, seatOnly: seatOnly, reveal: reveal)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.collecting || found.isEmpty)
            }
        }
        .padding(16)
        .frame(minWidth: 640, minHeight: 440)
        .id(model.uiLang)
    }
}
