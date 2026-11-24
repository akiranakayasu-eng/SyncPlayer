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
        // Values from a hand-edited file: keep the mesh in the range the controls allow.
        if !(2...8).contains(meshCols) || !(2...8).contains(meshRows) { meshCols = d.meshCols; meshRows = d.meshRows; mesh = [] }
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
