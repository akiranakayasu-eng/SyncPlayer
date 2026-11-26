import AppKit
import simd

enum EditMode { case none, corners, mesh }

/// Transparent layer over a picture: shows and drags the corner-pin and mesh handles of the
/// selected layer. Several overlays (the output window and the preview) share one state.
final class EditOverlay: NSView {
    /// Supplied by the controller.
    var modeOf: () -> EditMode = { .none }
    var selectedOf: () -> Int = { 0 }
    var select: (Int) -> Void = { _ in }
    /// The selected layer's look, nil when this overlay's output has no selected layer.
    var settings: () -> DisplaySettings? = { nil }
    var aspects: () -> (view: Double, video: Double) = { (16.0 / 9.0, 16.0 / 9.0) }
    var onChange: ((DisplaySettings) -> Void)?
    /// When not editing: a click picks the layer under it (normalized window point). Preview only.
    var pick: ((SIMD2<Double>) -> Void)?
    /// When not editing: a left drag moves the picture (preview only, Akira 2026-11-26).
    var panBy: ((CGFloat, CGFloat) -> Void)?
    /// Layer and file names drawn on each visible layer (T): name, file, box (normalized).
    var showLabels: () -> Bool = { false }
    var labels: () -> [(name: String, file: String, box: CGRect)] = { [] }
    private var dragging: Int?
    private var downAt: NSPoint?
    private var panning = false

    var mode: EditMode { settings() == nil ? .none : modeOf() }
    var selected: Int { selectedOf() }

    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? {
        mode == .none && pick == nil ? nil : super.hitTest(point)
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func toView(_ p: SIMD2<Double>) -> NSPoint {
        NSPoint(x: p.x * bounds.width, y: p.y * bounds.height)
    }

    /// Handle positions in normalized window coordinates.
    func handles() -> [SIMD2<Double>] {
        guard let s = settings() else { return [] }
        let a = aspects()
        let q = Warp.corners(s, viewAspect: a.view, videoAspect: a.video)
        switch mode {
        case .none: return []
        case .corners: return (0..<4).map { SIMD2(q[$0 * 2], q[$0 * 2 + 1]) }
        case .mesh:
            let H = Warp.Homography(q), m = s.meshOffsets
            var out: [SIMD2<Double>] = []
            for j in 0...s.meshRows { for i in 0...s.meshCols { out.append(Warp.meshNode(s, H, m, i, j)) } }
            return out
        }
    }

    var handleCount: Int { handles().count }

    /// Move handle k by d (normalized).
    func move(_ k: Int, by d: SIMD2<Double>) {
        guard var s = settings() else { return }
        let a = aspects()
        switch mode {
        case .none: return
        case .corners:
            var q = Warp.corners(s, viewAspect: a.view, videoAspect: a.video)
            guard k >= 0, k * 2 + 1 < q.count else { return }
            q[k * 2] += d.x; q[k * 2 + 1] += d.y
            s.corners = q
        case .mesh:
            var m = s.meshOffsets
            guard k >= 0, k * 2 + 1 < m.count else { return }
            m[k * 2] += d.x; m[k * 2 + 1] += d.y
            s.mesh = m
        }
        onChange?(s)
        needsDisplay = true
    }

    /// Nudge the selected handle by pixels.
    func nudge(dx: Double, dy: Double) {
        guard mode != .none, bounds.width > 0, bounds.height > 0 else { return }
        move(selected, by: SIMD2(dx / bounds.width, dy / bounds.height))
    }

    func selectNext(_ step: Int = 1) {
        let n = handleCount
        guard n > 0 else { return }
        select((selected + step + n) % n)
    }

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if mode == .none {
            // A click picks the layer (on release, so a drag can move the picture instead).
            if panBy == nil {
                if bounds.width > 0, bounds.height > 0 { pick?(SIMD2(Double(p.x / bounds.width), Double(p.y / bounds.height))) }
            } else {
                downAt = e.locationInWindow; panning = false
            }
            return
        }
        var best = -1, bestD = 18.0
        for (k, h) in handles().enumerated() {
            let v = toView(h)
            let d = hypot(v.x - p.x, v.y - p.y)
            if d < bestD { bestD = d; best = k }
        }
        if best >= 0 { dragging = best; select(best) }
    }

