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

    init(child: NSView) {
        self.child = child
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor
        addSubview(child)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let b = bounds
        guard b.width > 0, b.height > 0, aspect > 0 else { return }
        var w = b.width, h = b.width / aspect
        if h > b.height { h = b.height; w = h * aspect }
        child.frame = NSRect(x: (b.width - w) / 2, y: (b.height - h) / 2, width: w, height: h)
    }
}

/// The picture, the edit handles and the info text: used by output windows and the preview.
final class PictureView: NSView {
    let mtk: MTKView
    let renderer: OutputRenderer
    let overlay = EditOverlay()

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
    private var windowedFrame: NSRect?
    private(set) var isFull = false
    private(set) var screenIndex = -1

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
    func apply(_ o: OutputConfig, index: Int, title: String) {
        window.title = title
        guard o.fullscreen != isFull || o.screen != screenIndex else { return }
        let screens = NSScreen.screens
        let screen = screens.indices.contains(o.screen) ? screens[o.screen] : (NSScreen.main ?? screens[0])
        let movedScreen = o.screen != screenIndex
        if o.fullscreen {
            if !isFull { windowedFrame = window.frame }
            window.styleMask = [.borderless]
            window.setFrame(screen.frame, display: true)
        } else {
            window.styleMask = OutputWindow.windowed
            var f = windowedFrame ?? .zero
            if movedScreen || windowedFrame == nil || !screen.frame.intersects(f) {
                // Top right and small, so it does not hide the control window (bottom left).
                let vf = screen.visibleFrame
                let off = CGFloat(index * 40)
                let w = min(640, vf.width / 2), h = w * 9 / 16
                f = NSRect(x: vf.maxX - w - 20 - off, y: vf.maxY - h - 20 - off, width: w, height: h)
            }
            window.setFrame(f, display: true)
        }
        window.title = title
        isFull = o.fullscreen
        screenIndex = o.screen
        window.orderFront(nil)
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
}
