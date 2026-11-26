import Foundation
import UniformTypeIdentifiers

/// A movie file used by the show. All clips play on one shared timeline (same schedule);
/// each loops by its own length.
struct Clip: Codable, Equatable, Identifiable {
    var id: String
    var path: String
    var name: String { (path as NSString).lastPathComponent }
}

/// One picture on an output: which clip, and how it is placed (transform, crop, blend, warp).
/// Layers of an output are drawn in array order: the first is at the back.
struct Layer: Codable, Equatable, Identifiable {
    var id = UUID().uuidString
    var clipID: String
    var visible = true
    var opacity = 1.0
    var look = DisplaySettings()
    /// Mask image (path): white shows the picture, black hides it, grey fades. It covers the
    /// whole movie frame (before cropping) and moves with the layer. nil = no mask.
    var mask: String?
    /// Swap white and black of the mask.
    var maskInvert = false
    /// The layer's own name (nil = shown by its movie's name).
    var name: String?

    init(clipID: String, look: DisplaySettings = DisplaySettings()) {
        self.clipID = clipID
        self.look = look
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        clipID = try c.decode(String.self, forKey: .clipID)
        visible = try c.decodeIfPresent(Bool.self, forKey: .visible) ?? true
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 1
        look = try c.decodeIfPresent(DisplaySettings.self, forKey: .look) ?? DisplaySettings()
        mask = try c.decodeIfPresent(String.self, forKey: .mask)
        maskInvert = try c.decodeIfPresent(Bool.self, forKey: .maskInvert) ?? false
        name = try c.decodeIfPresent(String.self, forKey: .name)
    }
}

/// Edge blend of a Screen: its edges fade to black where two projectors overlap (fraction of the
/// Screen's width / height) and the gamma of that fade. It belongs to the Screen, not to a layer
/// (Akira 2026-11-26), and applies to every layer drawn on it.
struct EdgeBlend: Codable, Equatable {
    var l = 0.0, r = 0.0, t = 0.0, b = 0.0
    var gamma = 2.2

    init(l: Double = 0, r: Double = 0, t: Double = 0, b: Double = 0, gamma: Double = 2.2) {
        self.l = l; self.r = r; self.t = t; self.b = b; self.gamma = gamma
    }
    /// A missing value reads as its default (a file edited by hand still opens; check 63 L3).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        l = try c.decodeIfPresent(Double.self, forKey: .l) ?? 0
        r = try c.decodeIfPresent(Double.self, forKey: .r) ?? 0
        t = try c.decodeIfPresent(Double.self, forKey: .t) ?? 0
        b = try c.decodeIfPresent(Double.self, forKey: .b) ?? 0
        gamma = try c.decodeIfPresent(Double.self, forKey: .gamma) ?? 2.2
    }
}

/// One output window (a Screen): the display or projector it goes to and the layers drawn on it.
struct OutputConfig: Codable, Equatable, Identifiable {
    var id = UUID().uuidString
    var name: String
    var screen = 0
    var fullscreen = false
    var layers: [Layer] = []
    var blend = EdgeBlend()

    init(name: String, screen: Int = 0, fullscreen: Bool = false, layers: [Layer] = []) {
        self.name = name
        self.screen = screen
        self.fullscreen = fullscreen
        self.layers = layers
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Screen"
        // The default names of 0.3.4 and before ("出力 2", "Output 2", "出力", "練習の出力") read as
        // Screen (Akira 2026-11-26: one word, Screen). Only files of those versions (no "blend" key
        // on the Screen yet), so a name typed in this version stays as typed.
        if !c.contains(.blend) {
            for old in ["出力 ", "Output "] where name.hasPrefix(old) && Int(name.dropFirst(old.count)) != nil {
                name = "Screen " + name.dropFirst(old.count)
            }
            if name == "出力" || name == "Output" { name = "Screen" }
            if name == "練習の出力" { name = "練習の Screen" }
        }
        screen = try c.decodeIfPresent(Int.self, forKey: .screen) ?? 0
        fullscreen = try c.decodeIfPresent(Bool.self, forKey: .fullscreen) ?? false
        layers = try c.decodeIfPresent([Layer].self, forKey: .layers) ?? []
        if let b = try c.decodeIfPresent(EdgeBlend.self, forKey: .blend) {
            blend = b
        } else {
            // 0.3.4 and before kept the edge blend on each layer: the Screen takes the widest of each side.
            let looks = layers.map(\.look)
            blend.l = looks.map(\.blendL).max() ?? 0
            blend.r = looks.map(\.blendR).max() ?? 0
            blend.t = looks.map(\.blendT).max() ?? 0
            blend.b = looks.map(\.blendB).max() ?? 0
            if let g = looks.first(where: { $0.blendL + $0.blendR + $0.blendT + $0.blendB > 0 })?.blendGamma { blend.gamma = g }
        }
        blend.gamma = min(4, max(0.5, blend.gamma))
    }
}