    override func mouseDragged(with e: NSEvent) {
        if mode == .none, let d = downAt, let pan = panBy {
            if !panning && hypot(e.locationInWindow.x - d.x, e.locationInWindow.y - d.y) > 3 { panning = true }
            if panning { pan(e.deltaX, -e.deltaY) }
            return
        }
        guard let k = dragging, bounds.width > 0, bounds.height > 0 else { return }
        move(k, by: SIMD2(Double(e.deltaX) / bounds.width, Double(-e.deltaY) / bounds.height))
    }

    override func mouseUp(with e: NSEvent) {
        if let d = downAt {
            downAt = nil
            if !panning, mode == .none {
                let p = convert(d, from: nil)
                if bounds.width > 0, bounds.height > 0 { pick?(SIMD2(Double(p.x / bounds.width), Double(p.y / bounds.height))) }
            }
            panning = false
        }
        dragging = nil
    }

    override func draw(_ dirtyRect: NSRect) {
        if showLabels() { drawLabels() }
        guard mode != .none, let s = settings() else { return }
        let a = aspects()
        let q = Warp.corners(s, viewAspect: a.view, videoAspect: a.video)
        let H = Warp.Homography(q), m = s.meshOffsets

        // Outline of the warped canvas and the mesh lines.
        NSColor.systemYellow.withAlphaComponent(0.8).setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1
        let steps = 32
        let cols = mode == .mesh ? s.meshCols : 1, rows = mode == .mesh ? s.meshRows : 1
        for i in 0...cols {
            let u = Double(i) / Double(cols)
            for t in 0...steps {
                let pt = toView(Warp.output(s, H, m, u, Double(t) / Double(steps)))
                t == 0 ? path.move(to: pt) : path.line(to: pt)
            }
        }
        for j in 0...rows {
            let v = Double(j) / Double(rows)
            for t in 0...steps {
                let pt = toView(Warp.output(s, H, m, Double(t) / Double(steps), v))
                t == 0 ? path.move(to: pt) : path.line(to: pt)
            }
        }
        path.stroke()

        for (k, h) in handles().enumerated() {
            let c = toView(h)
            let r: CGFloat = k == selected ? 9 : 6
            let o = NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            (k == selected ? NSColor.systemRed : NSColor.systemYellow).setFill()
            o.fill()
            NSColor.black.setStroke()
            o.lineWidth = 1
            o.stroke()
        }
    }

    /// Name (large, bold) and file (smaller) in a dark box at the middle of each layer, sized to the
    /// layer so small layers stay readable and large ones read from a distance.
    private func drawLabels() {
        for l in labels() {
            let r = NSRect(x: l.box.minX * bounds.width, y: l.box.minY * bounds.height,
                           width: l.box.width * bounds.width, height: l.box.height * bounds.height)
            guard r.width > 8, r.height > 8 else { continue }
            let big = max(10, min(r.height * 0.16, r.width * 0.09, 72))
            let name = NSAttributedString(string: l.name, attributes: [.font: NSFont.boldSystemFont(ofSize: big), .foregroundColor: NSColor.white])
            let file = NSAttributedString(string: l.file, attributes: [.font: NSFont.systemFont(ofSize: max(9, big * 0.5)), .foregroundColor: NSColor.white.withAlphaComponent(0.85)])
            let showFile = l.file != l.name
            let ns = name.size(), fs = showFile ? file.size() : .zero
            let pad = big * 0.25
            let w = min(max(ns.width, fs.width) + pad * 2, r.width - 4)
            let h = ns.height + fs.height + pad * 2
            let box = NSRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h)
            NSColor.black.withAlphaComponent(0.6).setFill()
            NSBezierPath(roundedRect: box, xRadius: big * 0.2, yRadius: big * 0.2).fill()
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: box).addClip()
            name.draw(at: NSPoint(x: box.midX - min(ns.width, w - pad * 2) / 2 , y: box.maxY - pad - ns.height))
            if showFile { file.draw(at: NSPoint(x: box.midX - min(fs.width, w - pad * 2) / 2, y: box.minY + pad)) }
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}
