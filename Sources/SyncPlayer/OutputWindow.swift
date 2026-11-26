import AppKit
import MetalKit

/// A text label that lets clicks through, so the edit points under it can still be dragged.
final class PassThroughLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A borderless (full-screen) window can still take the keys.
final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Fills a container with a child view kept at a given aspect (letterboxed). Used for the preview.
final class AspectBox: NSView {
    let child: NSView
    var aspect: Double = 16.0 / 9.0 { didSet { if aspect != oldValue { needsLayout = true } } }

    // Zoom and pan of the preview, like After Effects' Composition panel (Akira 2026-11-26).
    // zoom nil = fit; otherwise 1 = 100 % (one pixel of the output is one pixel here).
    private(set) var zoom: Double?
    private var pan = CGPoint.zero
    /// The output's size in pixels (for 100 %), supplied by the model.
    var outputPixels: () -> CGSize = { CGSize(width: 1920, height: 1080) }
    /// Told whenever the zoom changes (the % shown under the preview).
    var onZoom: ((Double?) -> Void)?
    static let zoomRange: ClosedRange<Double> = 0.05...4
    /// The picture view is never made bigger than this (points).
    private static let maxSide: CGFloat = 6144
    /// The preview is drawn at most this many pixels on its long side, then scaled (check 48 M1).
    private static let maxDrawable: CGFloat = 4096
    private var drawableWork: DispatchWorkItem?

    /// The largest zoom for this output on this screen (the frame cap), never over 400 %.
    var maxZoom: Double {
        let px = outputPixels()
        let long = max(px.width, px.height)
        guard long > 0 else { return AspectBox.zoomRange.upperBound }
        return min(AspectBox.zoomRange.upperBound, Double(AspectBox.maxSide * scale / long))
    }

    init(child: NSView) {
        self.child = child
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor
        layer?.masksToBounds = true
        addSubview(child)
    }
    required init?(coder: NSCoder) { fatalError() }

    private var fitSize: CGSize {
        let b = bounds
        guard b.width > 0, b.height > 0, aspect > 0 else { return .zero }
        var w = b.width, h = b.width / aspect
        if h > b.height { h = b.height; w = h * aspect }
        return CGSize(width: w, height: h)
    }
    private var scale: CGFloat { window?.backingScaleFactor ?? 2 }
    /// The zoom the fit size is, as a %.
    var fitZoom: Double {
        let px = outputPixels()
        guard px.width > 0 else { return 1 }
        return Double(fitSize.width * scale / px.width)
    }
    /// What the zoom is now (fit too), 1 = 100 %.
    var currentZoom: Double { zoom ?? fitZoom }

    override func layout() {
        super.layout()
        let b = bounds
        let f = fitSize
        guard f.width > 0 else { return }
        var w = f.width, h = f.height
        if let z = zoom, z > maxZoom + 0.0001 {
            // Another output (a larger display) lowered the limit: the % follows (check 49 L2).
            zoom = maxZoom
            let nz = zoom
            DispatchQueue.main.async { [weak self] in self?.onZoom?(nz) }
        }
        if let z = zoom {
            let px = outputPixels()
            w = px.width * CGFloat(min(z, maxZoom)) / scale
            h = w / CGFloat(aspect)
        }
        // Keep at least a strip of the picture inside, so it can't be dragged away (check 48 L3).
        let keep: CGFloat = 60
        let mx = max(0, (w + b.width) / 2 - keep), my = max(0, (h + b.height) / 2 - keep)
        pan = CGPoint(x: min(max(pan.x, -mx), mx), y: min(max(pan.y, -my), my))
        child.frame = NSRect(x: (b.width - w) / 2 + pan.x, y: (b.height - h) / 2 + pan.y, width: w, height: h)
        updateDrawable()
    }