/// One place in the exhibition: a Mac and the projectors / displays it drives. Each seat has its
/// own outputs (and their layers) and its own sound. Every Mac opens the same show file and
/// remembers which seat it is.
struct Seat: Codable, Equatable, Identifiable {
    var id = UUID().uuidString
    var name: String
    var outputs: [OutputConfig] = []
    /// The clip whose sound this seat plays (nil = the first clip it uses).
    var audioClip: String?
    /// This seat plays sound (nil = not set: only a Mac started as master).
    var audioOn: Bool?

    init(name: String, outputs: [OutputConfig] = [], audioClip: String? = nil, audioOn: Bool? = nil) {
        self.name = name
        self.outputs = outputs
        self.audioClip = audioClip
        self.audioOn = audioOn
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "A"
        outputs = try c.decodeIfPresent([OutputConfig].self, forKey: .outputs) ?? []
        audioClip = try c.decodeIfPresent(String.self, forKey: .audioClip)
        audioOn = try c.decodeIfPresent(Bool.self, forKey: .audioOn)
    }
}

/// The whole exhibition: the clips (shared by all seats), the seats with their outputs and layers,
/// and the loop. Saved as one .syncshow file (JSON) that every Mac opens.
/// outputs / audioClip / audioOn are those of the seat this Mac is (seatID, kept per Mac, not in the file).
struct Show: Codable, Equatable {
    /// 3 since 0.3.5: position / scale / rotation move the whole layer (before: the picture inside it).
    var version = 3
    /// Layers of this Mac's seat that moved, scaled or turned their picture in a file of version 2 or
    /// older: they look different since 0.3.5 (check 63 M2). 0 for a file of this version.
    var oldTransforms: Int {
        guard version < 3 else { return 0 }
        let d = DisplaySettings()
        return outputs.flatMap(\.layers).filter {
            $0.look.posX != d.posX || $0.look.posY != d.posY || $0.look.scale != d.scale || $0.look.rotation != d.rotation
        }.count
    }
    /// Identifies the exhibition, so each Mac can remember its seat in it (also after copying the file).
    var id = UUID().uuidString
    var clips: [Clip] = []
    var seats: [Seat] = [Seat(name: "A")]
    /// The seat this Mac is (not saved in the file).
    var seatID = ""
    /// Loop all clips on all Macs together (a shorter clip holds its last frame). Used on the master.
    var loopTogether = true
    /// Loop length in seconds when looping together; 0 = the longest clip on any Mac.
    var loopLength = 0.0

    var seatIndex: Int {
        seats.firstIndex(where: { $0.id == seatID }) ?? 0
    }
    var seat: Seat { seats.isEmpty ? Seat(name: "A") : seats[seatIndex] }

    /// This Mac's outputs (those of its seat).
    var outputs: [OutputConfig] {
        get { seat.outputs }
        set { ensureSeat(); seats[seatIndex].outputs = newValue }
    }
    /// The clip whose sound is played on this Mac (nil = the first clip its seat uses).
    var audioClip: String? {
        get { seat.audioClip }
        set { ensureSeat(); seats[seatIndex].audioClip = newValue }
    }
    /// This Mac plays sound (nil = not set: only a Mac started with --master).
    var audioOn: Bool? {
        get { seat.audioOn }
        set { ensureSeat(); seats[seatIndex].audioOn = newValue }
    }
    private mutating func ensureSeat() { if seats.isEmpty { seats = [Seat(name: "A")]; seatID = seats[0].id } }

