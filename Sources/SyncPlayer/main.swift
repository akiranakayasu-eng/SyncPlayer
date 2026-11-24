import AppKit
import AVFoundation
import MetalKit
import UniformTypeIdentifiers

// SyncPlayer
//   SyncPlayer [--master | --follower] <movie>
// Options: --name A  --preset NAME  --fullscreen  --screen 1  --audio | --mute
//          --broadcast 192.168.1.255  --to 192.168.1.23 (extra master->follower address, repeatable)
//          --log  --log-interval 0.1  --autoplay 2 (master starts by itself)  --quit-after 60
//          --switch-after 30 (test: switch master <-> follower after 30 s)

struct Options {
    var master = false
    var file: String?
    var name = Host.current().localizedName ?? "mac"
    var fullscreen = false
    var screen: Int?
    var audio: Bool? = nil
    var broadcast = "255.255.255.255"
    var extra: [String] = []
    var log = false
    var logInterval = 1.0
    var autoplay: Double? = nil
    var quitAfter: Double? = nil
    var preset: String?
    var switchAfter: Double? = nil   // test: switch role (master <-> follower) after N seconds

    init(_ args: [String]) {
        var i = 1
        func next() -> String { i += 1; return i < args.count ? args[i] : "" }
        while i < args.count {
            switch args[i] {
            case "--master": master = true
            case "--follower": master = false
            case "--name": name = next()
            case "--fullscreen": fullscreen = true
            case "--screen": screen = Int(next())
            case "--audio": audio = true
            case "--mute": audio = false
            case "--broadcast": broadcast = next()
            case "--to": extra.append(next())
            case "--log": log = true
            case "--log-interval": log = true; logInterval = Double(next()) ?? 1
            case "--autoplay": autoplay = Double(next()) ?? 2
            case "--quit-after": quitAfter = Double(next())
            case "--preset": preset = next()
            case "--switch-after": switchAfter = Double(next())
            default: file = args[i]
            }
            i += 1
        }
    }
}

/// The window's content: picture (Metal), edit handles, info text. Takes the keys.
final class ContainerView: NSView {
    var onKey: ((NSEvent) -> Bool)?
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) { if onKey?(event) != true { super.keyDown(with: event) } }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), let c = event.charactersIgnoringModifiers, c.count == 1,
           let d = Int(c), d >= 1 && d <= 9 {
            return onKey?(event) ?? false
        }
        return super.performKeyEquivalent(with: event)
    }
}