    /// The Metal drawable follows the picture's size only once the size has settled. While a panel
    /// edge is dragged the old drawable is stretched, instead of making a new one every step, which
    /// made the preview and the dragging jitter (Akira 2026-11-26).
    private func updateDrawable() {
        guard let pv = child as? PictureView else { return }
        let mtk = pv.mtk
        if mtk.autoResizeDrawable {
            mtk.autoResizeDrawable = false
            mtk.layer?.contentsGravity = .resize
        }
        let sz = child.frame.size
        var target = CGSize(width: sz.width * scale, height: sz.height * scale)
        let long = max(target.width, target.height)
        if long > AspectBox.maxDrawable { let k = AspectBox.maxDrawable / long; target.width *= k; target.height *= k }
        target = CGSize(width: max(1, target.width.rounded()), height: max(1, target.height.rounded()))
        drawableWork?.cancel()   // a size that went back must not leave the other one pending (check 49 L1)
        if mtk.drawableSize == target { return }
        let set = DispatchWorkItem { [weak mtk] in mtk?.drawableSize = target }
        drawableWork = set
        // The first time (and from a tiny size) at once; otherwise after the size stops changing.
        if mtk.drawableSize.width < 4 { set.perform() } else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: set) }
    }

    /// Set a zoom (nil = fit). Keeps the point under `at` (in this view) where it is.
    func setZoom(_ z: Double?, at: CGPoint? = nil) {
        guard let z else { zoom = nil; pan = .zero; needsLayout = true; onZoom?(nil); return }
        let nz = min(max(z, AspectBox.zoomRange.lowerBound), maxZoom)
        let old = currentZoom
        let c = at ?? CGPoint(x: bounds.midX, y: bounds.midY)
        // The picture point under c stays under c: scale its offset from the centre.
        let k = CGFloat(nz / max(old, 0.0001))
        let mid = CGPoint(x: bounds.midX, y: bounds.midY)
        let off = CGPoint(x: c.x - (mid.x + pan.x), y: c.y - (mid.y + pan.y))
        pan = CGPoint(x: c.x - mid.x - off.x * k, y: c.y - mid.y - off.y * k)
        zoom = nz
        needsLayout = true
        onZoom?(nz)
    }

    /// Zoom and move so the part `r` of the picture (normalized, 0,0 bottom-left) fills `fill` of
    /// the view, centred, with the rest of the picture around it (Akira 2026-11-26: fit the
    /// selected layer at about 90 % so the other clips show too).
    func focus(_ r: CGRect, fill: CGFloat = 0.9) {
        let px = outputPixels(), b = bounds
        guard px.width > 0, b.width > 0, b.height > 0, aspect > 0, r.width > 0.001, r.height > 0.001 else { return }
        let zw = Double(fill * b.width * scale / (r.width * px.width))
        let zh = Double(fill * b.height * scale * CGFloat(aspect) / (r.height * px.width))
        let z = min(max(min(zw, zh), AspectBox.zoomRange.lowerBound), maxZoom)
        let w = px.width * CGFloat(z) / scale, h = w / CGFloat(aspect)
        zoom = z
        pan = CGPoint(x: w * (0.5 - r.midX), y: h * (0.5 - r.midY))
        needsLayout = true
        onZoom?(z)
    }

    func panBy(_ dx: CGFloat, _ dy: CGFloat) {
        if zoom == nil { zoom = fitZoom; onZoom?(zoom) }
        pan.x += dx; pan.y += dy
        needsLayout = true
    }

    // Wheel: zoom around the pointer. A trackpad's two-finger scroll moves the picture, a pinch zooms.
    override func scrollWheel(with e: NSEvent) {
        if e.hasPreciseScrollingDeltas && e.phase != [] || e.momentumPhase != [] {
            panBy(e.scrollingDeltaX, -e.scrollingDeltaY)
            return
        }
        let d = e.scrollingDeltaY
        guard d != 0 else { return }
        setZoom(currentZoom * pow(1.1, Double(d > 0 ? 1 : -1)), at: convert(e.locationInWindow, from: nil))
    }
    override func magnify(with e: NSEvent) {
        setZoom(currentZoom * (1 + Double(e.magnification)), at: convert(e.locationInWindow, from: nil))
    }
    // Middle-button (wheel) drag moves the picture.
    override func otherMouseDragged(with e: NSEvent) { panBy(e.deltaX, -e.deltaY) }
    override func otherMouseDown(with e: NSEvent) {}
    override func otherMouseUp(with e: NSEvent) {}
}

/// The picture, the edit handles and the info text: used by output windows and the preview.
final class PictureView: NSView {
    let mtk: MTKView
    let renderer: OutputRenderer
    let overlay = EditOverlay()
    /// Shown on the preview while it rests during playback (Akira 2026-11-26).
    let restNote = PassThroughLabel(labelWithString: "")

    init?(fps: Int) {
        mtk = MTKView(frame: NSRect(x: 0, y: 0, width: 960, height: 540))
        guard let r = OutputRenderer(view: mtk, fps: fps) else { return nil }
        renderer = r
        super.init(frame: NSRect(x: 0, y: 0, width: 960, height: 540))
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        mtk.frame = bounds
        mtk.autoresizingMask = [.width, .height]
        addSubview(mtk)
        overlay.frame = bounds
        overlay.autoresizingMask = [.width, .height]
        addSubview(overlay)
        restNote.font = .systemFont(ofSize: 13, weight: .medium)
        restNote.textColor = .white
        restNote.drawsBackground = true
        restNote.backgroundColor = NSColor.black.withAlphaComponent(0.65)
        restNote.alignment = .center
        restNote.isHidden = true
        addSubview(restNote)
    }