    /// The clips this Mac plays: those on its seat's layers and its sound clip (the first clip when
    /// the seat uses none yet, so there is still a length and a clock to follow).
    var seatClips: [Clip] {
        var used = Set(outputs.flatMap { $0.layers.map(\.clipID) })
        if let a = audioClip { used.insert(a) }
        let c = clips.filter { used.contains($0.id) }
        return c.isEmpty ? Array(clips.prefix(1)) : c
    }

    init(clips: [Clip] = [], outputs: [OutputConfig] = [], audioClip: String? = nil) {
        self.clips = clips
        self.seats = [Seat(name: "A", outputs: outputs, audioClip: audioClip)]
        self.seatID = seats[0].id
    }

    enum CodingKeys: String, CodingKey {
        case version, id, clips, seats, loopTogether, loopLength
        case outputs, audioClip, audioOn   // this seat's, also written so older versions can open the file
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        clips = try c.decode([Clip].self, forKey: .clips)          // required: tells a show from an old preset
        if let ss = try c.decodeIfPresent([Seat].self, forKey: .seats), !ss.isEmpty {
            seats = ss
        } else {
            // A show from before seats: one seat with its outputs and sound.
            let outs = try c.decode([OutputConfig].self, forKey: .outputs)
            seats = [Seat(name: "A", outputs: outs,
                          audioClip: try c.decodeIfPresent(String.self, forKey: .audioClip),
                          audioOn: try c.decodeIfPresent(Bool.self, forKey: .audioOn))]
        }
        // Two seats with the same id (hand-edited file) would be one seat: give the later one a new id.
        var seen = Set<String>()
        for i in seats.indices { if !seen.insert(seats[i].id).inserted { seats[i].id = UUID().uuidString } }
        seatID = seats[0].id
        loopTogether = try c.decodeIfPresent(Bool.self, forKey: .loopTogether) ?? true
        loopLength = max(0, try c.decodeIfPresent(Double.self, forKey: .loopLength) ?? 0)
        if loopLength > 0 && loopLength < Show.minLoop { loopLength = Show.minLoop }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(3, forKey: .version)
        try c.encode(id, forKey: .id)
        try c.encode(clips, forKey: .clips)
        try c.encode(seats, forKey: .seats)
        try c.encode(loopTogether, forKey: .loopTogether)
        try c.encode(loopLength, forKey: .loopLength)
        try c.encode(outputs, forKey: .outputs)
        try c.encodeIfPresent(audioClip, forKey: .audioClip)
        try c.encodeIfPresent(audioOn, forKey: .audioOn)
    }

    /// The same exhibition as saved in the file (this Mac's seat choice left out), for comparing.
    var fileContent: Show { var s = self; s.seatID = ""; return s }

    /// A name for a new seat: the next free letter (A, B, C …), then numbers.
    func newSeatName() -> String {
        let names = Set(seats.map(\.name))
        for u in 65...90 {
            let n = String(Character(UnicodeScalar(UInt8(u))))
            if !names.contains(n) { return n }
        }
        var k = seats.count + 1
        while names.contains("\(k)") { k += 1 }
        return "\(k)"
    }

    func clip(_ id: String) -> Clip? { clips.first { $0.id == id } }

    /// Movie names, as the master announces them (followers warn when theirs differ).
    /// Kept under ~400 bytes so the announcement fits one packet; long lists become a count,
    /// the start of the names and a short hash (the same on every Mac with the same clips).
    var fileLabel: String {
        let full = clips.map(\.name).joined(separator: " + ").precomposedStringWithCanonicalMapping
        guard full.utf8.count > 400 else { return full }
        var h: UInt32 = 2_166_136_261
        for b in full.utf8 { h = (h ^ UInt32(b)) &* 16_777_619 }
        return "\(clips.count) 本（\(String(full.prefix(60)))… #\(String(h, radix: 16))）"
    }

