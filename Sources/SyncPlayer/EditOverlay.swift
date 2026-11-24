import AppKit
import simd

enum EditMode { case none, corners, mesh }

/// Transparent layer over the picture: shows and drags corner-pin and mesh handles.
final class EditOverlay: NSView {
    var mode: EditMode = .none { didSet { selected = 0; needsDisplay = true } }
    var selected = 0
    /// Supplied by the controller.
    var settings: () -> DisplaySettings = { DisplaySettings() }
    var aspects: () -> (view: Double, video: Double) = { (16.0 / 9.0, 16.0 / 9.0) }
    var onChange: ((DisplaySettings) -> Void)?
    private var dragging: Int?

    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { mode == .none ? nil : super.hitTest(point) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func toView(_ p: SIMD2<Double>) -> NSPoint {
        NSPoint(x: p.x * bounds.width, y: p.y * bounds.height)
    }

    /// Handle positions in normalized window coordinates.
    func handles() -> [SIMD2<Double>] {
        let s = settings(), a = aspects()
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
        var s = settings()
        let a = aspects()
        switch mode {
        case .none: return
        case .corners:
            var q = Warp.corners(s, viewAspect: a.view, videoAspect: a.video)
            q[k * 2] += d.x; q[k * 2 + 1] += d.y
            s.corners = q
        case .mesh:
            var m = s.meshOffsets
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
        selected = (selected + step + n) % n
        needsDisplay = true
    }

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        var best = -1, bestD = 18.0
        for (k, h) in handles().enumerated() {
            let v = toView(h)
            let d = hypot(v.x - p.x, v.y - p.y)
            if d < bestD { bestD = d; best = k }
        }
        if best >= 0 { dragging = best; selected = best; needsDisplay = true }
    }

    override func mouseDragged(with e: NSEvent) {
        guard let k = dragging, bounds.width > 0, bounds.height > 0 else { return }
        move(k, by: SIMD2(Double(e.deltaX) / bounds.width, Double(-e.deltaY) / bounds.height))
    }

    override func mouseUp(with e: NSEvent) { dragging = nil }

    override func draw(_ dirtyRect: NSRect) {
        guard mode != .none else { return }
        let s = settings(), a = aspects()
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
}
