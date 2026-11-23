import AppKit
import AVFoundation

// SyncPlayer v0
//   swift run SyncPlayer --master   <movie>
//   swift run SyncPlayer --follower <movie>
// Options: --name A  --fullscreen  --screen 1  --audio (follower plays sound)  --mute (master silent)
//          --broadcast 192.168.1.255  --to 192.168.1.23 (extra master->follower address, repeatable)
//          --log (print one line per second: error, offset, round trip)
//          --autoplay 2 (master starts by itself after 2 s)  --quit-after 60
// Keys: space play/pause (master), r back to start, ←/→ 5 s, i info, f full screen, q quit.

struct Options {
    var master = false
    var file: String?
    var name = Host.current().localizedName ?? "mac"
    var fullscreen = false
    var screen = 0
    var audio: Bool? = nil
    var broadcast = "255.255.255.255"
    var extra: [String] = []
    var log = false
    var autoplay: Double? = nil   // master: start playing after N seconds
    var quitAfter: Double? = nil  // quit after N seconds (for unattended tests)

    init(_ args: [String]) {
        var i = 1
        func next() -> String { i += 1; return i < args.count ? args[i] : "" }
        while i < args.count {
            switch args[i] {
            case "--master": master = true
            case "--follower": master = false
            case "--name": name = next()
            case "--fullscreen": fullscreen = true
            case "--screen": screen = Int(next()) ?? 0
            case "--audio": audio = true
            case "--mute": audio = false
            case "--broadcast": broadcast = next()
            case "--to": extra.append(next())
            case "--log": log = true
            case "--autoplay": autoplay = Double(next()) ?? 2
            case "--quit-after": quitAfter = Double(next())
            default: file = args[i]
            }
            i += 1
        }
    }
}

final class VideoView: NSView {
    var onKey: ((NSEvent) -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) { onKey?(event) }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let opts: Options
    var window: NSWindow!
    var node: SyncNode!
    var master: Master?
    var follower: Follower?
    let info = NSTextField(labelWithString: "")
    var tickTimer: Timer?
    var logTimer: Timer?

    init(opts: Options) { self.opts = opts }

    func applicationDidFinishLaunching(_ n: Notification) {
        guard let path = opts.file, FileManager.default.fileExists(atPath: path) else {
            print("movie file not found: \(opts.file ?? "(none)")"); exit(1)
        }
        let url = URL(fileURLWithPath: path)
        let muted = !(opts.audio ?? opts.master)
        node = SyncNode(url: url, muted: muted)

        do {
            if opts.master {
                master = try Master(node: node, broadcast: opts.broadcast, extraTargets: opts.extra)
            } else {
                follower = try Follower(node: node)
            }
        } catch {
            print("network error: \(error)  (is another master already running on this Mac?)"); exit(1)
        }

        let screens = NSScreen.screens
        let screen = screens.indices.contains(opts.screen) ? screens[opts.screen] : NSScreen.main!
        let frame = NSRect(x: screen.frame.minX + 80, y: screen.frame.minY + 80, width: 960, height: 540)
        window = NSWindow(contentRect: frame, styleMask: [.titled, .resizable, .closable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "SyncPlayer — \(opts.master ? "MASTER" : "follower") — \(opts.name)"
        let view = VideoView(frame: NSRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        let pl = AVPlayerLayer(player: node.player)
        pl.frame = view.bounds
        pl.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        pl.videoGravity = .resizeAspect
        view.layer?.addSublayer(pl)

        info.font = .monospacedSystemFont(ofSize: 14, weight: .medium)
        info.textColor = .green
        info.backgroundColor = NSColor.black.withAlphaComponent(0.6)
        info.drawsBackground = true
        info.frame = NSRect(x: 10, y: 10, width: 700, height: 60)
        info.maximumNumberOfLines = 3
        view.addSubview(info)

        view.onKey = { [weak self] e in self?.key(e) }
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        NSApp.activate(ignoringOtherApps: true)
        if opts.fullscreen { window.toggleFullScreen(nil) }

        // The correction loop. 20 Hz is plenty; the decision is about tens of ms.
        tickTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.node.tick()
            self?.updateInfo()
        }
        RunLoop.main.add(tickTimer!, forMode: .common)
        if let a = opts.autoplay, let m = master {
            DispatchQueue.main.asyncAfter(deadline: .now() + a) { if !m.schedule.playing { m.togglePlay() } }
        }
        if let q = opts.quitAfter {
            DispatchQueue.main.asyncAfter(deadline: .now() + q) { NSApp.terminate(nil) }
        }
        if opts.log {
            logTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                self?.printLog()
            }
        }
    }

    func key(_ e: NSEvent) {
        switch e.keyCode {
        case 49: master?.togglePlay()                 // space
        case 123: master?.jump(by: -5)                // ←
        case 124: master?.jump(by: 5)                 // →
        default:
            switch e.charactersIgnoringModifiers?.lowercased() {
            case "r": master?.jump(to: 0)
            case "i": info.isHidden.toggle()
            case "f": window.toggleFullScreen(nil)
            case "q": NSApp.terminate(nil)
            default: break
            }
        }
    }

    func statusText() -> String {
        let pos = node.player.currentTime().seconds
        let frame = Int((pos * 60).rounded())
        var s = String(format: "%@ %@  pos %.3f s (frame@60 %d)  rate %.4f\n",
                       opts.master ? "MASTER" : "follower", opts.name, pos, frame, node.player.rate)
        s += String(format: "error %+.1f ms  avg %+.1f ms  jumps %d",
                    node.lastError * 1000, node.errorEMA * 1000, node.resyncCount)
        if let f = follower {
            let st = f.stats
            s += String(format: "\nclock %@ offset %+.3f ms  rtt %.3f ms%@",
                        st.ready ? "ok" : "learning", st.offset * 1000, st.rtt * 1000,
                        node.schedule == nil ? "  (waiting for master)" : "")
        } else if let m = master {
            s += m.schedule.playing ? "\nplaying — space to pause" : "\npaused — space to play"
        }
        return s
    }

    func updateInfo() { if !info.isHidden { info.stringValue = statusText() } }

    func printLog() {
        var line = String(format: "%.3f\t%@\terr_ms=%+.2f\tavg_ms=%+.2f\trate=%.4f\tjumps=%d",
                          Date().timeIntervalSince1970, opts.name, node.lastError * 1000,
                          node.errorEMA * 1000, node.player.rate, node.resyncCount)
        if let st = follower?.stats {
            line += String(format: "\toffset_ms=%+.3f\trtt_ms=%.3f", st.offset * 1000, st.rtt * 1000)
        }
        print(line); fflush(stdout)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
}

let opts = Options(CommandLine.arguments)
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate(opts: opts)
app.delegate = delegate
app.run()