    /// Shortest fixed loop length (s); shorter ones would keep restarting.
    static let minLoop = 0.5

    func newClipID() -> String {
        var n = clips.count + 1
        while clips.contains(where: { $0.id == "c\(n)" }) { n += 1 }
        return "c\(n)"
    }

    /// Place the given layers of an output in a grid (front layer top-left), each filling its cell.
    static func gridCorners(count n: Int) -> [[Double]] {
        guard n > 0 else { return [] }
        let cols = Int(ceil(sqrt(Double(n))))
        let rows = Int(ceil(Double(n) / Double(cols)))
        return (0..<n).map { k in
            let c = k % cols, r = k / cols
            let x0 = Double(c) / Double(cols), x1 = Double(c + 1) / Double(cols)
            let yT = 1 - Double(r) / Double(rows), yB = 1 - Double(r + 1) / Double(rows)
            return [x0, yB, x1, yB, x1, yT, x0, yT]
        }
    }

    /// A new show: these movies, one output, one layer per movie (in a grid when more than one).
    static func make(paths: [String], look: DisplaySettings = DisplaySettings()) -> Show {
        var show = Show()
        for p in paths { show.clips.append(Clip(id: show.newClipID(), path: p)) }
        var out = OutputConfig(name: "Screen 1", screen: look.screen, fullscreen: look.fullscreen)
        out.layers = show.clips.map { Layer(clipID: $0.id, look: look) }
        out.blend = EdgeBlend(l: look.blendL, r: look.blendR, t: look.blendT, b: look.blendB, gamma: look.blendGamma)
        show.outputs = [out]
        if out.layers.count > 1 { show.arrangeGrid(output: 0) }
        return show
    }

    mutating func arrangeGrid(output o: Int) {
        guard outputs.indices.contains(o) else { return }
        let n = outputs[o].layers.count
        let cells = Show.gridCorners(count: n)
        // The list shows the front layer (last in the array) first; give it the first cell.
        for (k, li) in outputs[o].layers.indices.reversed().enumerated() {
            outputs[o].layers[li].look.corners = cells[k]
            outputs[o].layers[li].look.resetMesh()
        }
    }
}