final class AppController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var opts: Options
    var window: NSWindow!
    var node: SyncNode!
    var master: Master?
    var follower: Follower?
    var renderer: VideoRenderer!
    var mtk: MTKView!
    let overlay = EditOverlay()
    let info = NSTextField(labelWithString: "")
    var panel: SettingsPanel?
    var tickTimer: Timer?
    var logTimer: Timer?
    var showHelp = false
    var audioOn = false
    var lastPreset = ""
    var message = ""            // short notice shown in the info text
    var messageUntil = 0.0
    private var saveWork: DispatchWorkItem?
    private var windowedFrame: NSRect?

    private(set) var settings = DisplaySettings()

    static let keyHelp = """
    space 再生／停止（マスター）  R 頭へ  ← → 5 秒（shift 1 秒）
    M マスター⇔フォロワー  S 設定パネル  I 情報  H キー一覧
    F 全画面  D 次の画面  A 音  G 格子
    E 四隅の変形  W 曲面メッシュ  Tab 次の点  矢印 1 px（shift 10 px）
    + − 大きさ  [ ] 回転  0 戻す（編集中はその変形、ほかは位置・大きさ・回転）
    1〜9 プリセット呼び出し  ⌘1〜⌘9 プリセット保存  Q 終了
    """

    init(opts: Options) { self.opts = opts }

    // MARK: launch

    func applicationDidFinishLaunching(_ n: Notification) {
        buildMenu()
        // Started by double-click (no file given): use the last movie, or ask for one.
        var chosen = opts.file
        if chosen == nil, let last = UserDefaults.standard.string(forKey: "lastMovie"),
           FileManager.default.fileExists(atPath: last) {
            chosen = last
        }
        if chosen == nil || !FileManager.default.fileExists(atPath: chosen!) {
            NSApp.activate(ignoringOtherApps: true)
            let p = NSOpenPanel()
            p.message = "同期再生する映像を選んでください"
            p.allowedContentTypes = [.movie, .video, .quickTimeMovie, .mpeg4Movie]
            guard p.runModal() == .OK, let u = p.url else {
                print("usage: SyncPlayer [--master|--follower] <movie> [--preset NAME] [--audio|--mute] ...")
                exit(1)
            }
            chosen = u.path
        }
        guard let given = chosen else { exit(1) }
        // Remember an absolute path: a relative one given on the command line would not be
        // found when the app is next started by double-click (its working directory is /).
        let path = URL(fileURLWithPath: given).standardizedFileURL.path
        UserDefaults.standard.set(path, forKey: "lastMovie")
        if let p = opts.preset, let s = PresetStore.load(p) { settings = s; lastPreset = p }
        else if let s = PresetStore.loadLast() { settings = s }
        if let sc = opts.screen { settings.screen = sc }
        if opts.fullscreen { settings.fullscreen = true }

        node = SyncNode(url: URL(fileURLWithPath: path), muted: true)
        audioOn = opts.audio ?? opts.master
        node.setMuted(!audioOn)

        buildWindow()
        setRole(master: opts.master)

        tickTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.node.tick()
            self?.updateInfo()
        }
        RunLoop.main.add(tickTimer!, forMode: .common)
        if opts.log {
            logTimer = Timer.scheduledTimer(withTimeInterval: opts.logInterval, repeats: true) { [weak self] _ in
                self?.printLog()
            }
        }
        if let a = opts.autoplay {
            DispatchQueue.main.asyncAfter(deadline: .now() + a) { [weak self] in self?.master?.play() }
        }
        if let sw = opts.switchAfter {
            DispatchQueue.main.asyncAfter(deadline: .now() + sw) { [weak self] in self?.toggleRole() }
        }
        if let q = opts.quitAfter {
            DispatchQueue.main.asyncAfter(deadline: .now() + q) { NSApp.terminate(nil) }
        }
    }

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "設定パネル", action: #selector(togglePanel), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "SyncPlayer を終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        NSApp.mainMenu = main
    }

    private func buildWindow() {
        let screens = NSScreen.screens
        let screen = screens.indices.contains(settings.screen) ? screens[settings.screen] : NSScreen.main!
        let frame = NSRect(x: screen.frame.minX + 80, y: screen.frame.minY + 80, width: 960, height: 540)
        window = NSWindow(contentRect: frame, styleMask: [.titled, .resizable, .closable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.delegate = self
        window.backgroundColor = .black
        let container = ContainerView(frame: NSRect(origin: .zero, size: frame.size))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor

        mtk = MTKView(frame: container.bounds)
        mtk.autoresizingMask = [.width, .height]
        guard let r = VideoRenderer(view: mtk) else { print("Metal is not available"); exit(1) }
        renderer = r
        renderer.node = node
        renderer.settings = settings
        renderer.onVideoAspect = { [weak self] in self?.overlay.needsDisplay = true }
        container.addSubview(mtk)

        overlay.frame = container.bounds
        overlay.autoresizingMask = [.width, .height]
        overlay.settings = { [unowned self] in self.settings }
        overlay.aspects = { [unowned self] in (self.renderer.viewAspect, self.renderer.videoAspect) }
        overlay.onChange = { [unowned self] s in self.updateSettings(s) }
        container.addSubview(overlay)

        info.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        info.textColor = .green
        info.backgroundColor = NSColor.black.withAlphaComponent(0.65)
        info.drawsBackground = true
        info.maximumNumberOfLines = 12
        info.frame = NSRect(x: 10, y: 10, width: 760, height: 60)
        container.addSubview(info)

        container.onKey = { [weak self] e in self?.key(e) ?? false }
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(container)
        NSApp.activate(ignoringOtherApps: true)
        if settings.fullscreen { setFullscreen(true) }
    }

    // MARK: settings & presets

    func updateSettings(_ s: DisplaySettings) {
        guard s != settings else { return }
        settings = s
        renderer.settings = s
        overlay.needsDisplay = true
        panel?.refresh()
        saveWork?.cancel()
        let w = DispatchWorkItem { PresetStore.saveLast(s) }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w)
    }

    func savePreset(_ name: String) {
        PresetStore.save(settings, as: name)
        lastPreset = name
        notify("プリセット「\(name)」を保存")
        panel?.refresh()
    }

    func loadPreset(_ name: String) {
        guard let s = PresetStore.load(name) else { notify("プリセット「\(name)」はありません"); return }
        let wasFull = settings.fullscreen, wasScreen = settings.screen
        updateSettings(s)
        lastPreset = name
        if s.screen != wasScreen { moveToScreen(s.screen) }
        if s.fullscreen != wasFull { setFullscreen(s.fullscreen) }
        notify("プリセット「\(name)」を読み込み")
    }

    func deletePreset(_ name: String) {
        PresetStore.delete(name)
        notify("プリセット「\(name)」を削除")
        panel?.refresh()
    }

    func notify(_ m: String) { message = m; messageUntil = hostNow() + 3 }

    // MARK: role

    func setRole(master wantMaster: Bool) {
        if wantMaster {
            guard master == nil else { return }
            let initial = follower?.localSchedule()
            // Outrank every master heard so far, whatever this Mac's wall clock says.
            let since = max(Date().timeIntervalSince1970, (follower?.highestSince ?? 0) + 0.001)
            follower?.stop(); follower = nil
            do {
                let m = try Master(node: node, broadcast: opts.broadcast, extraTargets: opts.extra,
                                   initial: initial, since: since)
                m.onDemote = { [weak self] in
                    self?.notify("ほかの Mac がマスターになったので、フォロワーに戻りました")
                    self?.setRole(master: false)
                }
                master = m
                notify("マスターになりました")
            } catch {
                notify("マスターになれません（この Mac で別のマスターが動いていませんか）")
                setRole(master: false)
                return
            }
        } else {
            let wasMaster = master != nil
            master?.stop(); master = nil
            if follower == nil {
                // A former master keeps playing its own schedule (offset 0) until it has the new clock.
                do { follower = try Follower(node: node, provisionalOffset: wasMaster ? 0 : nil) }
                catch { notify("ネットワークのエラー: \(error)") }
            }
        }
        window.title = "SyncPlayer — \(master != nil ? "マスター" : "フォロワー") — \(opts.name)"
        panel?.refresh()
    }

    func toggleRole() { setRole(master: master == nil) }

    // MARK: movie & audio

    func openFile() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.movie, .video, .quickTimeMovie, .mpeg4Movie]
        p.allowsMultipleSelection = false
        guard p.runModal() == .OK, let url = p.url else { return }
        UserDefaults.standard.set(url.path, forKey: "lastMovie")
        replaceMovie(url)
    }

    private func replaceMovie(_ url: URL) {
        let wasMaster = master != nil
        master?.stop(); master = nil
        follower?.stop(); follower = nil
        node.stop()
        node = SyncNode(url: url, muted: !audioOn)
        renderer.node = node
        setRole(master: wasMaster)
        notify("映像: \(url.lastPathComponent)")
    }

    func setAudio(_ on: Bool) {
        audioOn = on
        node.setMuted(!on)
        notify(on ? "音を出します" : "消音")
        panel?.refresh()
    }

    // MARK: window

    func setFullscreen(_ on: Bool) {
        var s = settings
        s.fullscreen = on
        let screens = NSScreen.screens
        let screen = screens.indices.contains(s.screen) ? screens[s.screen] : (window.screen ?? NSScreen.main!)
        if on {
            if window.styleMask.contains(.titled) { windowedFrame = window.frame }
            window.styleMask = [.borderless]
            window.setFrame(screen.frame, display: true)
            window.level = .normal
            if screen == NSScreen.screens.first {
                NSApp.presentationOptions = [.hideDock, .hideMenuBar]
            }
        } else {
            NSApp.presentationOptions = []
            window.styleMask = [.titled, .resizable, .closable, .miniaturizable]
            let f = windowedFrame ?? NSRect(x: screen.frame.minX + 80, y: screen.frame.minY + 80, width: 960, height: 540)
            window.setFrame(f, display: true)
        }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(window.contentView)
        updateSettings(s)
    }

    func moveToScreen(_ i: Int) {
        let screens = NSScreen.screens
        guard screens.indices.contains(i) else { return }
        var s = settings
        s.screen = i
        updateSettings(s)
        if settings.fullscreen {
            setFullscreen(true)
        } else {
            let f = screens[i].frame
            window.setFrameOrigin(NSPoint(x: f.minX + 80, y: f.minY + 80))
        }
        notify("画面 \(i + 1) へ")
    }

    @objc func togglePanel() {
        if panel == nil { panel = SettingsPanel(app: self) }
        guard let p = panel else { return }
        if p.isVisible { p.orderOut(nil) } else {
            p.refresh()
            p.setFrameTopLeftPoint(NSPoint(x: window.frame.maxX + 10, y: window.frame.maxY))
            p.orderFront(nil)
        }
    }

    func toggleEdit(_ m: EditMode) {
        overlay.mode = overlay.mode == m ? .none : m
        notify(overlay.mode == .corners ? "四隅の変形: 点をドラッグ、Tab で次、矢印で 1 px"
               : overlay.mode == .mesh ? "曲面メッシュ: 点をドラッグ、Tab で次、矢印で 1 px" : "変形の編集を終了")
        window.makeFirstResponder(window.contentView)
    }

    func windowWillClose(_ notification: Notification) { NSApp.terminate(nil) }

    // MARK: keys

    func key(_ e: NSEvent) -> Bool {
        let shift = e.modifierFlags.contains(.shift)
        let cmd = e.modifierFlags.contains(.command)
        let editing = overlay.mode != .none
        let px = shift ? 10.0 : 1.0
        var s = settings

        switch e.keyCode {
        case 49: master?.togglePlay(); return true                      // space
        case 48: overlay.selectNext(shift ? -1 : 1); return true         // tab
        case 53: if editing { toggleEdit(overlay.mode) }; return true    // esc
        case 123:                                                       // ←
            if editing { overlay.nudge(dx: -px, dy: 0) } else { master?.jump(by: shift ? -1 : -5) }
            return true
        case 124:                                                       // →
            if editing { overlay.nudge(dx: px, dy: 0) } else { master?.jump(by: shift ? 1 : 5) }
            return true
        case 125: if editing { overlay.nudge(dx: 0, dy: -px) }; return true   // ↓
        case 126: if editing { overlay.nudge(dx: 0, dy: px) }; return true    // ↑
        default: break
        }

        guard let c = e.charactersIgnoringModifiers?.lowercased(), let ch = c.first else { return false }
        if let d = Int(String(ch)), d >= 1 && d <= 9 {
            cmd ? savePreset(String(d)) : loadPreset(String(d))
            return true
        }
        switch ch {
        case "r": master?.jump(to: 0)
        case "m": toggleRole()
        case "s", ",": togglePanel()
        case "i": info.isHidden.toggle()
        case "h", "?": showHelp.toggle(); info.isHidden = false
        case "f": setFullscreen(!settings.fullscreen)
        case "d": moveToScreen((settings.screen + 1) % max(1, NSScreen.screens.count))
        case "a": setAudio(!audioOn)
        case "g": s.showGrid.toggle(); updateSettings(s)
        case "e": toggleEdit(.corners)
        case "w": toggleEdit(.mesh)
        case "+", "=": s.scale *= shift ? 1.1 : 1.01; updateSettings(s)
        case "-", "_": s.scale /= shift ? 1.1 : 1.01; updateSettings(s)
        case "[": s.rotation += shift ? 5 : 0.5; updateSettings(s)
        case "]": s.rotation -= shift ? 5 : 0.5; updateSettings(s)
        case "0":
            switch overlay.mode {
            case .corners: s.resetCorners()
            case .mesh: s.resetMesh()
            case .none: s.resetTransform()
            }
            updateSettings(s)
        case "q": NSApp.terminate(nil)
        default: return false
        }
        return true
    }

    // MARK: info

    func statusText() -> String {
        let pos = node.player.currentTime().seconds
        let p = pos.isFinite ? pos : 0
        var s = String(format: "%@ %@  %@  pos %.3f s  rate %.4f\n",
                       master != nil ? "MASTER" : "follower", opts.name, node.url.lastPathComponent, p, node.player.rate)
        s += String(format: "error %+.1f ms  avg %+.1f ms  jumps %d  loops %d",
                    node.lastError * 1000, node.errorEMA * 1000, node.resyncCount, node.loopCount)
        if let f = follower {
            let st = f.stats
            s += String(format: "\nmaster %@  clock %@ offset %+.3f ms  rtt %.3f ms",
                        f.masterHost, st.ready ? "ok" : "learning", st.offset * 1000, st.rtt * 1000)
            if node.schedule == nil { s += "  (waiting for master)" }
            if let mf = f.masterFile, mf != node.url.lastPathComponent { s += "\n⚠︎ マスターの映像は \(mf)" }
        } else if let m = master {
            s += m.schedule.playing ? "\n再生中 — space で停止" : "\n停止中 — space で再生"
        }
        if overlay.mode != .none { s += "\n編集: \(overlay.mode == .corners ? "四隅" : "曲面メッシュ")  点 \(overlay.selected + 1)/\(overlay.handleCount)" }
        if !lastPreset.isEmpty { s += "  プリセット \(lastPreset)" }
        if hostNow() < messageUntil { s += "\n" + message }
        if showHelp { s += "\n" + AppController.keyHelp }
        return s
    }

    private var infoTick = 0
    func updateInfo() {
        infoTick += 1
        if !info.isHidden {
            info.stringValue = statusText()
            let size = info.sizeThatFits(NSSize(width: 900, height: 600))
            info.frame = NSRect(x: 10, y: 10, width: min(size.width + 8, (window.contentView?.bounds.width ?? 900) - 20),
                                height: size.height + 4)
        }
        if infoTick % 10 == 0, let p = panel, p.isVisible { p.refreshStatus() }
    }

    func printLog() {
        let pos = node.player.currentTime().seconds
        var line = String(format: "%.3f\t%@\t%@\tpos=%.3f\terr_ms=%+.2f\tavg_ms=%+.2f\trate=%.4f\tjumps=%d\tloops=%d",
                          Date().timeIntervalSince1970, opts.name, master != nil ? "M" : "F",
                          pos.isFinite ? pos : 0, node.lastError * 1000, node.errorEMA * 1000, node.player.rate,
                          node.resyncCount, node.loopCount)
        if let st = follower?.stats {
            line += String(format: "\toffset_ms=%+.3f\trtt_ms=%.3f", st.offset * 1000, st.rtt * 1000)
        }
        print(line); fflush(stdout)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ n: Notification) { PresetStore.saveLast(settings) }
}

let opts = Options(CommandLine.arguments)
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppController(opts: opts)
app.delegate = delegate
app.run()