    /// While resting the preview stops drawing (the last picture stays) and says so.
    func setResting(_ on: Bool, text: String) {
        mtk.isPaused = on
        restNote.stringValue = text
        restNote.sizeToFit()
        let w = restNote.frame.width + 16, h = restNote.frame.height + 8
        restNote.frame = NSRect(x: (bounds.width - w) / 2, y: bounds.height - h - 8, width: w, height: h)
        restNote.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin]
        restNote.isHidden = !on
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// One output: a window on a chosen screen, full screen or not, drawing that output's layers.
final class OutputWindow: NSObject, NSWindowDelegate {
    let id: String
    let window: KeyableWindow
    let picture: PictureView
    let info = PassThroughLabel(labelWithString: "")
    /// Large Mac name and screen number in the middle (N key), to tell screens apart when setting up.
    let ident = PassThroughLabel(labelWithString: "")
    /// A short line at the bottom for a few seconds (how to get back from full screen).
    let hint = PassThroughLabel(labelWithString: "")
    private var hintWork: DispatchWorkItem?
    var onBecomeKey: (() -> Void)?
    /// A windowed output dragged by hand onto another display: its new display's number.
    var onMovedToScreen: ((Int) -> Void)?
    private var windowedFrame: NSRect?
    private(set) var isFull = false
    private(set) var screenIndex = -1
    /// True while the app itself moves or sizes the window (not a move by hand).
    private var placing = false

    static let windowed: NSWindow.StyleMask = [.titled, .resizable, .miniaturizable]
    /// Full-screen outputs stay above ordinary windows (the control window unless S brings it up)
    /// and the menu bar and Dock, on every screen. AppModel.refreshLevels sets the level.
    static let fullLevel = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)   // above the menu bar's icons too