/// Files in ~/Library/Application Support/SyncPlayer/:
///   current.syncshow — the show in use, saved on every change
/// (presets/ from v0.3 and older is no longer used and is left as it is.)
enum ShowStore {
    static var base: URL {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SyncPlayer", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    static var currentURL: URL { base.appendingPathComponent("current.syncshow") }
    static let fileType = UTType("com.nakayasu.syncshow") ?? UTType(filenameExtension: "syncshow", conformingTo: .json) ?? .json

    static func encode(_ show: Show) -> Data? {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? enc.encode(show)
    }

    static func write(_ show: Show, to url: URL) -> Bool {
        guard let d = encode(show) else { return false }
        return (try? d.write(to: url, options: .atomic)) != nil
    }

    /// Reads a show. Paths may be relative to the show file (a collected folder). A movie or mask
    /// that is not at its saved path is looked for next to the show file and in its movies/ and
    /// masks/ folders (so a folder with the show and its files can be copied to another Mac).
    static func read(_ url: URL) -> Show? {
        guard let d = try? Data(contentsOf: url), var s = try? JSONDecoder().decode(Show.self, from: d) else { return nil }
        let folder = url.deletingLastPathComponent()
        let fm = FileManager.default
        func find(_ p: String, _ sub: String) -> String {
            if p.hasPrefix("/") && fm.fileExists(atPath: p) { return p }
            if !p.hasPrefix("/") {
                let rel = folder.appendingPathComponent(p).standardizedFileURL.path
                if fm.fileExists(atPath: rel) { return rel }
            }
            let name = (p as NSString).lastPathComponent
            for cand in [folder.appendingPathComponent(name), folder.appendingPathComponent(sub).appendingPathComponent(name)]
            where fm.fileExists(atPath: cand.path) { return cand.path }
            // Not found: keep it (absolute when it was relative, so it reads the same later).
            return p.hasPrefix("/") ? p : folder.appendingPathComponent(p).standardizedFileURL.path
        }
        for i in s.clips.indices { s.clips[i].path = find(s.clips[i].path, "movies") }
        for k in s.seats.indices {
            for o in s.seats[k].outputs.indices {
                for l in s.seats[k].outputs[o].layers.indices {
                    if let m = s.seats[k].outputs[o].layers[l].mask { s.seats[k].outputs[o].layers[l].mask = find(m, "masks") }
                }
            }
        }
        return s
    }

    /// The show in use last time; on the first v0.3 start, made from v0.2's movie and settings.
    static func loadCurrent() -> Show? {
        if let s = read(currentURL) { return s }
        guard let movie = UserDefaults.standard.string(forKey: "lastMovie"),
              FileManager.default.fileExists(atPath: movie) else { return nil }
        var look = DisplaySettings()
        if let d = try? Data(contentsOf: base.appendingPathComponent("last.json")),
           let s = try? JSONDecoder().decode(DisplaySettings.self, from: d) { look = s }
        return Show.make(paths: [movie], look: look)
    }

    // MARK: this Mac's seat (kept per Mac, by the exhibition's id)

    static func rememberedSeat(_ show: Show) -> String? {
        (UserDefaults.standard.dictionary(forKey: "seats") as? [String: String])?[show.id]
    }

    static func rememberSeat(_ seatID: String, for show: Show) {
        var d = (UserDefaults.standard.dictionary(forKey: "seats") as? [String: String]) ?? [:]
        d[show.id] = seatID
        UserDefaults.standard.set(d, forKey: "seats")
    }
}

/// "Collect Files" (like After Effects): the show and every movie and mask it uses, copied into one
/// folder (or zip) with paths relative to the show, so the folder can be carried to any Mac.
enum Collect {
    struct Item: Identifiable, Equatable {
        var id: String { kind + ":" + path }
        var kind: String          // "movie" or "mask"
        var path: String
        var seats: [String]       // seat names that use it ("" for a clip no seat uses)
        var size: Int64?          // nil = not found
        var name: String { (path as NSString).lastPathComponent }
    }

    /// The show to write: every seat, or only the given seat (and only the clips it uses).
    static func scoped(_ show: Show, seat: String?) -> Show {
        guard let sid = seat, let st = show.seats.first(where: { $0.id == sid }) else { return show }
        var s = show
        s.seats = [st]; s.seatID = st.id
        let used = Set(st.outputs.flatMap { $0.layers.map(\.clipID) } + [st.audioClip].compactMap { $0 })
        s.clips = show.clips.filter { used.contains($0.id) }
        return s
    }

    /// Every file the show uses, with the seats that use it and its size.
    static func items(_ show: Show) -> [Item] {
        let fm = FileManager.default
        func size(_ p: String) -> Int64? {
            guard fm.fileExists(atPath: p) else { return nil }
            return (try? fm.attributesOfItem(atPath: p)[.size] as? NSNumber)?.int64Value ?? 0
        }
        var out: [Item] = []
        for c in show.clips {
            let names = show.seats.filter { st in
                st.audioClip == c.id || st.outputs.contains { $0.layers.contains { $0.clipID == c.id } }
            }.map(\.name)
            out.append(Item(kind: "movie", path: c.path, seats: names, size: size(c.path)))
        }
        var masks: [String: [String]] = [:]
        var order: [String] = []
        for st in show.seats {
            for o in st.outputs { for l in o.layers { if let m = l.mask {
                if masks[m] == nil { order.append(m); masks[m] = [] }
                if !masks[m]!.contains(st.name) { masks[m]!.append(st.name) }
            } } }
        }
        for m in order { out.append(Item(kind: "mask", path: m, seats: masks[m]!, size: size(m))) }
        return out
    }

    struct Result { var folder: URL; var copied: Int; var missing: [String] }

