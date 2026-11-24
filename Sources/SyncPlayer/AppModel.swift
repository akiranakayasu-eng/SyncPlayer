import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ServiceManagement

/// Fast-changing numbers for the control window (kept apart so the whole window is not redrawn 5 times a second).
final class StatusModel: ObservableObject {
    @Published var position = 0.0
    @Published var duration = 0.0
    @Published var playing = false
    @Published var isMaster = false
    @Published var text = ""
    /// One line at the top of the control window: what this Mac is doing now, in words.
    @Published var headline = ""
    /// 0 stopped / idle, 1 playing in step, 2 needs a look (waiting, master gone, clock still learning).
    @Published var tone = 0
}

/// The app: the show, the playback (transport + master/follower), the output windows and the control window.
final class AppModel: ObservableObject {
    var opts: Options
    let transport = Transport()
    let status = StatusModel()

    @Published var show = Show() { didSet { showDidChange(oldValue) } }
    @Published var selectedOutput: String? = nil { didSet { if selectedOutput != oldValue { fixSelection(); redrawOverlays() } } }
    @Published var selectedLayer: String? = nil { didSet { if selectedLayer != oldValue { selectedHandle = 0; redrawOverlays() } } }
    @Published var editMode: EditMode = .none { didSet { selectedHandle = 0; redrawOverlays() } }
    @Published var selectedHandle = 0 { didSet { redrawOverlays() } }
    @Published var isMaster = false
    @Published var audioOn = false
    @Published var presetNames: [String] = []
    @Published var lastPreset = ""
    /// The .syncshow opened or saved; changes are written to it as well as to current.syncshow.
    @Published var showFile: String? = nil {
        didSet { updateRepresented(); UserDefaults.standard.set(showFile, forKey: "showFile") }
    }
    /// What showFile holds now (so opening a file does not rewrite it unchanged).
    private var fileShow: Show?
    @Published var screenNames: [String] = []
    /// "ディスプレイ 1（1920×1080）" for the picker (the full names are too long for the side column).
    @Published var screenShort: [String] = []

    var master: Master?
    var follower: Follower?
    private(set) var outputs: [String: OutputWindow] = [:]
    var control: NSWindow?
    var preview: PictureView?
    var previewBox: AspectBox?
    var showHelp = false
    /// Info text on windowed outputs (shown unless I hides it).
    var infoHidden = false
    /// Info text on full-screen outputs (hidden unless I or H shows it, so an exhibition shows only the picture).
    var infoOnFull = false
    private var cursorHidden = false
    /// Keeps the display and the Mac awake while playing or while an output is full screen.
    private var awake: NSObjectProtocol?
    /// Large Mac name and screen number on every output (N key). On the master it also shows them on every Mac.
    @Published var showIdent = false
    /// An open / save panel is up (full-screen outputs stay down meanwhile).
    private var panelOpen = false
    /// S brought the control window above a full-screen output on its screen.
    private var controlRaised = false
    /// Another app came to the front after SyncPlayer was (not set when it started in the back,
    /// e.g. from the command line or at login, so outputs still cover the menu bar then).
    private var leftFront = false
    /// Info settings before H showed the key list (restored when it is closed).
    private var helpSaved: (Bool, Bool)?
    private var message = ""
    private var messageUntil = 0.0
    private var saveWork: DispatchWorkItem?
    private var tickTimer: Timer?
    private var logTimer: Timer?
    private var keyMonitor: Any?

    static let keyHelp = """
    space 再生／停止（マスター）  R 頭へ  ← → 5 秒（shift 1 秒）
    N この Mac の名前と画面の番号を大きく  M マスター⇔フォロワー  S 操作の窓（全画面の上にも出す／隠す）  I 情報（全画面では標準で隠す）  H キー一覧
    O 次の出力  L 次のレイヤー  F 全画面  D 次の画面  A 音  G 格子
    E 四隅の変形  W 曲面メッシュ  Tab 次の点  矢印 1 px（shift 10 px）
    + − 大きさ  [ ] 回転  0 戻す（編集中はその変形、ほかは位置・大きさ・回転）
    1〜9 プリセット呼び出し  ⌘1〜⌘9 プリセット保存  ⌘O ショーを開く  ⌘S ショーを保存  Q 終了
    """

    init(opts: Options) { self.opts = opts }

    // MARK: start

