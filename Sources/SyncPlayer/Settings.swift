import Foundation

/// How this Mac shows the picture. Saved per Mac (last used + named presets).
/// Coordinates are normalized to the output window: (0,0) bottom-left, (1,1) top-right.
struct DisplaySettings: Codable, Equatable {
    // Content transform inside the canvas
    var posX = 0.0, posY = 0.0          // shift, in canvas widths/heights
    var scale = 1.0
    var rotation = 0.0                  // degrees, counter-clockwise
    // Crop (mask) of the source picture, fraction of each side
    var cropL = 0.0, cropR = 0.0, cropT = 0.0, cropB = 0.0
    // Edge blend at the window edges (fraction of width/height) and its gamma
    var blendL = 0.0, blendR = 0.0, blendT = 0.0, blendB = 0.0
    var blendGamma = 2.2
    /// Corner pin: x,y for bottom-left, bottom-right, top-right, top-left. nil = fit the video in the window.
    var corners: [Double]? = nil
    /// Curved-surface mesh: (cols+1)*(rows+1) points, each an x,y offset added after the corner pin.
    var meshCols = 4, meshRows = 4
    var mesh: [Double] = []
    var showGrid = false
    var screen = 0
    var fullscreen = false

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DisplaySettings()
        posX = try c.decodeIfPresent(Double.self, forKey: .posX) ?? d.posX
        posY = try c.decodeIfPresent(Double.self, forKey: .posY) ?? d.posY
        scale = try c.decodeIfPresent(Double.self, forKey: .scale) ?? d.scale
        rotation = try c.decodeIfPresent(Double.self, forKey: .rotation) ?? d.rotation
        cropL = try c.decodeIfPresent(Double.self, forKey: .cropL) ?? 0
        cropR = try c.decodeIfPresent(Double.self, forKey: .cropR) ?? 0
        cropT = try c.decodeIfPresent(Double.self, forKey: .cropT) ?? 0
        cropB = try c.decodeIfPresent(Double.self, forKey: .cropB) ?? 0
        blendL = try c.decodeIfPresent(Double.self, forKey: .blendL) ?? 0
        blendR = try c.decodeIfPresent(Double.self, forKey: .blendR) ?? 0
        blendT = try c.decodeIfPresent(Double.self, forKey: .blendT) ?? 0
        blendB = try c.decodeIfPresent(Double.self, forKey: .blendB) ?? 0
        blendGamma = try c.decodeIfPresent(Double.self, forKey: .blendGamma) ?? d.blendGamma
        corners = try c.decodeIfPresent([Double].self, forKey: .corners)
        meshCols = try c.decodeIfPresent(Int.self, forKey: .meshCols) ?? d.meshCols
        meshRows = try c.decodeIfPresent(Int.self, forKey: .meshRows) ?? d.meshRows
        mesh = try c.decodeIfPresent([Double].self, forKey: .mesh) ?? []
        showGrid = try c.decodeIfPresent(Bool.self, forKey: .showGrid) ?? false
        screen = try c.decodeIfPresent(Int.self, forKey: .screen) ?? 0
        fullscreen = try c.decodeIfPresent(Bool.self, forKey: .fullscreen) ?? false
        if corners?.count != 8 { corners = nil }
    }

    var meshPointCount: Int { (meshCols + 1) * (meshRows + 1) }

    /// Mesh offsets, always the right length.
    var meshOffsets: [Double] {
        mesh.count == meshPointCount * 2 ? mesh : Array(repeating: 0, count: meshPointCount * 2)
    }

    mutating func resetTransform() { posX = 0; posY = 0; scale = 1; rotation = 0 }
    mutating func resetCorners() { corners = nil }
    mutating func resetMesh() { mesh = [] }
    mutating func setMeshSize(_ n: Int) { meshCols = n; meshRows = n; mesh = [] }
}

/// Presets live in ~/Library/Application Support/SyncPlayer/presets/<name>.json.
/// "last.json" next to that folder holds the settings in use, saved on every change.
enum PresetStore {
    static var base: URL {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SyncPlayer", isDirectory: true)
        try? FileManager.default.createDirectory(at: u.appendingPathComponent("presets"),
                                                 withIntermediateDirectories: true)
        return u
    }
    static var dir: URL { base.appendingPathComponent("presets", isDirectory: true) }

    static func safe(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?*\"<>|")
        return name.components(separatedBy: bad).joined(separator: "_").trimmingCharacters(in: .whitespaces)
    }

    static func list() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return files.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    static func save(_ s: DisplaySettings, as name: String) {
        let n = safe(name)
        guard !n.isEmpty else { return }
        write(s, to: dir.appendingPathComponent(n + ".json"))
    }

    static func load(_ name: String) -> DisplaySettings? {
        read(dir.appendingPathComponent(safe(name) + ".json"))
    }

    static func delete(_ name: String) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(safe(name) + ".json"))
    }

    static func saveLast(_ s: DisplaySettings) { write(s, to: base.appendingPathComponent("last.json")) }
    static func loadLast() -> DisplaySettings? { read(base.appendingPathComponent("last.json")) }

    private static func write(_ s: DisplaySettings, to url: URL) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(s) { try? d.write(to: url, options: .atomic) }
    }
    private static func read(_ url: URL) -> DisplaySettings? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(DisplaySettings.self, from: d)
    }
}