    /// Copies into dest (a new folder named after it): <name>.syncshow, movies/, masks/, report.txt.
    /// zip: makes dest.zip instead and leaves no folder. Runs the copying on the caller's thread.
    static func run(_ show: Show, to dest: URL, zip: Bool) throws -> Result {
        let fm = FileManager.default
        let showName = dest.deletingPathExtension().lastPathComponent
        let work: URL
        if zip {
            work = fm.temporaryDirectory.appendingPathComponent("SyncPlayer-collect-\(UUID().uuidString)")
                .appendingPathComponent(showName, isDirectory: true)
        } else {
            work = dest
            if fm.fileExists(atPath: work.path) {
                throw NSError(domain: "Collect", code: 1, userInfo: [NSLocalizedDescriptionKey:
                    L("「\(work.lastPathComponent)」はもうあります。別の名前にしてください", "“\(work.lastPathComponent)” already exists. Please choose another name")])
            }
        }
        try fm.createDirectory(at: work.appendingPathComponent("movies"), withIntermediateDirectories: true)
        // A failure part way (disk full …) leaves nothing behind, so the same name can be used again.
        var finished = false
        defer { if !finished { try? fm.removeItem(at: zip ? work.deletingLastPathComponent() : work) } }
        var s = show
        var copied = 0
        var missing: [String] = []
        var taken: Set<String> = []
        var done: [String: String] = [:]   // source path -> relative path in the folder
        func place(_ src: String, _ sub: String) throws -> String? {
            if let r = done[src] { return r }
            guard fm.fileExists(atPath: src) else { missing.append(src); return nil }
            let n = (src as NSString).lastPathComponent
            let base = (n as NSString).deletingPathExtension, ext = (n as NSString).pathExtension
            var name = n, k = 2
            while taken.contains(sub + "/" + name.lowercased()) {
                name = ext.isEmpty ? "\(base)-\(k)" : "\(base)-\(k).\(ext)"; k += 1
            }
            taken.insert(sub + "/" + name.lowercased())
            let dir = work.appendingPathComponent(sub, isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try fm.copyItem(at: URL(fileURLWithPath: src), to: dir.appendingPathComponent(name))
            copied += 1
            let rel = sub + "/" + name
            done[src] = rel
            return rel
        }
        for i in s.clips.indices { if let r = try place(s.clips[i].path, "movies") { s.clips[i].path = r } }
        for k in s.seats.indices {
            for o in s.seats[k].outputs.indices {
                for l in s.seats[k].outputs[o].layers.indices {
                    if let m = s.seats[k].outputs[o].layers[l].mask, let r = try place(m, "masks") {
                        s.seats[k].outputs[o].layers[l].mask = r
                    }
                }
            }
        }
        guard ShowStore.write(s, to: work.appendingPathComponent(showName + ".syncshow")) else {
            throw NSError(domain: "Collect", code: 2, userInfo: [NSLocalizedDescriptionKey: L("ショーを書けませんでした", "Couldn't write the show")])
        }
        var report = "SyncPlayer \(AppModel.version)  \(Date())\n"
        report += "\(showName).syncshow  seats: \(s.seats.map(\.name).joined(separator: ", "))\n\n"
        report += "copied (\(copied)):\n" + done.values.sorted().map { "  " + $0 }.joined(separator: "\n") + "\n"
        if !missing.isEmpty { report += "\nnot found (\(missing.count)):\n" + missing.map { "  " + $0 }.joined(separator: "\n") + "\n" }
        try report.write(to: work.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
        if zip {
            let z = dest.pathExtension.lowercased() == "zip" ? dest : dest.appendingPathExtension("zip")
            try? fm.removeItem(at: z)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            p.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", work.path, z.path]
            try p.run(); p.waitUntilExit()
            try? fm.removeItem(at: work.deletingLastPathComponent())
            guard p.terminationStatus == 0 else {
                throw NSError(domain: "Collect", code: 3, userInfo: [NSLocalizedDescriptionKey: L("zip を作れませんでした", "Couldn't make the zip")])
            }
            finished = true
            return Result(folder: z, copied: copied, missing: missing)
        }
        finished = true
        return Result(folder: work, copied: copied, missing: missing)
    }
}