    init?(id: String) {
        guard let p = PictureView(fps: 120) else { return nil }
        self.id = id
        picture = p
        window = KeyableWindow(contentRect: NSRect(x: 100, y: 100, width: 960, height: 540),
                               styleMask: OutputWindow.windowed, backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black
        window.delegate = self
        window.collectionBehavior = [.fullScreenNone]
        p.frame = NSRect(x: 0, y: 0, width: 960, height: 540)
        info.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        info.textColor = .green
        info.backgroundColor = NSColor.black.withAlphaComponent(0.65)
        info.drawsBackground = true
        info.maximumNumberOfLines = 22
        info.frame = NSRect(x: 10, y: 10, width: 700, height: 60)
        p.addSubview(info)
        ident.alignment = .center
        ident.textColor = .white
        ident.backgroundColor = NSColor.black.withAlphaComponent(0.7)
        ident.drawsBackground = true
        ident.maximumNumberOfLines = 3
        ident.isHidden = true
        p.addSubview(ident)
        hint.alignment = .center
        hint.textColor = .white
        hint.font = .boldSystemFont(ofSize: 18)
        hint.backgroundColor = NSColor.black.withAlphaComponent(0.7)
        hint.drawsBackground = true
        hint.isHidden = true
        p.addSubview(hint)
        window.contentView = p
    }

    var viewAspect: Double {
        let s = picture.mtk.bounds.size
        return s.height > 0 ? Double(s.width / s.height) : 16.0 / 9.0
    }

    /// Put the window where the output says: its screen, full screen or a window on it.
    /// index: the output's place in the list, to stagger windows on the same screen.
    /// Returns true when the window moved or changed between full screen and a window.
    @discardableResult
    func apply(_ o: OutputConfig, index: Int, title: String) -> Bool {
        window.title = title
        guard o.fullscreen != isFull || o.screen != screenIndex else { return false }
        placing = true
        defer { placing = false }
        let screens = NSScreen.screens
        let screen = screens.indices.contains(o.screen) ? screens[o.screen] : (NSScreen.main ?? screens[0])
        let movedScreen = o.screen != screenIndex
        if o.fullscreen {
            if !isFull { windowedFrame = window.frame }
            window.styleMask = [.borderless]
            window.setFrame(screen.frame, display: true)
        } else {
            window.styleMask = OutputWindow.windowed
            // A windowed output keeps its display's shape, so the layers are laid out the same as at
            // full screen and the preview matches the display (Akira 2026-11-26: it only matched after F).
            let ratio = screen.frame.width / max(screen.frame.height, 1)
            window.contentAspectRatio = screen.frame.size
            var f = windowedFrame ?? .zero
            if movedScreen || windowedFrame == nil || !screen.frame.intersects(f) {
                // Top right and small, so it does not hide the control window (bottom left).
                let vf = screen.visibleFrame
                let off = CGFloat(index * 40)
                let w = min(640, vf.width / 2), h = w / ratio
                f = NSRect(x: vf.maxX - w - 20 - off, y: vf.maxY - h - 20 - off, width: w, height: h)
            }
            // The content (not the title bar) has the display's shape; the top edge stays put.
            let c = window.contentRect(forFrameRect: f)
            f = window.frameRect(forContentRect: NSRect(x: c.minX, y: c.maxY - c.width / ratio,
                                                        width: c.width, height: c.width / ratio))
            window.setFrame(f, display: true)
        }
        window.title = title
        isFull = o.fullscreen
        screenIndex = o.screen
        // Regardless of which app is in front: a full-screen output moved to another display stays
        // up there (it seemed to vanish, Akira 2026-11-26).
        window.orderFrontRegardless()
        return true
    }

    /// Screens changed (a display was plugged or unplugged): place again.
    func replace(_ o: OutputConfig, index: Int, title: String) {
        screenIndex = -1
        if isFull { isFull = false; windowedFrame = nil }
        apply(o, index: index, title: title)
    }

    func layoutInfo(_ text: String) {
        guard !info.isHidden else { return }
        info.stringValue = text
        let size = info.sizeThatFits(NSSize(width: 900, height: 700))
        info.frame = NSRect(x: 10, y: 10, width: min(size.width + 8, picture.bounds.width - 20), height: size.height + 4)
    }

    /// Show (text) or hide (nil) the large name and number, sized to the window.
    func layoutIdent(_ text: String?) {
        guard let text else { if !ident.isHidden { ident.isHidden = true }; return }
        let b = picture.bounds
        // As large as fits: start from the window's height and shrink until the longest line fits.
        var size = max(18, min(b.height / 7, b.width / 12))
        let lines = text.components(separatedBy: "\n")
        func width(_ l: String, _ sz: CGFloat) -> CGFloat {
            (l as NSString).size(withAttributes: [.font: NSFont.boldSystemFont(ofSize: sz)]).width
        }
        while size > 18 {
            let w = lines.map { width($0, size) }.max() ?? 0   // widest line, by measured width
            if w + size <= b.width - 20 { break }
            size *= 0.9
        }
        if ident.font?.pointSize != size { ident.font = .boldSystemFont(ofSize: size) }
        if ident.stringValue != text { ident.stringValue = text }
        let fit = ident.sizeThatFits(NSSize(width: b.width - 40, height: b.height))
        let w = min(fit.width + size, b.width - 20), h = fit.height + size * 0.4
        ident.frame = NSRect(x: (b.width - w) / 2, y: (b.height - h) / 2, width: w, height: h)
        ident.isHidden = false
    }

    func showHint(_ text: String, seconds: Double) {
        hint.stringValue = text
        let b = picture.bounds
        let fit = hint.sizeThatFits(NSSize(width: b.width - 40, height: 60))
        let w = min(fit.width + 30, b.width - 20), h = fit.height + 12
        hint.frame = NSRect(x: (b.width - w) / 2, y: 40, width: w, height: h)
        hint.isHidden = false
        hintWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hint.isHidden = true }
        hintWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func close() {
        picture.mtk.isPaused = true
        window.delegate = nil
        window.orderOut(nil)
        window.close()
    }

    func windowDidBecomeKey(_ notification: Notification) { onBecomeKey?() }

    /// The window was dragged to another display (Akira 2026-11-26: N showed the new display, the
    /// control window still said the old one). The setting follows, and the window takes that
    /// display's shape, without being moved back.
    func windowDidChangeScreen(_ notification: Notification) {
        // Only a move by hand: not while the app places the window, and not when macOS moves it
        // because a display was unplugged (the setting must survive that; check 50 M1).
        guard !placing, !isFull, NSEvent.pressedMouseButtons & 1 != 0 else { return }
        waitForRelease()
    }
    /// The window is taken over by the display it ends on, once, when the mouse is let go (check 50 L1).
    private var waiting = false
    private func waitForRelease() {
        guard !waiting else { return }
        waiting = true
        func poll() {
            if NSEvent.pressedMouseButtons & 1 != 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { poll() }
                return
            }
            waiting = false
            adoptScreen()
        }
        poll()
    }
    private func adoptScreen() {
        guard !isFull, let sc = window.screen, let i = NSScreen.screens.firstIndex(of: sc), i != screenIndex else { return }
        screenIndex = i
        let ratio = sc.frame.width / max(sc.frame.height, 1)
        window.contentAspectRatio = sc.frame.size
        let c = window.contentRect(forFrameRect: window.frame)
        placing = true
        window.setFrame(window.frameRect(forContentRect: NSRect(x: c.minX, y: c.maxY - c.width / ratio,
                                                                width: c.width, height: c.width / ratio)), display: true)
        placing = false
        onMovedToScreen?(i)
    }
}
