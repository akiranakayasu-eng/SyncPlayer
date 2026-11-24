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
    }
}

/// One output window: a screen (display or projector) and the layers drawn on it.
struct OutputConfig: Codable, Equatable, Identifiable {
    var id = UUID().uuidString
    var name: String
    var screen = 0
    var fullscreen = false
    var layers: [Layer] = []

    init(name: String, screen: Int = 0, fullscreen: Bool = false, layers: [Layer] = []) {
        self.name = name
        self.screen = screen
        self.fullscreen = fullscreen
        self.layers = layers
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "画面"
        screen = try c.decodeIfPresent(Int.self, forKey: .screen) ?? 0
        fullscreen = try c.decodeIfPresent(Bool.self, forKey: .fullscreen) ?? false
        layers = try c.decodeIfPresent([Layer].self, forKey: .layers) ?? []
    }
}

/// Everything one Mac needs: the clips, the outputs and their layers. Saved as a .syncshow file (JSON).
struct Show: Codable, Equatable {
    var version = 1
    var clips: [Clip] = []
    var outputs: [OutputConfig] = []
    /// The clip whose sound is played (nil = the first clip).
    var audioClip: String?
    /// Loop all clips on all Macs together (a shorter clip holds its last frame). Used on the master.
    var loopTogether = true
    /// Loop length in seconds when looping together; 0 = the longest clip on any Mac.
    var loopLength = 0.0
    /// This Mac plays sound (nil = not set: only a Mac started with --master). Saved with the
    /// show, since each Mac keeps its own show file.
    var audioOn: Bool?
    /// This Mac starts as the master (remembered when M or the role switch is used). nil = follower.
    var startAsMaster: Bool?
    /// The master starts playing by itself when the app opens (for an exhibition after a restart).
    var autoPlay = false

    init(clips: [Clip] = [], outputs: [OutputConfig] = [], audioClip: String? = nil) {
        self.clips = clips
        self.outputs = outputs
        self.audioClip = audioClip
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        clips = try c.decode([Clip].self, forKey: .clips)          // required: tells a show from an old preset
        outputs = try c.decode([OutputConfig].self, forKey: .outputs)
        audioClip = try c.decodeIfPresent(String.self, forKey: .audioClip)
        loopTogether = try c.decodeIfPresent(Bool.self, forKey: .loopTogether) ?? true
        loopLength = max(0, try c.decodeIfPresent(Double.self, forKey: .loopLength) ?? 0)
        if loopLength > 0 && loopLength < Show.minLoop { loopLength = Show.minLoop }
        audioOn = try c.decodeIfPresent(Bool.self, forKey: .audioOn)
        startAsMaster = try c.decodeIfPresent(Bool.self, forKey: .startAsMaster)
        autoPlay = try c.decodeIfPresent(Bool.self, forKey: .autoPlay) ?? false
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
        var out = OutputConfig(name: "画面 1", screen: look.screen, fullscreen: look.fullscreen)
        out.layers = show.clips.map { Layer(clipID: $0.id, look: look) }
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
///   presets/<name>.syncshow — named presets (whole shows). Older presets/<name>.json hold
///   only a picture setting (v0.2) and are applied to the selected layer.
enum ShowStore {
    static var base: URL {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SyncPlayer", isDirectory: true)
        try? FileManager.default.createDirectory(at: u.appendingPathComponent("presets"),
                                                 withIntermediateDirectories: true)
        return u
    }
    static var presetDir: URL { base.appendingPathComponent("presets", isDirectory: true) }
    static var currentURL: URL { base.appendingPathComponent("current.syncshow") }
    static let fileType = UTType("com.nakayasu.syncshow") ?? UTType(filenameExtension: "syncshow", conformingTo: .json) ?? .json

    static func write(_ show: Show, to url: URL) -> Bool {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let d = try? enc.encode(show) else { return false }
        return (try? d.write(to: url, options: .atomic)) != nil
    }

    /// Reads a show. A movie that is not at its saved path is looked for next to the show file
    /// (so a folder with the show and its movies can be copied to another Mac).
    static func read(_ url: URL) -> Show? {
        guard let d = try? Data(contentsOf: url), var s = try? JSONDecoder().decode(Show.self, from: d) else { return nil }
        let folder = url.deletingLastPathComponent()
        let fm = FileManager.default
        for i in s.clips.indices where !fm.fileExists(atPath: s.clips[i].path) {
            let near = folder.appendingPathComponent(s.clips[i].name).path
            if fm.fileExists(atPath: near) { s.clips[i].path = near }
        }
        for o in s.outputs.indices {
            for l in s.outputs[o].layers.indices {
                guard let m = s.outputs[o].layers[l].mask, !fm.fileExists(atPath: m) else { continue }
                let near = folder.appendingPathComponent((m as NSString).lastPathComponent).path
                if fm.fileExists(atPath: near) { s.outputs[o].layers[l].mask = near }
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

    static func safe(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?*\"<>|")
        return name.components(separatedBy: bad).joined(separator: "_").trimmingCharacters(in: .whitespaces)
    }

    static func presetNames() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: presetDir.path)) ?? []
        var names = Set<String>()
        for f in files {
            if f.hasSuffix(".syncshow") { names.insert(String(f.dropLast(9))) }
            else if f.hasSuffix(".json") { names.insert(String(f.dropLast(5))) }
        }
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    enum Preset { case show(Show), look(DisplaySettings) }

    static func savePreset(_ show: Show, as name: String) -> Bool {
        let n = safe(name)
        guard !n.isEmpty else { return false }
        // A v0.3 preset replaces an old one of the same name.
        try? FileManager.default.removeItem(at: presetDir.appendingPathComponent(n + ".json"))
        return write(show, to: presetDir.appendingPathComponent(n + ".syncshow"))
    }

    static func loadPreset(_ name: String) -> Preset? {
        let n = safe(name)
        if let s = read(presetDir.appendingPathComponent(n + ".syncshow")) { return .show(s) }
        if let d = try? Data(contentsOf: presetDir.appendingPathComponent(n + ".json")),
           let s = try? JSONDecoder().decode(DisplaySettings.self, from: d) { return .look(s) }
        return nil
    }

    static func deletePreset(_ name: String) {
        let n = safe(name)
        try? FileManager.default.removeItem(at: presetDir.appendingPathComponent(n + ".syncshow"))
        try? FileManager.default.removeItem(at: presetDir.appendingPathComponent(n + ".json"))
    }
}