    func start() {
        buildMenu()
        refreshScreens()
        var s: Show?
        if let f = opts.showFile {
            s = ShowStore.read(URL(fileURLWithPath: f))
            if s == nil { print("cannot read show: \(f)") } else { showFile = absolute(f); fileShow = s }
        }
        let overridden = !opts.files.isEmpty || opts.preset != nil
        if overridden { detachShowFile(forget: false) }
        if s == nil {
            s = ShowStore.loadCurrent()
            // Keep writing to the show file opened last time, if it still holds the same show
            // (not when it was changed elsewhere since).
            if !overridden, let cur = s, let f = UserDefaults.standard.string(forKey: "showFile"),
               let fs = ShowStore.read(URL(fileURLWithPath: f)), fs == cur { showFile = f; fileShow = fs }
        }
        if !opts.files.isEmpty {
            let paths = opts.files.map(absolute)
            if var cur = s, cur.clips.count == paths.count {
                for i in cur.clips.indices { cur.clips[i].path = paths[i] }   // keep the layout, swap the movies
                s = cur
            } else {
                s = Show.make(paths: paths, look: s?.outputs.first?.layers.first?.look ?? DisplaySettings())
            }
        }
        let missing = s.map { !$0.clips.contains(where: { FileManager.default.fileExists(atPath: $0.path) }) } ?? true
        if missing {
            NSApp.activate(ignoringOtherApps: true)
            let n = s?.clips.count ?? 0
            let msg = n > 0 ? "映像が見つかりません。\(n) 本の映像を選ぶと、今の配置のまま使えます（同じ名前の映像は同じ場所に）"
                            : "同期再生する映像を選んでください（複数選べます）"
            let urls = pickMovies(message: msg, multiple: true)
            guard !urls.isEmpty else {
                print("usage: SyncPlayer [--master|--follower] <movie>... [--show FILE] [--preset NAME] [--audio|--mute] ...")
                exit(1)
            }
            if var cur = s, cur.clips.count == urls.count {
                // Keep the layout: same file names first, then the rest in order.
                var rest = urls
                var assigned = Array(repeating: false, count: cur.clips.count)
                for i in cur.clips.indices {
                    if let k = rest.firstIndex(where: { $0.lastPathComponent == cur.clips[i].name }) {
                        cur.clips[i].path = rest.remove(at: k).path; assigned[i] = true
                    }
                }
                for i in cur.clips.indices where !assigned[i] { cur.clips[i].path = rest.removeFirst().path }
                s = cur
            } else {
                // A different show: keep the old one aside and leave the opened file untouched.
                let prev = ShowStore.base.appendingPathComponent("current.prev.syncshow")
                try? FileManager.default.removeItem(at: prev)
                try? FileManager.default.copyItem(at: ShowStore.currentURL, to: prev)
                detachShowFile(forget: true)
                s = Show.make(paths: urls.map(\.path))
            }
        }
        guard var show0 = s else { exit(1) }
        if let p = opts.preset {
            switch ShowStore.loadPreset(p) {
            case .show(let ps): show0 = ps; lastPreset = p
            case .look(let l): if !show0.outputs.isEmpty, !show0.outputs[0].layers.isEmpty {
                show0.outputs[0].layers[0].look = l; lastPreset = p }
            case nil: print("no preset: \(p)")
            }
        }
        if show0.outputs.isEmpty, let c = show0.clips.first {
            show0.outputs = [OutputConfig(name: "画面 1", layers: [Layer(clipID: c.id)])]
        }
        if let sc = opts.screen { show0.outputs[0].screen = sc }
        if opts.fullscreen { show0.outputs[0].fullscreen = true }
        // The exhibition master (kept per Mac, not in the show) opens as master and plays.
        let startMaster = opts.roleGiven ? opts.master : exhibitMaster
        audioOn = opts.audio ?? show0.audioOn ?? startMaster
        presetNames = ShowStore.presetNames()

        buildControlWindow()
        show = show0
        selectedOutput = show.outputs.first?.id
        setRole(master: startMaster)
        installKeys()
        // Exhibition: the master plays by itself a few seconds after opening (followers catch up).
        if !opts.roleGiven && exhibitMaster && opts.autoplay == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, let m = self.master, !m.schedule.playing else { return }
                m.play()
                self.notify("開いたので自動で再生しました")
            }
        }
        // Another app or a macOS dialog (e.g. the local network permission) in front: full-screen
        // outputs step down so it is not hidden behind them; back up when SyncPlayer is active again.
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.leftFront = true; self?.refreshLevels() }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.leftFront = false; self?.refreshLevels()
            // Back from System Settings (the login item may have been approved there).
            let on = SMAppService.mainApp.status == .enabled
            if self?.loginItemOn != on { self?.loginItemOn = on }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.screensChanged() }

        tickTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in self?.tick() }
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

    private func absolute(_ p: String) -> String { URL(fileURLWithPath: p).standardizedFileURL.path }

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "SyncPlayer を終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        // Text editing (copy / paste in the name fields).
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "編集")
        edit.addItem(withTitle: "取り消す", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "カット", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "コピー", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "ペースト", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "すべてを選択", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        NSApp.mainMenu = main
    }

    // MARK: show changes

    private func showDidChange(_ old: Show) {
        if show.clips != old.clips { transport.setClips(show.clips) }
        // A show opened or a preset loaded brings this Mac's sound setting with it.
        var soundChanged = show.clips != old.clips || show.audioClip != old.audioClip
        if show.audioOn != old.audioOn, let a = show.audioOn, a != audioOn, opts.audio == nil { audioOn = a; soundChanged = true }
        if soundChanged { applyAudio() }
        if show.outputs != old.outputs { syncOutputs() }
        fixSelection()
        redrawOverlays()
        scheduleSave()
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w)
    }

    func saveNow() {
        saveWork?.cancel()
        _ = ShowStore.write(show, to: ShowStore.currentURL)
        if let f = showFile, show != fileShow {
            backUpOnce(f)
            if ShowStore.write(show, to: URL(fileURLWithPath: f)) { fileShow = show }
            else { notify("ショーのファイルに書けません: \((f as NSString).lastPathComponent)") }
        }
    }

    /// Stop writing to the show file. forget: false keeps it remembered for the next start.
    private func detachShowFile(forget: Bool) {
        let keep = UserDefaults.standard.string(forKey: "showFile")
        showFile = nil; fileShow = nil
        if !forget { UserDefaults.standard.set(keep, forKey: "showFile") }
    }

    private var backedUp: Set<String> = []
    /// Before the first change to a show file in this run, keep a copy of it in
    /// ~/Library/Application Support/SyncPlayer/backups/ (one per file name).
    private func backUpOnce(_ f: String) {
        guard !backedUp.contains(f) else { return }
        backedUp.insert(f)
        let dir = ShowStore.base.appendingPathComponent("backups", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dst = dir.appendingPathComponent((f as NSString).lastPathComponent)
        try? FileManager.default.removeItem(at: dst)
        try? FileManager.default.copyItem(at: URL(fileURLWithPath: f), to: dst)
    }

    private func fixSelection() {
        if selectedOutput == nil || !show.outputs.contains(where: { $0.id == selectedOutput }) {
            selectedOutput = show.outputs.first?.id
        }
        let layers = selectedOutputConfig?.layers ?? []
        if selectedLayer == nil || !layers.contains(where: { $0.id == selectedLayer }) {
            selectedLayer = layers.last?.id
        }
        // The mesh may have fewer points now (size changed, show or preset loaded).
        if let n = nudgeOverlay?.handleCount, selectedHandle >= n { selectedHandle = 0 }
    }

    var selectedOutputIndex: Int? { show.outputs.firstIndex { $0.id == selectedOutput } }
    var selectedOutputConfig: OutputConfig? { selectedOutputIndex.map { show.outputs[$0] } }
    var selectedLayerIndex: (o: Int, l: Int)? {
        guard let o = selectedOutputIndex, let l = show.outputs[o].layers.firstIndex(where: { $0.id == selectedLayer })
        else { return nil }
        return (o, l)
    }
    var selectedLook: DisplaySettings? { selectedLayerIndex.map { show.outputs[$0.o].layers[$0.l].look } }

    func updateLook(_ s: DisplaySettings) {
        guard let i = selectedLayerIndex, show.outputs[i.o].layers[i.l].look != s else { return }
        show.outputs[i.o].layers[i.l].look = s
    }

    func lookBinding<T>(_ kp: WritableKeyPath<DisplaySettings, T>, _ def: T) -> Binding<T> {
        Binding(get: { self.selectedLook?[keyPath: kp] ?? def },
                set: { v in guard var s = self.selectedLook else { return }; s[keyPath: kp] = v; self.updateLook(s) })
    }

    func layerBinding<T: Equatable>(_ kp: WritableKeyPath<Layer, T>, _ def: T) -> Binding<T> {
        Binding(get: { self.selectedLayerIndex.map { self.show.outputs[$0.o].layers[$0.l][keyPath: kp] } ?? def },
                set: { v in
                    guard let i = self.selectedLayerIndex, self.show.outputs[i.o].layers[i.l][keyPath: kp] != v else { return }
                    self.show.outputs[i.o].layers[i.l][keyPath: kp] = v })
    }

    func outputBinding<T: Equatable>(_ kp: WritableKeyPath<OutputConfig, T>, _ def: T) -> Binding<T> {
        Binding(get: { self.selectedOutputConfig?[keyPath: kp] ?? def },
                set: { v in
                    guard let o = self.selectedOutputIndex, self.show.outputs[o][keyPath: kp] != v else { return }
                    self.show.outputs[o][keyPath: kp] = v })
    }

    func visibleBinding(_ layerID: String) -> Binding<Bool> {
        Binding(get: { self.selectedOutputConfig?.layers.first { $0.id == layerID }?.visible ?? false },
                set: { v in
                    guard let o = self.selectedOutputIndex,
                          let l = self.show.outputs[o].layers.firstIndex(where: { $0.id == layerID }) else { return }
                    self.show.outputs[o].layers[l].visible = v })
    }

    // MARK: outputs

    /// The show file each window stands for (the last show in use when none was opened).
    /// Accessibility tools read it as the window's document.
    private func updateRepresented() {
        let u = showFile.map { URL(fileURLWithPath: $0) } ?? ShowStore.currentURL
        control?.representedURL = u
        for w in outputs.values { w.window.representedURL = u }
    }

    private func outputTitle(_ o: OutputConfig) -> String {
        "SyncPlayer — \(o.name) — \(isMaster ? "マスター" : "フォロワー") — \(opts.name)"
    }

    private func syncOutputs() {
        let ids = Set(show.outputs.map(\.id))
        for (id, w) in outputs where !ids.contains(id) { w.close(); outputs[id] = nil }
        var created = false
        for (i, o) in show.outputs.enumerated() {
            if outputs[o.id] == nil {
                guard let w = OutputWindow(id: o.id) else { print("Metal is not available"); exit(1) }
                configure(w)
                outputs[o.id] = w
                w.window.representedURL = showFile.map { URL(fileURLWithPath: $0) } ?? ShowStore.currentURL
                w.apply(o, index: i, title: outputTitle(o))
                w.window.makeKeyAndOrderFront(nil)
                created = true
            } else {
                outputs[o.id]?.apply(o, index: i, title: outputTitle(o))
            }
        }
        // A new windowed output must not hide the control window (full-screen outputs stay above it anyway).
        if created, let c = control, c.isVisible { c.orderFront(nil) }
        refreshInfo()
        updatePresentation()
    }

    private func configure(_ w: OutputWindow) {
        let id = w.id
        let r = w.picture.renderer
        r.layers = { [weak self] in self?.show.outputs.first { $0.id == id }?.layers ?? [] }
        r.frames = { [weak self] clip in self?.transport.frames[clip] }
        setupOverlay(w.picture.overlay, outputID: { id }, viewAspect: { [weak w] in w?.viewAspect ?? 16.0 / 9.0 })
        w.onBecomeKey = { [weak self] in
            if self?.selectedOutput != id { self?.selectedOutput = id }
        }
    }

    private func setupOverlay(_ ov: EditOverlay, outputID: @escaping () -> String?, viewAspect: @escaping () -> Double) {
        ov.modeOf = { [weak self] in self?.editMode ?? .none }
        ov.selectedOf = { [weak self] in self?.selectedHandle ?? 0 }
        ov.select = { [weak self] k in self?.selectedHandle = k }
        ov.settings = { [weak self] in
            guard let self, let id = outputID(), id == self.selectedOutput else { return nil }
            return self.selectedLook
        }
        ov.aspects = { [weak self] in
            var video = 16.0 / 9.0
            if let self, let i = self.selectedLayerIndex,
               let a = self.transport.frames[self.show.outputs[i.o].layers[i.l].clipID]?.aspect, a > 0 { video = a }
            return (viewAspect(), video)
        }
        ov.onChange = { [weak self] s in self?.updateLook(s) }
    }

    private func updatePresentation() {
        let first = NSScreen.screens.first
        let coversMain = show.outputs.contains { o in
            o.fullscreen && (NSScreen.screens.indices.contains(o.screen) ? Optional(NSScreen.screens[o.screen]) : NSScreen.main) == first
        }
        NSApp.presentationOptions = coversMain ? [.hideDock, .hideMenuBar] : []
    }

    /// Whether the info text is shown now (on full-screen outputs when there are any).
    var infoShownNow: Bool { outputs.values.contains(where: { $0.isFull }) ? infoOnFull : !infoHidden }

    /// One switch for every output (I key and the control window).
    func setInfoShown(_ on: Bool) {
        infoOnFull = on; infoHidden = !on
        helpSaved = nil
        refreshInfo()
        objectWillChange.send()
    }

    /// Show or hide the info text on each output (full-screen ones follow infoOnFull).
    private func refreshInfo() {
        for w in outputs.values { w.info.isHidden = w.isFull ? !infoOnFull : infoHidden }
        refreshLevels()
    }

    /// Hide the pointer while the front-most window under it is a full-screen output (so it shows
    /// over the control window, open / save panels and other apps' windows), not while editing points.
    private func updateCursor() {
        let p = NSEvent.mouseLocation
        let top = NSWindow.windowNumber(at: p, belowWindowWithWindowNumber: 0)
        let hide = NSApp.isActive && editMode == .none
            && outputs.values.contains { $0.isFull && $0.window.isVisible && $0.window.windowNumber == top }
        if hide != cursorHidden {
            cursorHidden = hide
            if hide { NSCursor.hide() } else { NSCursor.unhide() }
        }
    }

    private func screensChanged() {
        refreshScreens()
        for (i, o) in show.outputs.enumerated() { outputs[o.id]?.replace(o, index: i, title: outputTitle(o)) }
        refreshInfo()
        updatePresentation()
        notify("画面のつながりが変わりました（\(NSScreen.screens.count) 枚）")
    }

    func refreshScreens() {
        screenNames = NSScreen.screens.enumerated().map { i, s in
            "\(i + 1): \(s.localizedName)  \(Int(s.frame.width))×\(Int(s.frame.height))"
        }
        screenShort = NSScreen.screens.enumerated().map { i, s in
            "ディスプレイ \(i + 1)（\(Int(s.frame.width))×\(Int(s.frame.height))）"
        }
    }

    func redrawOverlays() {
        for w in outputs.values { w.picture.overlay.needsDisplay = true }
        preview?.overlay.needsDisplay = true
    }

    func addOutput() {
        let used = Set(show.outputs.map(\.screen))
        let screen = (0..<NSScreen.screens.count).first { !used.contains($0) } ?? 0
        var o = OutputConfig(name: "画面 \(show.outputs.count + 1)", screen: screen)
        if let c = show.clips.first { o.layers = [Layer(clipID: c.id)] }
        show.outputs.append(o)
        selectedOutput = o.id
        notify("出力「\(o.name)」を足しました（画面 \(screen + 1)）")
    }

    func removeOutput() {
        guard show.outputs.count > 1, let o = selectedOutputIndex else { notify("出力は 1 つ以上要ります"); return }
        let name = show.outputs[o].name
        show.outputs.remove(at: o)
        notify("出力「\(name)」を消しました")
    }

    func selectNextOutput() {
        guard !show.outputs.isEmpty else { return }
        let i = ((selectedOutputIndex ?? -1) + 1) % show.outputs.count
        selectedOutput = show.outputs[i].id
        notify("出力: \(show.outputs[i].name)")
    }

    func toggleFullscreen() {
        guard let o = selectedOutputIndex else { return }
        show.outputs[o].fullscreen.toggle()
        outputs[show.outputs[o].id]?.window.makeKeyAndOrderFront(nil)
    }

    func moveToNextScreen() {
        guard let o = selectedOutputIndex else { return }
        let n = max(1, NSScreen.screens.count)
        show.outputs[o].screen = (show.outputs[o].screen + 1) % n
        notify("\(show.outputs[o].name) を画面 \(show.outputs[o].screen + 1) へ")
    }

    // MARK: layers

    func addLayer() {
        guard let o = selectedOutputIndex, let c = show.clips.first else { return }
        let l = Layer(clipID: c.id)
        show.outputs[o].layers.append(l)
        selectedLayer = l.id
    }

    func removeLayer() {
        guard let i = selectedLayerIndex else { return }
        show.outputs[i.o].layers.remove(at: i.l)
    }

    /// Move the selected layer toward the front (+1) or back (-1).
    func moveLayer(_ d: Int) {
        guard let i = selectedLayerIndex else { return }
        let j = i.l + d
        guard show.outputs[i.o].layers.indices.contains(j) else { return }
        show.outputs[i.o].layers.swapAt(i.l, j)
    }

    func selectNextLayer() {
        guard let o = selectedOutputConfig, !o.layers.isEmpty else { return }
        let ids = o.layers.reversed().map(\.id)   // the order the list shows
        let k = ids.firstIndex(where: { $0 == selectedLayer }) ?? -1
        selectedLayer = ids[(k + 1) % ids.count]
        if let c = selectedLayerIndex.flatMap({ show.clip(show.outputs[$0.o].layers[$0.l].clipID) }) { notify("レイヤー: \(c.name)") }
    }

    func arrangeGrid() {
        guard let o = selectedOutputIndex else { return }
        show.arrangeGrid(output: o)
        notify("レイヤーを格子に並べました")
    }

    // MARK: clips

    private func pickMovies(message: String, multiple: Bool) -> [URL] {
        let p = NSOpenPanel()
        p.message = message
        p.allowedContentTypes = [.movie, .video, .quickTimeMovie, .mpeg4Movie]
        p.allowsMultipleSelection = multiple
        return runPanel(p) == .OK ? p.urls : []
    }

    /// Add movies; each also gets a layer on the selected output.
    func addClips() {
        let urls = pickMovies(message: "足す映像を選んでください（複数選べます）", multiple: true)
        guard !urls.isEmpty else { return }
        var s = show
        for u in urls {
            let c = Clip(id: s.newClipID(), path: u.path)
            s.clips.append(c)
            if let o = selectedOutputIndex { s.outputs[o].layers.append(Layer(clipID: c.id)) }
        }
        show = s
        notify("映像を \(urls.count) つ足しました")
    }

    func replaceClip(_ id: String) {
        guard let i = show.clips.firstIndex(where: { $0.id == id }),
              let u = pickMovies(message: "「\(show.clips[i].name)」と入れ替える映像", multiple: false).first else { return }
        show.clips[i].path = u.path
        notify("映像: \(u.lastPathComponent)")
    }

    func removeClip(_ id: String) {
        guard show.clips.count > 1 else { notify("映像は 1 つ以上要ります"); return }
        var s = show
        s.clips.removeAll { $0.id == id }
        for o in s.outputs.indices { s.outputs[o].layers.removeAll { $0.clipID == id } }
        if s.audioClip == id { s.audioClip = nil }
        show = s
    }

    func clipName(_ id: String) -> String { show.clip(id)?.name ?? "（なし）" }

    // MARK: show files & presets

    func openShow() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [ShowStore.fileType, .json]
        p.message = "ショーのファイル（.syncshow）を開く"
        guard runPanel(p) == .OK, let u = p.url else { return }
        openShow(at: u)
    }

    func openShow(at u: URL) {
        guard let s = ShowStore.read(u) else { notify("開けませんでした: \(u.lastPathComponent)"); return }
        saveNow()   // finish writing the previous file first
        showFile = u.path
        fileShow = s
        applyShow(s)
        notify("ショー: \(u.lastPathComponent)")
    }

    func saveShowAs() {
        let p = NSSavePanel()
        p.allowedContentTypes = [ShowStore.fileType]
        p.nameFieldStringValue = showFile.map { ($0 as NSString).lastPathComponent } ?? "show.syncshow"
        p.message = "ショーを保存（映像は同じフォルダに置くと、ほかの Mac でもそのまま開けます）"
        guard runPanel(p) == .OK, let u = p.url else { return }
        if ShowStore.write(show, to: u) { showFile = u.path; fileShow = show; notify("保存: \(u.lastPathComponent)") }
        else { notify("保存できませんでした") }
    }

    func applyShow(_ s: Show) {
        show = s
        fixSelection()
    }

    func savePreset(_ name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        if ShowStore.savePreset(show, as: n) { lastPreset = n; notify("プリセット「\(n)」を保存") }
        presetNames = ShowStore.presetNames()
    }

    func loadPreset(_ name: String) {
        switch ShowStore.loadPreset(name) {
        case .show(let s):
            // A preset is another show: keep the opened file as it is.
            if let f = showFile {
                saveNow(); detachShowFile(forget: false)
                notify("プリセット「\(name)」を読み込み（\((f as NSString).lastPathComponent) には書きません）")
                applyShow(s); lastPreset = name
                return
            }
            applyShow(s)
        case .look(let l):
            var l = l
            if let cur = selectedLook { l.screen = cur.screen; l.fullscreen = cur.fullscreen }
            updateLook(l)
        case nil: notify("プリセット「\(name)」はありません"); return
        }
        lastPreset = name
        notify("プリセット「\(name)」を読み込み")
    }

    func deletePreset(_ name: String) {
        ShowStore.deletePreset(name)
        presetNames = ShowStore.presetNames()
        notify("プリセット「\(name)」を削除")
    }

    // MARK: role & audio

    func setRole(master wantMaster: Bool) {
        if wantMaster {
            if master == nil {
                let initial = follower?.localSchedule()
                // Outrank every master heard so far, whatever this Mac's wall clock says.
                let since = max(Date().timeIntervalSince1970, (follower?.highestSince ?? 0) + 0.001)
                follower?.stop(); follower = nil
                do {
                    let m = try Master(transport: transport, broadcast: opts.broadcast, extraTargets: opts.extra,
                                       initial: initial, since: since,
                                       fileLabel: { [weak self] in self?.show.fileLabel ?? "" },
                                       loopPolicy: { [weak self] in (self?.show.loopTogether ?? true, self?.show.loopLength ?? 0) })
                    m.ident = { [weak self] in self?.showIdent ?? false }
                    m.name = opts.name
                    m.onDemote = { [weak self] in
                        // The exhibition-master mark stays: this Mac is still the one to start as master
                        // after a restart (another Mac took over by hand for now).
                        if self?.exhibitMaster == true { self?.exhibitTakenOver = true }
                        self?.notify(self?.exhibitMaster == true
                            ? "ほかの Mac がマスターになりました（この Mac は「展示のマスター」のままで、次に開くとマスターで始まります）"
                            : "ほかの Mac がマスターになったので、フォロワーに戻りました")
                        self?.setRole(master: false)
                    }
                    master = m
                    notify("マスターになりました")
                } catch {
                    notify("マスターになれません（この Mac で別のマスターが動いていませんか）")
                    setRole(master: false)
                    return
                }
            }
        } else {
            let wasMaster = master != nil
            master?.stop(); master = nil
            if follower == nil {
                // A former master keeps playing its own schedule (offset 0) until it has the new clock.
                do { follower = try Follower(transport: transport, provisionalOffset: wasMaster ? 0 : nil) }
                catch { notify("ネットワークのエラー: \(error)") }
            }
        }
        isMaster = master != nil
        status.isMaster = isMaster
        for (i, o) in show.outputs.enumerated() { outputs[o.id]?.apply(o, index: i, title: outputTitle(o)) }
        control?.title = "SyncPlayer — 操作 — \(isMaster ? "マスター" : "フォロワー") — \(opts.name)"
    }

    func toggleRole() { setRoleByHand(master: master == nil) }

    /// Role changed by hand (M, the switch): the "taken over" notice no longer applies.
    func setRoleByHand(master m: Bool) {
        exhibitTakenOver = false
        setRole(master: m)
    }

    /// This Mac is the exhibition master: it opens as master and starts playing by itself.
    /// Kept for this Mac (UserDefaults), not in the show, so copying a show to other Macs does not
    /// make them masters too.
    @Published var exhibitMaster = UserDefaults.standard.bool(forKey: "exhibitMaster") {
        didSet { UserDefaults.standard.set(exhibitMaster, forKey: "exhibitMaster") }
    }

    /// Another master took over while this Mac is the exhibition master (shown in the status).
    private var exhibitTakenOver = false

    func setExhibitMaster(_ on: Bool) {
        exhibitMaster = on
        exhibitTakenOver = false
        if on && master == nil { setRole(master: true) }
    }

    /// Open SyncPlayer when this Mac's user logs in (macOS Login Items). Read once and after changes.
    @Published private(set) var loginItemOn = SMAppService.mainApp.status == .enabled
    var openAtLogin: Bool {
        get { loginItemOn }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                notify("ログイン時に開く設定ができません: \(error.localizedDescription)")
            }
            if newValue && SMAppService.mainApp.status == .requiresApproval {
                notify("システム設定 → 一般 → ログイン項目 で SyncPlayer を許可してください")
                SMAppService.openSystemSettingsLoginItems()
            }
            loginItemOn = SMAppService.mainApp.status == .enabled
        }
    }

    func applyAudio() { transport.setAudio(clipID: show.audioClip ?? show.clips.first?.id, on: audioOn) }

    func setAudio(_ on: Bool) {
        audioOn = on
        applyAudio()
        if show.audioOn != on { show.audioOn = on }   // kept in this Mac's show
        notify(on ? "音を出します" : "消音")
    }

    func setAudioClip(_ id: String?) {
        show.audioClip = id
        applyAudio()
    }

    func notify(_ m: String) { message = m; messageUntil = hostNow() + 3 }

    // MARK: control window

    private func buildControlWindow() {
        let pv = PictureView(fps: 30)
        guard let pv else { print("Metal is not available"); exit(1) }
        preview = pv
        pv.renderer.layers = { [weak self] in self?.selectedOutputConfig?.layers ?? [] }
        pv.renderer.frames = { [weak self] clip in self?.transport.frames[clip] }
        setupOverlay(pv.overlay, outputID: { [weak self] in self?.selectedOutput },
                     viewAspect: { [weak self] in self?.selectedOutputAspect ?? 16.0 / 9.0 })
        previewBox = AspectBox(child: pv)

        let screen = NSScreen.main ?? NSScreen.screens[0]
        let vf = screen.visibleFrame
        let w = min(1180, vf.width - 40), h = min(760, vf.height - 40)
        let win = NSWindow(contentRect: NSRect(x: vf.minX + 20, y: vf.minY + 20, width: w, height: h),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: 960, height: 600)
        win.contentView = NSHostingView(rootView: ControlView(model: self, status: status))
        win.title = "SyncPlayer — 操作"
        control = win
        updateRepresented()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The selected output's shape (its window), so the preview matches it.
    var selectedOutputAspect: Double {
        guard let id = selectedOutput, let w = outputs[id] else { return 16.0 / 9.0 }
        return w.viewAspect
    }

    func toggleControl() {
        guard let c = control else { return }
        // By frames: a hidden window may not report its screen.
        let coveredScreen = outputs.values.contains { $0.isFull && $0.window.frame.intersects(c.frame) }
        // Hide only when it is really in front (it may hold the keys while a full-screen output covers it).
        if c.isVisible && c.isKeyWindow && (!coveredScreen || controlRaised) {
            c.orderOut(nil); controlRaised = false; refreshLevels(); return
        }
        // Above a full-screen output on its screen while it is up; S again hides it.
        controlRaised = coveredScreen
        NSApp.activate(ignoringOtherApps: true)
        refreshLevels()
        c.makeKeyAndOrderFront(nil)
    }

    /// The one place that sets window levels. A full-screen output is above the menu bar while
    /// SyncPlayer has not left the front and no open / save panel is up. When another app or a macOS
    /// dialog comes to the front, only the outputs on the main screen (where dialogs and the menu bar
    /// appear) step down; outputs on other screens stay up.
    func refreshLevels() {
        let main = NSScreen.screens.first
        for w in outputs.values {
            let up = w.isFull && !panelOpen && (!leftFront || w.window.screen != main)
            let level: NSWindow.Level = up ? OutputWindow.fullLevel : .normal
            if w.window.level != level { w.window.level = level }
        }
        if let c = control {
            let raise = controlRaised && !leftFront && !panelOpen && outputs.values.contains { $0.isFull }
            let level: NSWindow.Level = raise ? NSWindow.Level(rawValue: OutputWindow.fullLevel.rawValue + 1) : .normal
            if c.level != level { c.level = level }
        }
    }

    /// Run an open / save panel. Full-screen outputs sit above the menu bar, so they are lowered
    /// while the panel is up (otherwise it could open behind them), also if the app is left and
    /// entered again meanwhile.
    func runPanel(_ p: NSSavePanel) -> NSApplication.ModalResponse {
        panelOpen = true
        refreshLevels()
        defer { panelOpen = false; refreshLevels() }
        NSApp.activate(ignoringOtherApps: true)
        return p.runModal()
    }

    /// Pick a mask image for the selected layer.
    func pickMask() {
        guard let o0 = selectedOutput, let l0 = selectedLayer else { return }
        let p = NSOpenPanel()
        p.allowedContentTypes = [.image]
        p.message = "マスクの画像（白は見える、黒は隠れる。映像と同じ縦横比にする。ショーと同じフォルダに置くと、ほかの Mac でもそのまま使えます）"
        guard runPanel(p) == .OK, let u = p.url else { return }
        guard let gpu = GPU.shared, GPU.loadMask(u.path, device: gpu.device) != nil else {
            notify("画像を読めませんでした: \(u.lastPathComponent)"); return
        }
        // The show may have changed while the panel was open: find the layer again.
        guard let o = show.outputs.firstIndex(where: { $0.id == o0 }),
              let l = show.outputs[o].layers.firstIndex(where: { $0.id == l0 }) else { return }
        show.outputs[o].layers[l].mask = u.path
    }

    func toggleEdit(_ m: EditMode) {
        editMode = editMode == m ? .none : m
        notify(editMode == .corners ? "四隅の変形: 点をドラッグ、Tab で次、矢印で 1 px"
               : editMode == .mesh ? "曲面メッシュ: 点をドラッグ、Tab で次、矢印で 1 px" : "変形の編集を終了")
    }

    // MARK: keys

    private func installKeys() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self else { return e }
            // Only in our own windows, and never while a text field is being typed in.
            guard let w = NSApp.keyWindow, w === self.control || self.outputs.values.contains(where: { $0.window === w })
            else { return e }
            if w.firstResponder is NSText { return e }
            return self.key(e) ? nil : e
        }
    }

    /// The overlay to nudge in pixels: the selected output's window, else the preview.
    private var nudgeOverlay: EditOverlay? {
        if let id = selectedOutput, let w = outputs[id] { return w.picture.overlay }
        return preview?.overlay
    }

    func key(_ e: NSEvent) -> Bool {
        let shift = e.modifierFlags.contains(.shift)
        let cmd = e.modifierFlags.contains(.command)
        let editing = editMode != .none
        let px = shift ? 10.0 : 1.0
        var s = selectedLook ?? DisplaySettings()
        let hasLayer = selectedLook != nil

        if cmd {
            guard let c = e.charactersIgnoringModifiers?.lowercased(), let ch = c.first else { return false }
            if let d = Int(String(ch)), d >= 1 && d <= 9 { savePreset(String(d)); return true }
            switch ch {
            case "o": openShow(); return true
            case "s": saveShowAs(); return true
            case ",": toggleControl(); return true
            default: return false   // ⌘Q, copy / paste and the rest go to the menu
            }
        }

        switch e.keyCode {
        case 49: master?.togglePlay(); return true                      // space
        case 48: nudgeOverlay?.selectNext(shift ? -1 : 1); return true   // tab
        case 53: if editing { toggleEdit(editMode) }; return true       // esc
        case 123:                                                       // ←
            if editing { nudgeOverlay?.nudge(dx: -px, dy: 0) } else { master?.jump(by: shift ? -1 : -5) }
            return true
        case 124:                                                       // →
            if editing { nudgeOverlay?.nudge(dx: px, dy: 0) } else { master?.jump(by: shift ? 1 : 5) }
            return true
        case 125: if editing { nudgeOverlay?.nudge(dx: 0, dy: -px) }; return true   // ↓
        case 126: if editing { nudgeOverlay?.nudge(dx: 0, dy: px) }; return true    // ↑
        default: break
        }

        guard let c = e.charactersIgnoringModifiers?.lowercased(), let ch = c.first else { return false }
        if let d = Int(String(ch)), d >= 1 && d <= 9 { loadPreset(String(d)); return true }
        switch ch {
        case "r": master?.jump(to: 0)
        case "m": toggleRole()
        case "s": toggleControl()
        case "i": setInfoShown(!infoShownNow)
        case "h", "?":
            showHelp.toggle()
            if showHelp {
                helpSaved = (infoHidden, infoOnFull)
                infoHidden = false; infoOnFull = true
            } else if let h = helpSaved {
                (infoHidden, infoOnFull) = h   // back to how it was before H
                helpSaved = nil
            }
            refreshInfo()
        case "f": toggleFullscreen()
        case "d": moveToNextScreen()
        case "o": selectNextOutput()
        case "l": selectNextLayer()
        case "a": setAudio(!audioOn)
        case "n": showIdent.toggle()
        case "q": NSApp.terminate(nil)
        case "g", "e", "w", "+", "=", "-", "_", "[", "]", "0":
            guard hasLayer else { notify("レイヤーを選んでください"); return true }
            switch ch {
            case "g": s.showGrid.toggle()
            case "e": toggleEdit(.corners); return true
            case "w": toggleEdit(.mesh); return true
            case "+", "=": s.scale *= shift ? 1.1 : 1.01
            case "-", "_": s.scale /= shift ? 1.1 : 1.01
            case "[": s.rotation += shift ? 5 : 0.5
            case "]": s.rotation -= shift ? 5 : 0.5
            default:
                switch editMode {
                case .corners: s.resetCorners()
                case .mesh: s.resetMesh()
                case .none: s.resetTransform()
                }
            }
            updateLook(s)
        default: return false
        }
        return true
    }

    // MARK: status

    private var tickCount = 0
    private func tick() {
        transport.tick()
        tickCount += 1
        updateCursor()
        let keepAwake = (transport.schedule?.playing ?? false) || outputs.values.contains { $0.isFull }
        if keepAwake && awake == nil {
            awake = ProcessInfo.processInfo.beginActivity(options: [.idleDisplaySleepDisabled, .idleSystemSleepDisabled],
                                                          reason: "SyncPlayer: playing or showing full screen")
        } else if !keepAwake, let a = awake {
            ProcessInfo.processInfo.endActivity(a); awake = nil
        }
        guard tickCount % 4 == 0 else { return }
        status.position = transport.displayTime()
        status.duration = transport.duration
        status.playing = transport.schedule?.playing ?? false
        let text = statusText()
        if status.text != text { status.text = text }
        let (headline, tone) = headlineNow()
        if status.headline != headline { status.headline = headline }
        if status.tone != tone { status.tone = tone }
        let short = outputInfo()
        for w in outputs.values { w.layoutInfo(short) }
        for (id, w) in outputs {
            // Shown when N is on here, or when the master has N on (every Mac at once).
            guard showIdent || (follower.map { $0.masterIdent && $0.masterAlive } ?? false), let o = show.outputs.first(where: { $0.id == id }) else { w.layoutIdent(nil); continue }
            // The display the window is really on (numbered as in the control window's screen list);
            // when that differs from the setting (not plugged in, moved by hand), both are shown.
            let real = w.window.screen.flatMap { NSScreen.screens.firstIndex(of: $0) }.map { $0 + 1 }
            let set = o.screen + 1
            let disp = real == nil || real == set ? "ディスプレイ \(set)" : "ディスプレイ \(real!)（設定は \(set)）"
            w.layoutIdent("\(opts.name)\n\(disp)\n\(o.name)")
        }
        previewBox?.aspect = selectedOutputAspect
        if editMode != .none && tickCount % 20 == 0 { redrawOverlays() }
    }

    /// The state in plain words for the top of the control window.
    private func headlineNow() -> (String, Int) {
        let playing = transport.schedule?.playing ?? false
        if isMaster {
            return playing ? ("再生中 ・ この Mac がマスター", 1) : ("停止中 ・ この Mac がマスター（space で再生）", 0)
        }
        guard let f = follower else { return ("準備中", 2) }
        if transport.schedule == nil { return ("マスター待ち ・ マスターの Mac を開くと、そろって始まる", 2) }
        if !f.masterAlive { return ("マスターが見えない ・ この Mac はそのまま再生を続けている", 2) }
        let who = f.masterName ?? f.masterHost
        if !f.stats.ready { return ("マスター（\(who)）と時計を合わせている…", 2) }
        let err = String(format: "%.1f", abs(transport.maxError) * 1000)
        return playing ? ("マスター（\(who)）に合わせて再生中 ・ ずれ \(err) ms", 1)
                       : ("マスター（\(who)）が停止中", 0)
    }

    private func roleLine() -> String {
        String(format: "%@ %@  %@\npos %.3f s  error %+.1f ms  jumps %d",
               isMaster ? "MASTER" : "follower", opts.name, show.fileLabel, transport.displayTime(),
               transport.maxError * 1000, transport.resyncCount)
    }

    private func clockLines() -> String {
        var s = ""
        if let c = transport.schedule?.cycle, c > 0 {
            s += String(format: "\nループ %.3f s（全員いっしょ、短い映像は最後のコマで待つ）", c)
        } else if transport.schedule != nil {
            s += "\nループ: 映像ごとの尺"
        }
        if let f = follower {
            let st = f.stats
            s += String(format: "\nmaster %@  clock %@ offset %+.3f ms  rtt %.3f ms",
                        f.masterName.map { "\($0) (\(f.masterHost))" } ?? f.masterHost, st.ready ? "ok" : "learning", st.offset * 1000, st.rtt * 1000)
            if transport.schedule == nil { s += "  (waiting for master)" }
            if let mf = f.masterFile, mf != show.fileLabel { s += "\n⚠︎ マスターの映像は \(mf)" }
        } else if let m = master {
            s += m.schedule.playing ? "\n再生中 — space で停止" : "\n停止中 — space で再生"
        }
        return s
    }

    /// Text on the output windows.
    private func outputInfo() -> String {
        var s = roleLine() + clockLines()
        if editMode != .none, nudgeOverlay != nil {
            s += "\n編集: \(editMode == .corners ? "四隅" : "曲面メッシュ")  点 \(selectedHandle + 1)/\(nudgeOverlay?.handleCount ?? 0)"
        }
        if !lastPreset.isEmpty { s += "  プリセット \(lastPreset)" }
        if hostNow() < messageUntil { s += "\n" + message }
        if showHelp { s += "\n" + AppModel.keyHelp }
        return s
    }

    private var missingCache: (at: Double, paths: Set<String>) = (-10, [])
    /// Movies and mask images not found on disk, checked at most every 2 s (a sleeping disk can be slow to answer).
    private func missingFiles() -> Set<String> {
        let now = hostNow()
        if now - missingCache.at > 2 {
            let masks = show.outputs.flatMap { $0.layers.compactMap(\.mask) }
            missingCache = (now, Set((transport.orderedNodes.map(\.node.url.path) + masks)
                                        .filter { !FileManager.default.fileExists(atPath: $0) }))
        }
        return missingCache.paths
    }

    /// Text in the control window: each clip's state as well.
    private func statusText() -> String {
        var s = roleLine()
        // Warnings first: the status box shows about 8 lines.
        if exhibitTakenOver && exhibitMaster && master == nil {
            s += "\n⚠︎ この Mac は「展示のマスター」ですが、ほかの Mac がマスターです。ほかの Mac にも「展示のマスター」が入っていませんか（入れるのは 1 台だけ）"
        }
        for o in show.outputs {
            for l in o.layers {
                guard let m = l.mask else { continue }
                let name = (m as NSString).lastPathComponent
                if missingFiles().contains(m) {
                    s += "\n⚠︎ マスク \(name) が見つかりません（\(o.name)）— マスクなしで映っています"
                } else if GPU.shared?.maskReady(m) == false {
                    s += "\n⚠︎ マスク \(name) を読めません（\(o.name)）— マスクなしで映っています"
                }
            }
        }
        s += clockLines()
        for (id, n) in transport.orderedNodes {
            let name = clipName(id)
            if n.items.contains(where: { $0.status == .failed }) || missingFiles().contains(n.url.path) {
                s += "\n\(name): 開けません"
            } else if !n.ready {
                s += "\n\(name): 読み込み中"
            } else {
                s += String(format: "\n%@: %.1f s  error %+.2f ms  avg %+.2f ms  jumps %d  loops %d",
                            name, n.duration, n.lastError * 1000, n.errorEMA * 1000, n.resyncCount, n.loopCount)
                if let f = transport.frames[id] {
                    s += String(format: "  %dx%d %@%@  dropped %d",
                                Int(n.videoSize.width), Int(n.videoSize.height), f.format,
                                f.gaveUp ? "（コマが届かない）" : f.fellBack ? "（形を下げた）" : "", f.framesDropped)
                }
            }
        }
        let draws = show.outputs.compactMap { o in outputs[o.id].map { String(format: "%@ %.0f fps", o.name, $0.picture.renderer.drawRate) } }
        if !draws.isEmpty { s += "\n描画: " + draws.joined(separator: "  ") }
        if hostNow() < messageUntil { s += "\n" + message }
        return s
    }

    func printLog() {
        guard let p = transport.primary else { return }
        let pos = p.player.currentTime().seconds
        var line = String(format: "%.3f\t%@\t%@\tpos=%.3f\terr_ms=%+.2f\tavg_ms=%+.2f\trate=%.4f\tjumps=%d\tloops=%d\tclips=%d\tmaxerr_ms=%+.2f",
                          Date().timeIntervalSince1970, opts.name, master != nil ? "M" : "F",
                          pos.isFinite ? pos : 0, p.lastError * 1000, p.errorEMA * 1000, p.player.rate,
                          transport.resyncCount, p.loopCount, transport.nodes.count, transport.maxError * 1000)
        if let st = follower?.stats {
            line += String(format: "\toffset_ms=%+.3f\trtt_ms=%.3f", st.offset * 1000, st.rtt * 1000)
        }
        // Load check: frames shown / skipped over all clips, and the slowest output's draw rate.
        let fs = Array(transport.frames.values)
        let rates = outputs.values.map { $0.picture.renderer.drawRate }
        line += String(format: "\tshown=%d\tdropped=%d\tdraw_fps=%.1f\tformats=%@",
                       fs.reduce(0) { $0 + $1.framesShown }, fs.reduce(0) { $0 + $1.framesDropped }, rates.min() ?? 0,
                       Set(fs.map(\.format)).sorted().joined(separator: ","))
        print(line); fflush(stdout)
    }

    func willTerminate() {
        saveNow()
        transport.stopAll()
    }
}
