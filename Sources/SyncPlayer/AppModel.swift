import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ServiceManagement
import AVFoundation

/// Fast-changing numbers for the control window (kept apart so the whole window is not redrawn 5 times a second).
final class StatusModel: ObservableObject {
    @Published var position = 0.0
    @Published var duration = 0.0
    @Published var playing = false
    @Published var isMaster = false
    /// The "詳しい状態" box: one row each, coloured by level, with what to do when something is wrong.
    @Published var lines: [StatusLine] = []
    /// One line at the top of the control window: what this Mac is doing now, in words.
    @Published var headline = ""
    /// 0 stopped / idle, 1 playing in step, 2 needs a look (waiting, master gone, clock still learning).
    @Published var tone = 0
}

/// One row of the detailed status. level: 0 plain, 1 good, 2 look at it, 3 problem.
struct StatusLine: Equatable, Identifiable {
    var id = 0
    var text: String
    var level = 0
    var fix: String? = nil
}

/// The app: the show, the playback (transport + master/follower), the output windows and the control window.
final class AppModel: ObservableObject {
    var opts: Options
    let transport = Transport()
    let status = StatusModel()

    @Published var show = Show() { didSet { showDidChange(oldValue) } }
    @Published var selectedOutput: String? = nil { didSet { if selectedOutput != oldValue { layerPicks = []; fixSelection(); redrawOverlays() } } }
    @Published var selectedLayer: String? = nil {
        didSet {
            if selectedLayer != oldValue { selectedHandle = 0; redrawOverlays() }
            // Chosen from the preview, L or a menu (not a click in the list): the ⌘/⇧ group and
            // the delete target no longer match what is shown (check 39).
            if !rowClicking && selectedLayer != oldValue { layerPicks = []; deleteTarget = nil; arrowTarget = nil }
        }
    }
    private var rowClicking = false
    /// Several layers picked with ⌘ / ⇧ click (empty = just selectedLayer). Same for clips.
    @Published var layerPicks: Set<String> = []
    @Published var selectedClip: String? = nil
    @Published var clipPicks: Set<String> = []
    @Published var editMode: EditMode = .none { didSet { selectedHandle = 0; redrawOverlays() } }
    @Published var selectedHandle = 0 { didSet { redrawOverlays() } }
    @Published var isMaster = false
    @Published var audioOn = false
    /// The .syncshow opened or saved; changes are written to it as well as to current.syncshow.
    @Published var showFile: String? = nil {
        didSet {
            let prev = UserDefaults.standard.string(forKey: "showFile")
            updateRepresented(); UserDefaults.standard.set(showFile, forKey: "showFile")
            // "The last write failed" belongs to the file it was about: cleared when another file is
            // opened (not when the start goes back to the same file).
            if let f = showFile, f != prev { UserDefaults.standard.set(false, forKey: "showFileBehind") }
        }
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
    /// The preview's zoom (nil = fit), shown and chosen under the preview.
    @Published var previewZoom: Double?
    func setPreviewZoom(_ z: Double?) { previewBox?.setZoom(z) }
    var showHelp = false
    /// Info text on windowed outputs (shown unless I hides it).
    var infoHidden = false
    /// Info text on full-screen outputs (hidden unless I or H shows it, so an exhibition shows only the picture).
    var infoOnFull = false
    private var cursorHidden = false
    /// Keeps the display and the Mac awake while playing or while an output is full screen.
    private var awake: NSObjectProtocol?

    /// "0.3.3 (abc1234)": the release and the commit it was built from.
    static let version: String = {
        let i = Bundle.main.infoDictionary
        let short = i?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = i?["CFBundleVersion"] as? String
        return build.map { "\(short) (\($0))" } ?? short
    }()

    /// The followers the master hears (for the list of all Macs on the master).
    @Published private(set) var peers: [Master.Peer] = []
    private var peersAt = 0.0
    /// Sends from this Mac do not reach the network (no Local Network permission, or no network).
    @Published private(set) var netBlocked = false
    private var probe: UDPSocket?
    private let started = hostNow()
    private var fullBefore: Set<String> = []
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

    /// Every key, in groups: shown in the key list window (Help menu) and, as text, on the outputs with H.
    static var keyGroups: [KeyGroup] { [
        KeyGroup(title: L("再生", "Playback"), keys: [
            KeyItem(key: "space", what: L("再生／停止（マスター）", "Play / stop (master)")),
            KeyItem(key: "R  ↑", what: L("頭へ", "Go to start")),
            KeyItem(key: "↓", what: L("終わりの 3 秒前へ", "3 s before the end")),
            KeyItem(key: "←  →", what: L("1 コマ戻る／進む（止めているとき）", "1 frame back / forward (when stopped)")),
            KeyItem(key: "⇧←  ⇧→", what: L("1 秒戻る／進む", "1 s back / forward")),
            KeyItem(key: "A", what: L("音を出す／消す", "Sound on / off"))]),
        KeyGroup(title: L("窓と表示", "Windows and display"), keys: [
            KeyItem(key: "S", what: L("操作の窓を出す／隠す", "Show / hide the control window")),
            KeyItem(key: "⌘0", what: L("左の欄を隠す／出す", "Hide / show the left column")),
            KeyItem(key: "⌥⌘0", what: L("右の欄を隠す／出す", "Hide / show the right column")),
            KeyItem(key: "⇧⌘Y", what: L("詳しい状態を隠す／出す", "Hide / show the status panel")),
            KeyItem(key: "I", what: L("動作確認の文字", "Info text")),
            KeyItem(key: "N", what: L("Mac 名とディスプレイの番号", "Mac names and display numbers")),
            KeyItem(key: "H  ?", what: L("キー一覧（出力の画面に）", "Key list (on the outputs)")),
            KeyItem(key: "F", what: L("全画面", "Full screen")),
            KeyItem(key: "D", what: L("次のディスプレイへ", "Next display")),
            KeyItem(key: "G", what: L("格子", "Grid")),
            KeyItem(key: "M", what: L("マスター⇔フォロワー", "Master ⇔ follower")),
            KeyItem(key: "Q", what: L("終了", "Quit"))]),
        KeyGroup(title: L("出力とレイヤー", "Outputs and layers"), keys: [
            KeyItem(key: "O", what: L("次の出力", "Next output")),
            KeyItem(key: "L", what: L("次のレイヤー", "Next layer")),
            KeyItem(key: "+  −", what: L("大きさ", "Scale")),
            KeyItem(key: "[  ]", what: L("回転", "Rotate")),
            KeyItem(key: "0", what: L("戻す（編集中はその変形、ほかは位置・大きさ・回転）", "Reset (the warp being edited, else the transform)"))]),
        KeyGroup(title: L("変形の編集", "Editing warps"), keys: [
            KeyItem(key: "E", what: L("四隅の変形", "Corner pin")),
            KeyItem(key: "W", what: L("曲面メッシュ", "Mesh")),
            KeyItem(key: "Tab", what: L("次の点", "Next point")),
            KeyItem(key: "↑ ↓ ← →", what: L("点を 1 px 動かす", "Move the point 1 px")),
            KeyItem(key: "⇧ + ↑ ↓ ← →", what: L("点を 10 px 動かす", "Move the point 10 px"))]),
        KeyGroup(title: L("展示のファイル", "Show file"), keys: [
            KeyItem(key: "⌘O", what: L("展示のファイルを開く", "Open a show")),
            KeyItem(key: "⌘S", what: L("別名で保存", "Save As")),
            KeyItem(key: "⇧⌘E", what: L("素材をまとめる", "Collect Files")),
            KeyItem(key: "⌘Z", what: L("戻す", "Undo")),
            KeyItem(key: "⇧⌘Z", what: L("やり直す", "Redo")),
            KeyItem(key: "↑ ↓", what: L("左の一覧で行を押したあと: 上下の行を選ぶ", "After clicking a row in the left lists: pick the row above / below")),
            KeyItem(key: "delete", what: L("左の一覧で選んだ行を消す・外す（⌘・⇧ クリックで複数）", "Delete the rows picked in the left lists (⌘ / ⇧ click for several)")),
            KeyItem(key: "⌘,", what: L("設定（この Mac の見た目・言語・確かめの窓）", "Settings (this Mac: look, language, confirm windows)"))]),
        KeyGroup(title: L("文字を入れているとき", "While typing"), keys: [
            KeyItem(key: "esc", what: L("入力を終える（space がまた再生に効く）", "Leave the field (space plays again)")),
            KeyItem(key: "return", what: L("決める", "Set"))]),
    ] }

    static var keyHelp: String {
        keyGroups.map { g in
            "[\(g.title)] " + g.keys.map { "\($0.key) \($0.what)" }.joined(separator: "   ")
        }.joined(separator: "\n")
    }

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
        let overridden = !opts.files.isEmpty
        if overridden { detachShowFile(forget: false) }
        if s == nil {
            s = ShowStore.loadCurrent()
            // Keep writing to the show file opened last time, if it still holds the same exhibition.
            // Other Macs may have written their seats to it since (a shared file): read it from the
            // file then (this Mac's seat was written there too, on every change).
            // A file from 0.3.3 or older has no id (a new one each read): the same content counts.
            if !overridden, let cur = s, let f = UserDefaults.standard.string(forKey: "showFile"),
               var fs = ShowStore.read(URL(fileURLWithPath: f)) {
                // (Its one seat also gets a new id each read, and its version is older.)
                var same = fs; same.id = cur.id; same.version = cur.version
                if same.seats.count == 1 && cur.seats.count == 1 { same.seats[0].id = cur.seats[0].id }
                if fs.id == cur.id || same.fileContent == cur.fileContent {
                    if fs.id != cur.id { fs = same }
                    // This Mac's seat from its own copy only when the last write to the file failed
                    // (e.g. the shared folder was away); else the file's (another Mac may have adjusted it).
                    let fileAsIs = fs
                    if UserDefaults.standard.bool(forKey: "showFileBehind"), let mine = ShowStore.rememberedSeat(cur) ?? cur.seats.first?.id,
                       let st = cur.seats.first(where: { $0.id == mine }),
                       let i = fs.seats.firstIndex(where: { $0.id == mine }) { fs.seats[i] = st }
                    // fileShow is what the file holds, so a seat taken from the copy is written there.
                    showFile = f; fileShow = fileAsIs; s = fs
                }
            }
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
            let msg = n > 0 ? L("映像が見つかりません。\(n) 本の映像を選ぶと、今の配置のまま使えます（同じ名前の映像は同じ場所に）", "Clips not found. Choose \(n) clips to keep the current layout (clips with the same name go to the same place)")
                            : L("同期再生する映像を選んでください（複数選べます）", "Choose the clips to play in sync (several allowed)")
            // The very first start: offer the practice movies, so a student can begin without any.
            var practice: Show?
            if n == 0 {
                let a = NSAlert()
                a.messageText = L("SyncPlayer へようこそ", "Welcome to SyncPlayer")
                a.informativeText = L("はじめてなら「練習用の映像で始める」がおすすめです。番号入りの映像 4 本とマスクの見本をこの Mac で作って開きます（数秒）。自分の映像はあとから足せます。", "New here? Try Start with Practice Clips: it makes 4 numbered clips and a sample mask on this Mac and opens them (a few seconds). You can add your own clips later.")
                a.addButton(withTitle: L("練習用の映像で始める", "Start with Practice Clips"))
                a.addButton(withTitle: L("自分の映像を選ぶ…", "Choose My Clips…"))
                if a.runModal() == .alertFirstButtonReturn {
                    practice = Practice.makeShow()
                    if practice == nil { notify(L("練習用の映像を作れませんでした。自分の映像を選んでください", "Couldn't make the practice clips. Please choose your own clips")) }
                }
            }
            let urls = practice != nil ? [] : pickMovies(message: msg, multiple: true)
            if let p = practice {
                detachShowFile(forget: true)
                s = p
            } else
            { guard !urls.isEmpty else {
                print("usage: SyncPlayer [--master|--follower] <movie>... [--show FILE] [--seat NAME] [--audio|--mute] ...")
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
        }
        guard var show0 = s else { exit(1) }
        if opts.preset != nil { print("--preset: presets were removed; a show file holds every seat (--show, --seat)") }
        show0 = chooseSeat(show0, asking: opts.seat == nil && !opts.roleGiven)
        if show0.outputs.isEmpty, let c = show0.clips.first {
            show0.outputs = [OutputConfig(name: L("出力 1", "Output 1"), layers: [Layer(clipID: c.id)])]
        }
        if let sc = opts.screen { show0.outputs[0].screen = sc }
        if opts.fullscreen { show0.outputs[0].fullscreen = true }
        // The exhibition master (kept per Mac, not in the show) opens as master and plays.
        let startMaster = opts.roleGiven ? opts.master : exhibitMaster
        audioOn = opts.audio ?? show0.audioOn ?? startMaster

        buildControlWindow()
        applyTheme()
        show = show0
        selectedOutput = show.outputs.first?.id
        setRole(master: startMaster)
        installKeys()
        undoStack.removeAll(); redoStack.removeAll()
        // Exhibition: the master plays by itself a few seconds after opening (followers catch up).
        if !opts.roleGiven && exhibitMaster && opts.autoplay == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, let m = self.master, !m.schedule.playing else { return }
                m.play()
                self.notify(L("開いたので自動で再生しました", "Opened, so playback started automatically"))
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
            DispatchQueue.main.asyncAfter(deadline: .now() + q) { [weak self] in self?.quitWithoutAsking = true; NSApp.terminate(nil) }
        }
    }

    private func absolute(_ p: String) -> String { URL(fileURLWithPath: p).standardizedFileURL.path }

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(MenuAction.item(L("設定…", "Settings…"), key: ",") { [weak self] in self?.showSettingsWindow() })
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("SyncPlayer を終了", "Quit SyncPlayer"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let fileItem = NSMenuItem()
        main.addItem(fileItem)
        let file = NSMenu(title: L("ファイル", "File"))
        file.addItem(MenuAction.item(L("開く…", "Open…"), key: "o") { [weak self] in self?.openShow() })
        file.addItem(MenuAction.item(L("別名で保存…", "Save As…"), key: "s") { [weak self] in self?.saveShowAs() })
        file.addItem(.separator())
        let col = MenuAction.item(L("素材をまとめる…", "Collect Files…"), key: "e") { [weak self] in self?.showCollectWindow() }
        col.keyEquivalentModifierMask = [.command, .shift]
        file.addItem(col)
        fileItem.submenu = file
        // Text editing (copy / paste in the name fields).
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: L("編集", "Edit"))
        edit.addItem(withTitle: L("取り消す", "Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(.separator())
        edit.addItem(withTitle: L("カット", "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: L("コピー", "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: L("ペースト", "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: L("すべてを選択", "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        // View: hide or show the left and right columns (Akira 2026-11-26), keys like Xcode.
        let viewItem = NSMenuItem()
        main.addItem(viewItem)
        let view = NSMenu(title: L("表示", "View"))
        view.addItem(MenuAction.item(L("左の欄を隠す／出す", "Hide / Show Left Column"), key: "0") { AppModel.toggleUI("ui.hideLeft") })
        let right = MenuAction.item(L("右の欄を隠す／出す", "Hide / Show Right Column"), key: "0") { AppModel.toggleUI("ui.hideRight") }
        right.keyEquivalentModifierMask = [.command, .option]
        view.addItem(right)
        let st = MenuAction.item(L("詳しい状態を隠す／出す", "Hide / Show Status Panel"), key: "y") { AppModel.toggleUI("ui.hideStatus") }
        st.keyEquivalentModifierMask = [.command, .shift]
        view.addItem(st)
        viewItem.submenu = view
        let helpItem = NSMenuItem()
        main.addItem(helpItem)
        let help = NSMenu(title: L("ヘルプ", "Help"))
        let keys = MenuAction.item(L("キー一覧", "Keyboard Shortcuts"), key: "/") { [weak self] in self?.showKeyWindow() }
        help.addItem(keys)
        helpItem.submenu = help
        NSApp.helpMenu = help
        NSApp.mainMenu = main
    }

    /// Flip a per-Mac on/off setting the views read with @AppStorage (the side columns).
    static func toggleUI(_ key: String) {
        let d = UserDefaults.standard
        d.set(!d.bool(forKey: key), forKey: key)
    }

    private var keyWindow: NSWindow?
    /// The key list in its own window (Help menu > キー一覧, ⌘/).
    func showKeyWindow() {
        if keyWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 640),
                             styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.title = L("キー一覧", "Keyboard Shortcuts")
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: KeyListView())
            w.center()
            keyWindow = w
        }
        raisePanel(keyWindow)
        keyWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: show changes

    private func showDidChange(_ old: Show) {
        recordUndo(old)
        if show.seatClips != old.seatClips { transport.setClips(show.seatClips) }
        // A show opened or another seat brings this Mac's sound setting with it.
        var soundChanged = show.seatClips != old.seatClips || show.audioClip != old.audioClip
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
        if let f = showFile, show.fileContent != fileShow?.fileContent {
            backUpOnce(f)
            mergeFromDisk(f)
            let ok = ShowStore.write(show, to: URL(fileURLWithPath: f))
            UserDefaults.standard.set(!ok, forKey: "showFileBehind")
            if ok { fileShow = show }
            else { notify(L("ショーのファイルに書けません: \((f as NSString).lastPathComponent)", "Can't write the show file: \((f as NSString).lastPathComponent)")) }
        }
    }

    /// Several Macs may write one show file (a shared or synced folder). When the file was changed
    /// elsewhere since this Mac read or wrote it, the other seats are taken from it (each Mac
    /// edits its own seat), new seats and clips there are kept, then this Mac's seat is written.
    private func mergeFromDisk(_ f: String) {
        guard let disk = ShowStore.read(URL(fileURLWithPath: f)), let mine = fileShow,
              disk.id == show.id, disk.fileContent != mine.fileContent else { return }
        var m = show
        for d in disk.seats where d.id != show.seatID {
            if let i = m.seats.firstIndex(where: { $0.id == d.id }) {
                // Changed on that Mac (not by this one since): take it.
                if mine.seats.first(where: { $0.id == d.id }) == m.seats[i] { m.seats[i] = d }
            } else if !mine.seats.contains(where: { $0.id == d.id }) {
                m.seats.append(d)          // a seat added elsewhere
            }
        }
        // A seat deleted elsewhere (and not changed here since): delete it here too. Never this Mac's seat.
        m.seats.removeAll { st in
            st.id != show.seatID && !disk.seats.contains(where: { $0.id == st.id })
                && mine.seats.contains(where: { $0.id == st.id }) && mine.seats.first(where: { $0.id == st.id }) == st
        }
        for c in disk.clips where !m.clips.contains(where: { $0.id == c.id }) && !mine.clips.contains(where: { $0.id == c.id }) {
            m.clips.append(c)              // a clip added elsewhere
        }
        // A clip removed elsewhere (unchanged here, and not on this Mac's seat): remove it here too.
        let usedHere = Set(m.seats.flatMap { $0.outputs.flatMap { $0.layers.map(\.clipID) } } + m.seats.compactMap(\.audioClip))
        m.clips.removeAll { c in
            !disk.clips.contains(where: { $0.id == c.id }) && mine.clips.contains(c) && !usedHere.contains(c.id)
        }
        // Loop settings: the file's, unless this Mac changed them since.
        if m.loopTogether == mine.loopTogether { m.loopTogether = disk.loopTogether }
        if m.loopLength == mine.loopLength { m.loopLength = disk.loopLength }
        guard m != show else { return }
        undoing = true; show = m; undoing = false
        // Undo would bring the other seats back to before this (and write that): start undo again here.
        undoStack.removeAll(); redoStack.removeAll()
        notify(L("ほかの Mac の変更（ほかの席）を取り込みました", "Took in changes made on another Mac (other seats)"))
    }

    // MARK: seats

    /// Sets this Mac's seat in s: --seat, else the one remembered for this exhibition, else (when
    /// asking and there are several) the seat chooser, else the first.
    func chooseSeat(_ s: Show, asking: Bool) -> Show {
        var s = s
        if let n = opts.seat, let st = s.seats.first(where: { $0.name == n || $0.id == n }) { s.seatID = st.id }
        else if let r = ShowStore.rememberedSeat(s), s.seats.contains(where: { $0.id == r }) { s.seatID = r }
        else if s.seats.count > 1 && asking, let id = runSeatChooser(s) { s.seatID = id; ShowStore.rememberSeat(id, for: s) }
        else { s.seatID = s.seats.first?.id ?? "" }   // not remembered: asked again next time
        if opts.seat != nil, s.seats.count > 1 { ShowStore.rememberSeat(s.seatID, for: s) }
        return s
    }

    /// The seat chooser in its own window, waiting for the answer. nil = cancelled (keeps the first).
    private func runSeatChooser(_ s: Show) -> String? {
        NSApp.activate(ignoringOtherApps: true)
        var picked: String?
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 360),
                         styleMask: [.titled], backing: .buffered, defer: false)
        w.title = showFile.map { ($0 as NSString).lastPathComponent } ?? "SyncPlayer"
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: SeatChooserView(show: s, current: ShowStore.rememberedSeat(s)) { id in
            picked = id
            NSApp.stopModal()
        })
        w.center()
        panelOpen = true
        NSApp.runModal(for: w)
        panelOpen = false
        w.orderOut(nil)
        return picked
    }

    /// Another Mac (or this master) is the same seat.
    func seatClash(_ name: String?) -> Bool {
        guard let n = name, show.seats.count > 1 else { return false }
        return peers.filter { $0.seat == n }.count + (show.seat.name == n ? 1 : 0) > 1
    }

    /// Makes this Mac another seat: its outputs, layers and sound change to that seat's.
    func switchSeat(_ id: String, ask: Bool = true) {
        guard id != show.seatID, let st = show.seats.first(where: { $0.id == id }) else { return }
        if ask && !confirm(L("この Mac を席「\(st.name)」にしますか？", "Make this Mac seat “\(st.name)”?"),
                           L("出力・レイヤー・音がその席のものに変わります。いまの席「\(show.seat.name)」の設定はファイルに残ります。",
                             "Outputs, layers and sound change to that seat's. The current seat “\(show.seat.name)” stays in the file as it is.")) { return }
        saveNow()
        var s = show
        s.seatID = id
        ShowStore.rememberSeat(id, for: s)
        applyShow(s)
        selectedOutput = show.outputs.first?.id
        notify(L("この Mac は席「\(st.name)」", "This Mac is now seat “\(st.name)”"))
    }

    func addSeat() {
        var s = show
        let n = s.newSeatName()
        s.seats.append(Seat(name: n, outputs: [OutputConfig(name: L("出力 1", "Output 1"))]))
        show = s
        notify(L("席「\(n)」を足しました。その席の Mac で開き、席に選んでください", "Added seat “\(n)”. Open the show on that seat's Mac and choose it there"))
    }

    /// A copy of a seat (its outputs and layers), as a start for a similar place.
    func duplicateSeat(_ id: String) {
        guard let st = show.seats.first(where: { $0.id == id }) else { return }
        var s = show
        var c = st
        c.id = UUID().uuidString
        c.name = s.newSeatName()
        for o in c.outputs.indices {
            c.outputs[o].id = UUID().uuidString
            for l in c.outputs[o].layers.indices { c.outputs[o].layers[l].id = UUID().uuidString }
        }
        s.seats.append(c)
        show = s
        notify(L("席「\(st.name)」を「\(c.name)」に複製", "Duplicated seat “\(st.name)” as “\(c.name)”"))
    }

    func renameSeat(_ id: String, _ name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, let i = show.seats.firstIndex(where: { $0.id == id }), show.seats[i].name != n else { return }
        if show.seats.contains(where: { $0.name == n && $0.id != id }) { notify(L("席「\(n)」はもうあります", "There is already a seat “\(n)”")); return }
        show.seats[i].name = n
    }

    func deleteSeat(_ id: String) {
        guard show.seats.count > 1, let st = show.seats.first(where: { $0.id == id }) else { return }
        guard confirm(L("席「\(st.name)」を消しますか？", "Delete seat “\(st.name)”?"),
                      L("その席の出力とレイヤーがファイルから消えます（⌘Z で戻せます）。映像は消えません。",
                        "Its outputs and layers are removed from the file (⌘Z brings them back). Clips are kept."), skip: .seat) else { return }
        var s = show
        s.seats.removeAll { $0.id == id }
        if id == show.seatID { s.seatID = s.seats[0].id; ShowStore.rememberSeat(s.seatID, for: s) }
        show = s
        notify(L("席「\(st.name)」を消しました", "Deleted seat “\(st.name)”"))
    }

    // MARK: collect files

    private var collectWindow: NSWindow?
    @Published var collecting = false

    /// File > 素材をまとめる (⇧⌘E): the window listing every file, then the copy.
    func showCollectWindow() {
        saveNow()
        if collectWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
                             styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.title = L("素材をまとめる", "Collect Files")
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: CollectView(model: self))
            w.center()
            collectWindow = w
        }
        raisePanel(collectWindow)
        collectWindow?.makeKeyAndOrderFront(nil)
    }

    func closeCollectWindow() { collectWindow?.orderOut(nil) }

    /// SyncPlayer ▸ Settings… (⌘,): this Mac's own preferences (look, language, confirm windows).
    func showSettingsWindow() {
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 300),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView(model: self))
            w.center()
            settingsWindow = w
        }
        settingsWindow?.title = L("設定（この Mac）", "Settings (this Mac)")
        raisePanel(settingsWindow)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
    private var settingsWindow: NSWindow?

    /// Point a missing movie or mask at its file (in every seat that uses it).
    func relink(_ item: Collect.Item) {
        let urls = pickMovies(message: L("「\(item.name)」を探す", "Locate “\(item.name)”"), multiple: false,
                              images: item.kind == "mask")
        guard let u = urls.first else { return }
        var s = show
        if item.kind == "movie" {
            for i in s.clips.indices where s.clips[i].path == item.path { s.clips[i].path = u.path }
        } else {
            for k in s.seats.indices { for o in s.seats[k].outputs.indices { for l in s.seats[k].outputs[o].layers.indices
                where s.seats[k].outputs[o].layers[l].mask == item.path { s.seats[k].outputs[o].layers[l].mask = u.path } } }
        }
        show = s
    }

    /// Asks where, then copies in the background. seatOnly: only this Mac's seat.
    func collect(zip: Bool, seatOnly: Bool, reveal: Bool) {
        saveNow()
        let p = NSSavePanel()
        let base = showFile.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension } ?? "show"
        p.nameFieldStringValue = seatOnly ? "\(base)-\(show.seat.name)" : base
        p.message = zip ? L("zip の名前と置き場所", "Name and place of the zip")
                        : L("新しいフォルダの名前と置き場所（中に .syncshow・movies・masks を作ります）", "Name and place of a new folder (the .syncshow, movies and masks go inside)")
        if zip { p.allowedContentTypes = [.zip] }
        guard runPanel(p) == .OK, let u = p.url else { return }
        let s = Collect.scoped(show, seat: seatOnly ? show.seatID : nil)
        collecting = true
        notify(L("素材をまとめています…", "Collecting files…"))
        DispatchQueue.global(qos: .userInitiated).async {
            let r = Result { try Collect.run(s, to: u, zip: zip) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.collecting = false
                switch r {
                case .success(let res):
                    let miss = res.missing.isEmpty ? "" : L("（見つからない \(res.missing.count) 件は report.txt に）", " (\(res.missing.count) not found: see report.txt)")
                    self.notify(L("まとめました: \(res.folder.lastPathComponent)、\(res.copied) 件", "Collected: \(res.folder.lastPathComponent), \(res.copied) files") + miss)
                    self.closeCollectWindow()
                    if reveal { NSWorkspace.shared.activateFileViewerSelecting([res.folder]) }
                case .failure(let e):
                    self.notify(L("まとめられませんでした: ", "Couldn't collect: ") + e.localizedDescription)
                    let a = NSAlert(); a.messageText = L("素材をまとめられませんでした", "Couldn't collect the files")
                    a.informativeText = e.localizedDescription; a.runModal()
                }
            }
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
        // The mesh may have fewer points now (size changed, show or seat changed).
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
        learned("adjusted")
    }

    // MARK: undo (⌘Z / ⇧⌘Z)

    private var undoStack: [Show] = []
    private var redoStack: [Show] = []
    private var undoing = false
    private var lastUndoAt = 0.0

    /// While a number is dragged (Scrub), all its changes are one step however slowly it moves.
    static var undoHold = false
    static var undoHoldUsed = false

    /// Changes in quick succession (a slider dragged, keys held) are one step.
    private func recordUndo(_ old: Show) {
        guard !undoing else { return }
        let now = hostNow()
        // A hold left on (a drag whose end never came) runs out after 10 s still (check 46 L2).
        if AppModel.undoHold && AppModel.undoHoldUsed && now - lastUndoAt > 10 { AppModel.undoHold = false }
        let sameStep = AppModel.undoHold ? AppModel.undoHoldUsed : now - lastUndoAt <= 0.7
        if undoStack.isEmpty || !sameStep {
            undoStack.append(old)
            if undoStack.count > 100 { undoStack.removeFirst() }
        }
        if AppModel.undoHold { AppModel.undoHoldUsed = true }
        lastUndoAt = now
        redoStack.removeAll()
    }

    func undoShow() {
        guard let prev = undoStack.popLast() else { notify(L("これより前には戻せません", "Nothing more to undo")); return }
        redoStack.append(show)
        undoing = true; show = prev; undoing = false
        if show.seats.count > 1 { ShowStore.rememberSeat(show.seatID, for: show) }
        fixSelection()
        lastUndoAt = 0
        notify(L("1 つ前に戻しました（⇧⌘Z でやり直す）", "Undone (⇧⌘Z to redo)"))
    }

    func redoShow() {
        guard let next = redoStack.popLast() else { notify(L("やり直すものがありません", "Nothing to redo")); return }
        undoStack.append(show)
        undoing = true; show = next; undoing = false
        if show.seats.count > 1 { ShowStore.rememberSeat(show.seatID, for: show) }
        fixSelection()
        lastUndoAt = 0
        notify(L("やり直しました", "Redone"))
    }

    // MARK: learning (the steps checklist)

    /// Things a student has done once on this Mac (kept in UserDefaults "learned", a list of names).
    @Published private(set) var learnedSet: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "learned") ?? [])
    func learned(_ name: String) {
        guard !learnedSet.contains(name) else { return }
        learnedSet.insert(name)
        UserDefaults.standard.set(Array(learnedSet), forKey: "learned")
    }
    func forgetLearned() {
        learnedSet = []
        UserDefaults.standard.removeObject(forKey: "learned")
    }

    /// The practice show is open (its movies are the practice movies).
    var isPractice: Bool { show.clips.contains { $0.path.hasPrefix(Practice.dir.path) } }

    func openPractice() {
        // A show not saved to a file would be lost (and ⌘Z cannot bring it back).
        if showFile == nil && !show.clips.isEmpty && !isPractice,
           !confirm(L("いまのショーはまだ保存していません。練習用のショーに替えますか？", "This show isn't saved. Replace it with the practice show?"),
                    L("替えると、いまのショー（映像の並びや調整）は戻せません。残すときは「やめる」を押し、上の「保存…」で保存してから開く。", "The current show (clips and adjustments) can't be brought back. To keep it, press Cancel and save it first."),
                    ok: L("替える", "Replace")) { return }
        notify(L("練習用の映像を用意しています…", "Preparing practice clips…"))
        guard let s = Practice.makeShow() else { notify(L("練習用の映像を作れませんでした", "Couldn't make the practice clips")); return }
        saveNow()
        if showFile != nil { detachShowFile(forget: false) }
        applyShow(s)
        notify(L("練習用のショーを開きました（4 本の映像、4 本目に丸いマスク）", "Opened the practice show (4 clips, a round mask on the 4th)"))
    }

    /// The manual's page for a part of the window (the "?" buttons).
    static let manualBase = "https://lecture.nakayasu.com/sync-player/"
    static func openManual(_ anchor: String) {
        if let u = URL(string: AppModel.manualBase + "#" + anchor) { NSWorkspace.shared.open(u) }
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
        "SyncPlayer — \(o.name) — " + (isMaster ? L("マスター", "Master") : L("フォロワー", "Follower")) + " — \(opts.name)"
    }

    /// One full-screen output per display (Akira 2026-11-26: people do things they did not mean to).
    /// When two are full screen on the same display, the one just made full screen or just moved
    /// there stays, and the other goes back to a window, with a message. ⌘Z undoes it.
    private func resolveFullClash() -> Bool {
        let screens = NSScreen.screens
        // Only outputs whose display is connected now: one set to a display that is not there yet
        // (a projector still waking) must keep its full screen for when it comes (check 51 H1).
        func screenOf(_ o: OutputConfig) -> Int? { screens.indices.contains(o.screen) ? o.screen : nil }
        var groups: [Int: [Int]] = [:]
        for (i, o) in show.outputs.enumerated() where o.fullscreen {
            if let k = screenOf(o) { groups[k, default: []].append(i) }
        }
        var s = show
        var any = false
        for idx in groups.values where idx.count > 1 {
            var dropped: [String] = []
            let fresh = idx.last { i in
                let o = show.outputs[i]
                guard let w = outputs[o.id] else { return true }
                return !w.isFull || w.screenIndex != o.screen
            }
            let keep = fresh ?? idx[0]
            for i in idx where i != keep { s.outputs[i].fullscreen = false; dropped.append(s.outputs[i].name); any = true }
            notify(L("1 つのディスプレイに全画面の出力は 1 つだけ。「\(show.outputs[keep].name)」を全画面にし、「\(dropped.joined(separator: "」「"))」は窓に戻しました（⌘Z で戻せる）",
                     "One full-screen output per display. \(show.outputs[keep].name) is full screen; \(dropped.joined(separator: ", ")) went back to a window (⌘Z undoes)"))
        }
        if !any { return false }
        show = s
        return true
    }

    private func syncOutputs() {
        // Two full screens on one display: one goes back to a window first, then the windows are placed.
        // (If the change runs this again, the second run finds nothing to do.)
        _ = resolveFullClash()
        let ids = Set(show.outputs.map(\.id))
        for (id, w) in outputs where !ids.contains(id) { w.close(); outputs[id] = nil }
        var created = false
        var moved = false
        for (i, o) in show.outputs.enumerated() {
            if outputs[o.id] == nil {
                guard let w = OutputWindow(id: o.id) else { print("Metal is not available"); exit(1) }
                configure(w)
                outputs[o.id] = w
                w.window.representedURL = showFile.map { URL(fileURLWithPath: $0) } ?? ShowStore.currentURL
                w.apply(o, index: i, title: outputTitle(o))
                w.window.orderFront(nil)
                created = true
            } else if outputs[o.id]?.apply(o, index: i, title: outputTitle(o)) == true {
                moved = true
            }
        }
        // A display or full screen changed from the control window (Akira 2026-11-26: the output
        // seemed to vanish and Chrome behind came forward). Levels for the new screen at once, and
        // SyncPlayer keeps the front with the control window as the key window where it can be seen.
        if moved && !created {
            refreshLevels()
            NSApp.activate(ignoringOtherApps: true)
            if let c = control, c.isVisible,
               !outputs.values.contains(where: { $0.isFull && $0.window.frame.intersects(c.frame) }) || controlRaised {
                c.makeKeyAndOrderFront(nil)
            } else if let w = show.outputs.compactMap({ outputs[$0.id] }).first(where: { $0.isFull }) {
                w.window.makeKeyAndOrderFront(nil)
            }
        }
        // A new windowed output must not hide the control window (full-screen outputs stay above it anyway).
        // The control window also stays the key window, so activating the app does not bring the
        // output above it and the first S hides it.
        // With a full-screen output on the control window's screen, or with the control window hidden
        // (S), an output takes the keys as before, so S, space and Q keep working.
        if created {
            if let c = control, c.isVisible,
               !outputs.values.contains(where: { $0.isFull && $0.window.frame.intersects(c.frame) }) {
                c.makeKeyAndOrderFront(nil)
                c.makeFirstResponder(nil)      // not into a text field, so the keys are not typed there
            } else if let w = show.outputs.compactMap({ outputs[$0.id] }).first(where: { $0.isFull })
                        ?? show.outputs.first.flatMap({ outputs[$0.id] }) {
                w.window.makeKeyAndOrderFront(nil)
            }
        }
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
        w.onMovedToScreen = { [weak self] i in
            guard let self, let k = self.show.outputs.firstIndex(where: { $0.id == id }), self.show.outputs[k].screen != i else { return }
            self.show.outputs[k].screen = i
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
        notify(L("ディスプレイのつながりが変わりました（\(NSScreen.screens.count) 枚）", "Displays changed (\(NSScreen.screens.count) connected)"))
    }

    func refreshScreens() {
        screenNames = NSScreen.screens.enumerated().map { i, s in
            "\(i + 1): \(s.localizedName)  \(Int(s.frame.width))×\(Int(s.frame.height))"
        }
        screenShort = NSScreen.screens.enumerated().map { i, s in
            L("ディスプレイ \(i + 1)（\(Int(s.frame.width))×\(Int(s.frame.height))）", "Display \(i + 1) (\(Int(s.frame.width))×\(Int(s.frame.height)))")
        }
    }

    func redrawOverlays() {
        for w in outputs.values { w.picture.overlay.needsDisplay = true }
        preview?.overlay.needsDisplay = true
    }

    func addOutput() {
        let used = Set(show.outputs.map(\.screen))
        let screen = (0..<NSScreen.screens.count).first { !used.contains($0) } ?? 0
        var o = OutputConfig(name: L("出力 \(show.outputs.count + 1)", "Output \(show.outputs.count + 1)"), screen: screen)
        if let c = show.clips.first { o.layers = [Layer(clipID: c.id)] }
        show.outputs.append(o)
        selectedOutput = o.id
        notify(L("出力「\(o.name)」を足しました（ディスプレイ \(screen + 1)）", "Added output “\(o.name)” (display \(screen + 1))"))
    }

    func removeOutput() {
        guard show.outputs.count > 1, let o = selectedOutputIndex else { notify(L("出力は 1 つ以上要ります", "At least one output is needed")); return }
        let name = show.outputs[o].name, oid = show.outputs[o].id
        guard confirm(L("出力「\(name)」を消しますか？", "Delete output “\(name)”?"), L("この出力のレイヤーと、その調整（四隅・メッシュなど）も消えます（⌘Z で戻せます）。", "Its layers and their adjustments (corners, mesh…) are deleted too (⌘Z brings them back)."), skip: .output),
              show.outputs.count > 1, let o2 = show.outputs.firstIndex(where: { $0.id == oid }) else { return }
        show.outputs.remove(at: o2)
        notify(L("出力「\(name)」を消しました", "Deleted output “\(name)”"))
    }

    func selectNextOutput() {
        guard !show.outputs.isEmpty else { return }
        let i = ((selectedOutputIndex ?? -1) + 1) % show.outputs.count
        selectedOutput = show.outputs[i].id
        notify(L("出力: \(show.outputs[i].name)", "Output: \(show.outputs[i].name)"))
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
        notify(L("\(show.outputs[o].name) をディスプレイ \(show.outputs[o].screen + 1) へ", "\(show.outputs[o].name) to display \(show.outputs[o].screen + 1)"))
    }

    // MARK: layers

    func addLayer() {
        guard let o = selectedOutputIndex, let c = show.clips.first else { return }
        let l = Layer(clipID: c.id)
        show.outputs[o].layers.append(l)
        selectedLayer = l.id
    }

    /// Deletes the picked layers (or the selected one), asking first.
    func removeLayer() {
        guard let o = selectedOutputIndex else { return }
        let oid = show.outputs[o].id
        let ids = layerPicks.isEmpty ? Set([selectedLayer].compactMap { $0 }) : layerPicks
        let gone = show.outputs[o].layers.filter { ids.contains($0.id) }
        guard !gone.isEmpty else { return }
        let title = gone.count == 1
            ? L("レイヤー「\(gone[0].name ?? clipName(gone[0].clipID))」を消しますか？", "Delete layer “\(gone[0].name ?? clipName(gone[0].clipID))”?")
            : L("レイヤー \(gone.count) つを消しますか？", "Delete \(gone.count) layers?")
        guard confirm(title, L("調整（位置・四隅・メッシュ・マスクなど）も消えます（⌘Z で戻せます）。映像のファイルは消えません。", "Their adjustments (transform, corners, mesh, mask…) go too (⌘Z brings them back). Movie files are kept."), skip: .layer),
              let o2 = show.outputs.firstIndex(where: { $0.id == oid }) else { return }
        show.outputs[o2].layers.removeAll { ids.contains($0.id) }
        layerPicks = []
    }

    /// A copy of the selected layer just in front of it (like ⌘D in After Effects).
    func duplicateLayer() {
        guard let i = selectedLayerIndex else { return }
        var l = show.outputs[i.o].layers[i.l]
        l.id = UUID().uuidString
        show.outputs[i.o].layers.insert(l, at: i.l + 1)
        selectedLayer = l.id
        layerPicks = []
    }

    /// A click on a list row, like Finder: a plain click picks one row, ⌘ adds or takes away a
    /// row, ⇧ picks the rows between the last clicked and this one. `order` is the list's order.
    /// One click reaches here from the row and from its name; the second call is ignored.
    func clickLayerRow(_ id: String, order: [String]) {
        guard let r = Self.click(id, focus: selectedLayer, picks: layerPicks, order: order, last: &lastRowClick) else { return }
        rowClicking = true; defer { rowClicking = false }
        selectedLayer = r.focus; layerPicks = r.picks
    }
    func clickClipRow(_ id: String) {
        guard let r = Self.click(id, focus: selectedClip, picks: clipPicks, order: show.clips.map(\.id), last: &lastRowClick) else { return }
        selectedClip = r.focus; clipPicks = r.picks
    }
    private static func click(_ id: String, focus: String?, picks: Set<String>, order: [String],
                              last: inout TimeInterval) -> (focus: String?, picks: Set<String>)? {
        let stamp = NSApp.currentEvent?.timestamp ?? -1
        if stamp >= 0 && stamp == last { return nil }
        last = stamp
        let m = NSEvent.modifierFlags
        if m.contains(.command) {
            var p = picks.isEmpty ? Set([focus].compactMap { $0 }) : picks
            if p.contains(id) { p.remove(id) } else { p.insert(id) }
            var f = focus
            if p.contains(id) { f = id } else if f == nil || !p.contains(f!) { f = order.first { p.contains($0) } ?? id }
            return (f, p.count > 1 ? p : [])
        }
        if m.contains(.shift), let f = focus, let a = order.firstIndex(of: f), let b = order.firstIndex(of: id) {
            let r = Set(order[min(a, b)...max(a, b)])
            return (f, r.count > 1 ? r : [])
        }
        return (id, [])
    }
    private var lastRowClick: TimeInterval = -2

    /// Move the selected layer toward the front (+1) or back (-1).
    func moveLayer(_ d: Int) {
        guard let i = selectedLayerIndex else { return }
        let j = i.l + d
        guard show.outputs[i.o].layers.indices.contains(j) else { return }
        show.outputs[i.o].layers.swapAt(i.l, j)
    }

    /// Drag in the layer list. The list shows the layers front first (reversed), so the offsets
    /// are in that order.
    func moveLayers(fromDisplayed src: IndexSet, toDisplayed dst: Int) {
        guard let o = selectedOutputConfig.flatMap({ c in show.outputs.firstIndex { $0.id == c.id } }) else { return }
        var shown = Array(show.outputs[o].layers.reversed())
        shown.move(fromOffsets: src, toOffset: dst)
        let layers = Array(shown.reversed())
        if layers.map(\.id) != show.outputs[o].layers.map(\.id) { show.outputs[o].layers = layers }
    }

    func selectNextLayer() {
        guard let o = selectedOutputConfig, !o.layers.isEmpty else { return }
        let ids = o.layers.reversed().map(\.id)   // the order the list shows
        let k = ids.firstIndex(where: { $0 == selectedLayer }) ?? -1
        selectedLayer = ids[(k + 1) % ids.count]
        if let c = selectedLayerIndex.flatMap({ show.clip(show.outputs[$0.o].layers[$0.l].clipID) }) { notify(L("レイヤー: \(c.name)", "Layer: \(c.name)")) }
    }

    func arrangeGrid() {
        guard let o = selectedOutputIndex else { return }
        show.arrangeGrid(output: o)
        notify(L("レイヤーを格子に並べました", "Layers tiled in a grid"))
    }

    // MARK: clips

    private func pickMovies(message: String, multiple: Bool, images: Bool = false) -> [URL] {
        let p = NSOpenPanel()
        p.message = message
        p.allowedContentTypes = images ? [.image] : [.movie, .video, .quickTimeMovie, .mpeg4Movie]
        p.allowsMultipleSelection = multiple
        return runPanel(p) == .OK ? p.urls : []
    }

    /// Add movies; each also gets a layer on the selected output.
    func addClips() {
        let urls = pickMovies(message: L("足す映像を選んでください（複数選べます）", "Choose clips to add (several allowed)"), multiple: true)
        guard !urls.isEmpty else { return }
        var s = show
        for u in urls {
            let c = Clip(id: s.newClipID(), path: u.path)
            s.clips.append(c)
            if let o = selectedOutputIndex { s.outputs[o].layers.append(Layer(clipID: c.id)) }
        }
        show = s
        learned("added")
        notify(L("映像を \(urls.count) つ足しました", "Added \(urls.count) clip(s)"))
    }

    /// Show a different movie on one layer (from the layer list's movie chooser or a drop).
    func setLayerClip(_ layerID: String, _ clipID: String) {
        guard show.clip(clipID) != nil else { return }
        for o in show.outputs.indices {
            if let l = show.outputs[o].layers.firstIndex(where: { $0.id == layerID }), show.outputs[o].layers[l].clipID != clipID {
                show.outputs[o].layers[l].clipID = clipID
                notify(L("レイヤーの映像: \(clipName(clipID))", "Layer clip: \(clipName(clipID))"))
            }
        }
    }

    /// Add movies from files and show the first one on a layer.
    func addClipsForLayer(_ layerID: String) {
        let urls = pickMovies(message: L("このレイヤーに出す映像を選んでください", "Choose the clip for this layer"), multiple: false)
        guard let u = urls.first else { return }
        let c = Clip(id: show.newClipID(), path: u.path)
        var s = show
        s.clips.append(c)
        for o in s.outputs.indices {
            if let l = s.outputs[o].layers.firstIndex(where: { $0.id == layerID }) { s.outputs[o].layers[l].clipID = c.id }
        }
        show = s
        learned("added")
        notify(L("映像: \(u.lastPathComponent)", "Clip: \(u.lastPathComponent)"))
    }

    func replaceClip(_ id: String) {
        guard let i = show.clips.firstIndex(where: { $0.id == id }),
              let u = pickMovies(message: L("「\(show.clips[i].name)」と入れ替える映像", "Movie to replace “\(show.clips[i].name)”"), multiple: false).first else { return }
        show.clips[i].path = u.path
        learned("added")
        notify(L("映像: \(u.lastPathComponent)", "Clip: \(u.lastPathComponent)"))
    }

    func removeClip(_ id: String) { removeClips([id]) }

    /// Removes the picked clips (or the selected one) from the show.
    func removeSelectedClips() {
        removeClips(clipPicks.isEmpty ? Set([selectedClip].compactMap { $0 }) : clipPicks)
    }

    func removeClips(_ given: Set<String>) {
        let ids = given.filter { id in show.clips.contains { $0.id == id } }
        guard !ids.isEmpty else { return }
        guard show.clips.count > ids.count else { notify(L("映像は 1 つ以上要ります", "At least one clip is needed")); return }
        let users = show.seats.flatMap(\.outputs).reduce(0) { $0 + $1.layers.filter { ids.contains($0.clipID) }.count }
        // Where they are used: seat, output and layer number (1 = front), so it is clear what goes.
        var places: [String] = []
        for st in show.seats {
            for o in st.outputs {
                for (k, l) in o.layers.reversed().enumerated() where ids.contains(l.clipID) {
                    let seat = show.seats.count > 1 ? L("席 \(st.name)・", "Seat \(st.name) · ") : ""
                    let name = l.name.map { "（\($0)）" } ?? ""
                    places.append("・" + seat + "\(o.name)・" + L("レイヤー \(k + 1)", "Layer \(k + 1)") + name + (ids.count > 1 ? " — " + clipName(l.clipID) : ""))
                }
            }
        }
        let shown = places.prefix(12).joined(separator: "\n") + (places.count > 12 ? L("\n…ほか \(places.count - 12) つ", "\n…and \(places.count - 12) more") : "")
        let title = ids.count == 1
            ? L("映像「\(clipName(ids.first!))」をショーから外しますか？", "Remove clip “\(clipName(ids.first!))” from the show?")
            : L("映像 \(ids.count) 本をショーから外しますか？", "Remove \(ids.count) clips from the show?")
        guard confirm(title,
                      users > 0 ? L("使っているレイヤー \(users) つも、その調整（位置・四隅・メッシュ・マスクなど）ごと消えます（⌘Z で戻せます）。映像のファイルは消えません。\n\n使っている所:\n\(shown)", "\(users) layer(s) using them go too, with their adjustments (⌘Z brings them back). Movie files are kept.\n\nUsed in:\n\(shown)")
                                : L("どのレイヤーでも使っていません。映像のファイルは消えません。", "Not used by any layer. Movie files are kept."), ok: L("外す", "Remove"), skip: .clip) else { return }
        var s = show
        s.clips.removeAll { ids.contains($0.id) }
        // Every seat: its layers that show the clips go too.
        for k in s.seats.indices {
            for o in s.seats[k].outputs.indices { s.seats[k].outputs[o].layers.removeAll { ids.contains($0.clipID) } }
            if let a = s.seats[k].audioClip, ids.contains(a) { s.seats[k].audioClip = nil }
        }
        show = s
        clipPicks = []
        if let c = selectedClip, ids.contains(c) { selectedClip = nil }
    }

    /// What the footage library shows for the selected clip (like the top of After Effects' Project
    /// panel): size, frame rate, length, codec, sound, file size. Read once per file, in the background.
    struct ClipInfo: Equatable {
        var width = 0, height = 0
        var fps = 0.0, seconds = 0.0
        var codec = "", audio = false, bytes: Int64 = 0
        var line: String {
            if width == 0 && seconds == 0 { return L("読めない（形式かファイルを確かめる）", "Can't read (check the format or file)") }
            var p: [String] = []
            if width > 0 { p.append("\(width)×\(height)") }
            // 29.97 and 23.976 as they are (not rounded to 30 / 24, check 43).
            if fps > 0 {
                var f = String(format: "%.3f", fps)
                while f.hasSuffix("0") { f.removeLast() }
                if f.hasSuffix(".") { f.removeLast() }
                p.append(f + " fps")
            }
            if seconds > 0 { p.append(timeString(seconds)) }
            if !codec.isEmpty { p.append(codec) }
            p.append(audio ? L("音あり", "audio") : L("音なし", "no audio"))
            if bytes > 0 { p.append(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) }
            return p.joined(separator: " · ")
        }
    }
    @Published private(set) var clipInfos: [String: ClipInfo] = [:]
    private var clipInfoLoading = Set<String>()

    func clipInfo(_ id: String) -> ClipInfo? {
        guard let c = show.clip(id) else { return nil }
        if let i = clipInfos[c.path] { return i }
        let path = c.path
        if clipInfoLoading.insert(path).inserted {
            Task { @MainActor in
                var i = ClipInfo()
                let asset = AVURLAsset(url: URL(fileURLWithPath: path))
                if let v = try? await asset.loadTracks(withMediaType: .video).first {
                    if let sz = try? await v.load(.naturalSize) { i.width = Int(sz.width); i.height = Int(sz.height) }
                    i.fps = Double((try? await v.load(.nominalFrameRate)) ?? 0)
                    if let f = (try? await v.load(.formatDescriptions))?.first {
                        i.codec = Self.codecName(CMFormatDescriptionGetMediaSubType(f))
                    }
                }
                i.audio = !((try? await asset.loadTracks(withMediaType: .audio)) ?? []).isEmpty
                i.seconds = (try? await asset.load(.duration))?.seconds ?? 0
                i.bytes = ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value ?? 0
                self.clipInfos[path] = i
                self.clipInfoLoading.remove(path)
            }
        }
        return nil
    }

    private static func codecName(_ t: FourCharCode) -> String {
        switch t {
        case kCMVideoCodecType_H264: return "H.264"
        case kCMVideoCodecType_HEVC: return "HEVC"
        case kCMVideoCodecType_AppleProRes422, kCMVideoCodecType_AppleProRes422HQ, kCMVideoCodecType_AppleProRes422LT,
             kCMVideoCodecType_AppleProRes422Proxy: return "ProRes 422"
        case kCMVideoCodecType_AppleProRes4444, kCMVideoCodecType_AppleProRes4444XQ: return "ProRes 4444"
        default:
            let c = [24, 16, 8, 0].map { Character(UnicodeScalar(UInt8((t >> $0) & 0xFF))) }
            return String(c).trimmingCharacters(in: .whitespaces)
        }
    }

    /// Shows the clip's movie file in the Finder.
    func revealClip(_ id: String) {
        guard let c = show.clip(id) else { return }
        let u = URL(fileURLWithPath: c.path)
        if FileManager.default.fileExists(atPath: u.path) { NSWorkspace.shared.activateFileViewerSelecting([u]) }
        else { notify(L("映像のファイルが見つかりません: \(c.path)", "Movie file not found: \(c.path)")) }
    }

    /// The movie cannot be opened (missing file or failed to load).
    func clipBroken(_ id: String) -> Bool {
        guard let n = transport.orderedNodes.first(where: { $0.id == id })?.node else { return false }
        return n.items.contains(where: { $0.status == .failed }) || missingFiles().contains(n.url.path)
    }

    func clipName(_ id: String) -> String { show.clip(id)?.name ?? L("（なし）", "(none)") }

    // MARK: show files

    func openShow() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [ShowStore.fileType, .json]
        p.message = L("ショーのファイル（.syncshow）を開く", "Open a show file (.syncshow)")
        guard runPanel(p) == .OK, let u = p.url else { return }
        openShow(at: u)
    }

    func openShow(at u: URL) {
        guard let s = ShowStore.read(u) else { notify(L("開けませんでした: \(u.lastPathComponent)", "Couldn't open: \(u.lastPathComponent)")); return }
        saveNow()   // finish writing the previous file first
        showFile = u.path
        fileShow = s
        applyShow(chooseSeat(s, asking: true))
        selectedOutput = show.outputs.first?.id
        notify(L("ショー: \(u.lastPathComponent)", "Show: \(u.lastPathComponent)"))
    }

    func saveShowAs() {
        let p = NSSavePanel()
        p.allowedContentTypes = [ShowStore.fileType]
        p.nameFieldStringValue = showFile.map { ($0 as NSString).lastPathComponent } ?? "show.syncshow"
        p.message = L("ショーを保存（映像は同じフォルダに置くと、ほかの Mac でもそのまま開けます）", "Save the show (keep the clips in the same folder so other Macs can open it as is)")
        guard runPanel(p) == .OK, let u = p.url else { return }
        if ShowStore.write(show, to: u) { showFile = u.path; fileShow = show; notify(L("保存: \(u.lastPathComponent)", "Saved: \(u.lastPathComponent)")) }
        else { notify(L("保存できませんでした", "Couldn't save")) }
    }

    func applyShow(_ s: Show) {
        // Another show or seat (opened, the practice show): undo starts again from here.
        undoing = true; show = s; undoing = false
        undoStack.removeAll(); redoStack.removeAll()
        fixSelection()
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
                    m.ver = AppModel.version
                    m.onDemote = { [weak self] in
                        // The exhibition-master mark stays: this Mac is still the one to start as master
                        // after a restart (another Mac took over by hand for now).
                        if self?.exhibitMaster == true { self?.exhibitTakenOver = true }
                        self?.notify(self?.exhibitMaster == true
                            ? L("ほかの Mac がマスターになりました（この Mac は「展示のマスター」のままで、次に開くとマスターで始まります）", "Another Mac became master (this Mac stays Exhibition Master and starts as master next time)")
                            : L("ほかの Mac がマスターになったので、フォロワーに戻りました", "Another Mac became master, so this Mac is a follower again"))
                        self?.setRole(master: false)
                    }
                    master = m
                    notify(L("マスターになりました", "This Mac is now the master"))
                } catch {
                    notify(L("マスターになれません（この Mac で別のマスターが動いていませんか）", "Can't become master (is another master running on this Mac?)"))
                    setRole(master: false)
                    return
                }
            }
        } else {
            let wasMaster = master != nil
            master?.stop(); master = nil
            if follower == nil {
                // A former master keeps playing its own schedule (offset 0) until it has the new clock.
                do {
                    let f = try Follower(transport: transport, provisionalOffset: wasMaster ? 0 : nil)
                    f.report = { [weak self] in
                        guard let self else { return ("", "", nil, nil, "", nil) }
                        let err = self.transport.schedule != nil ? self.transport.maxError * 1000 : nil
                        return (self.opts.name, AppModel.version, err, self.problemNow(), String(self.show.fileLabel.prefix(200)),
                                self.show.seats.count > 1 ? self.show.seat.name : nil)
                    }
                    follower = f
                }
                catch { notify(L("ネットワークのエラー: \(error)", "Network error: \(error)")) }
            }
        }
        isMaster = master != nil
        status.isMaster = isMaster
        refreshTitles()
    }

    private func refreshTitles() {
        for (i, o) in show.outputs.enumerated() { outputs[o.id]?.apply(o, index: i, title: outputTitle(o)) }
        control?.title = L("SyncPlayer — 操作 — ", "SyncPlayer — Control — ") + (isMaster ? L("マスター", "Master") : L("フォロワー", "Follower")) + " — \(opts.name)"
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
                notify(L("ログイン時に開く設定ができません: \(error.localizedDescription)", "Can't set Open at Login: \(error.localizedDescription)"))
            }
            if newValue && SMAppService.mainApp.status == .requiresApproval {
                notify(L("システム設定 → 一般 → ログイン項目 で SyncPlayer を許可してください", "Allow SyncPlayer in System Settings → General → Login Items"))
                SMAppService.openSystemSettingsLoginItems()
            }
            loginItemOn = SMAppService.mainApp.status == .enabled
        }
    }

    func applyAudio() { transport.setAudio(clipID: show.audioClip ?? show.seatClips.first?.id, on: audioOn) }

    func setAudio(_ on: Bool) {
        audioOn = on
        applyAudio()
        if show.audioOn != on { show.audioOn = on }   // kept in this Mac's show
        notify(on ? L("音を出します", "Sound on") : L("消音", "Muted"))
    }

    func setAudioClip(_ id: String?) {
        show.audioClip = id
        applyAudio()
    }

    func notify(_ m: String) { message = m; messageUntil = hostNow() + 3 }

    // MARK: control window

    /// The colour of the control window (and its dialogs): light or dark (Akira 2026-11-25: two kinds
    /// are enough). Older saved values: grey and black become dark; "auto" (and nothing saved) take
    /// the Mac's appearance at that moment.
    enum UITheme: String, CaseIterable, Identifiable {
        case light, dark
        var id: String { rawValue }
        var label: String { self == .light ? L("ライト", "Light") : L("ダーク", "Dark") }
        static func saved() -> UITheme {
            switch UserDefaults.standard.string(forKey: "ui.theme") {
            case "light": return .light
            case "dark", "gray": return .dark
            default:
                let sys = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
                return sys == .darkAqua ? .dark : .light
            }
        }
    }
    @Published var uiTheme: UITheme = UITheme.saved() {
        didSet { UserDefaults.standard.set(uiTheme.rawValue, forKey: "ui.theme"); applyTheme() }
    }

    /// English or Japanese for the control window and messages (this Mac only).
    @Published var uiLang: UILang = UILang.current {
        willSet { UILang.current = newValue }
        didSet {
            UserDefaults.standard.set(uiLang.rawValue, forKey: "ui.lang")
            buildMenu(); refreshInfo(); refreshTitles()
            if let w = keyWindow { w.title = L("キー一覧", "Keyboard Shortcuts"); w.contentView = NSHostingView(rootView: KeyListView()) }
        }
    }

    func applyTheme() {
        NSApp.appearance = NSAppearance(named: uiTheme == .light ? .aqua : .darkAqua)
        control?.backgroundColor = UIColors.base
    }

    private func buildControlWindow() {
        let pv = PictureView(fps: 30)
        guard let pv else { print("Metal is not available"); exit(1) }
        preview = pv
        pv.renderer.layers = { [weak self] in self?.selectedOutputConfig?.layers ?? [] }
        pv.renderer.frames = { [weak self] clip in self?.transport.frames[clip] }
        setupOverlay(pv.overlay, outputID: { [weak self] in self?.selectedOutput },
                     viewAspect: { [weak self] in self?.selectedOutputAspect ?? 16.0 / 9.0 })
        // Click the preview to select the layer under the pointer (frontmost first, like Adobe).
        pv.overlay.pick = { [weak self] p in self?.pickLayer(at: p) }
        let box = AspectBox(child: pv)
        previewBox = box
        pv.overlay.panBy = { [weak box] dx, dy in box?.panBy(dx, dy) }
        // 100 % is the selected output's own pixels.
        box.outputPixels = { [weak self] in
            // The selected output's display in pixels (the same when windowed or full screen).
            guard let self, let o = self.selectedOutputConfig else { return CGSize(width: 1920, height: 1080) }
            let sc = NSScreen.screens.indices.contains(o.screen) ? NSScreen.screens[o.screen] : (NSScreen.main ?? NSScreen.screens[0])
            return CGSize(width: sc.frame.width * sc.backingScaleFactor, height: sc.frame.height * sc.backingScaleFactor)
        }
        box.onZoom = { [weak self] z in self?.previewZoom = z }

        let screen = NSScreen.main ?? NSScreen.screens[0]
        let vf = screen.visibleFrame
        let w = min(1180, vf.width - 40), h = min(760, vf.height - 40)
        let win = NSWindow(contentRect: NSRect(x: vf.minX + 20, y: vf.minY + 20, width: w, height: h),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: 960, height: 600)
        win.contentView = NSHostingView(rootView: ControlView(model: self, status: status))
        win.title = L("SyncPlayer — 操作", "SyncPlayer — Control")
        control = win
        updateRepresented()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The frontmost visible layer of the selected output that shows a picture at window point p
    /// (0...1, y up). Mesh bends are ignored; crop is respected. Clicking an empty spot keeps the selection.
    func pickLayer(at p: SIMD2<Double>) {
        guard let o = selectedOutputConfig else { return }
        let view = selectedOutputAspect
        for l in o.layers.reversed() where l.visible && l.opacity > 0.01 {
            let a = transport.frames[l.clipID]?.aspect ?? 0
            let video = a > 0 ? a : 16.0 / 9.0
            let H = Warp.Homography(Warp.corners(l.look, viewAspect: view, videoAspect: video))
            guard let uv = H.unmap(p.x, p.y), (0...1).contains(uv.x), (0...1).contains(uv.y) else { continue }
            let src = Warp.source(l.look, videoAspect: video, uv.x, uv.y)
            let s = l.look
            guard src.x >= s.cropL, src.x <= 1 - s.cropR, src.y >= s.cropB, src.y <= 1 - s.cropT else { continue }
            if selectedLayer != l.id {
                selectedLayer = l.id
                notify(L("レイヤー: \(clipName(l.clipID))", "Layer: \(clipName(l.clipID))"))
            }
            return
        }
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
        // Settings, the key list and Collect Files: opened while an output is full screen, they come
        // above it (check 40 L2). Left open when an output becomes full screen, they are closed, so
        // the full screen shows only the picture (regression 28, check 41 M1).
        let anyFull = outputs.values.contains { $0.isFull }
        let panels = [settingsWindow, keyWindow, collectWindow].compactMap { $0 }
        if anyFull && !wasFull {
            for w in panels where w.isVisible && !raisedPanels.contains(ObjectIdentifier(w)) { w.orderOut(nil) }
        }
        if !anyFull { raisedPanels.removeAll() }
        wasFull = anyFull
        let up = anyFull && !leftFront && !panelOpen
        for w in panels {
            let level: NSWindow.Level = up && raisedPanels.contains(ObjectIdentifier(w))
                ? NSWindow.Level(rawValue: OutputWindow.fullLevel.rawValue + 2) : .normal
            if w.level != level { w.level = level }
        }
    }
    private var wasFull = false
    private var raisedPanels = Set<ObjectIdentifier>()
    /// Before showing one of those windows: above the full screen if one is up now.
    private func raisePanel(_ w: NSWindow?) {
        guard let w else { return }
        if outputs.values.contains(where: { $0.isFull }) { raisedPanels.insert(ObjectIdentifier(w)) }
        refreshLevels()
    }

    /// Run an open / save panel. Full-screen outputs sit above the menu bar, so they are lowered
    /// while the panel is up (otherwise it could open behind them), also if the app is left and
    /// entered again meanwhile.
    /// Ask before something that cannot be undone (lowers full-screen outputs while the alert is up).
    /// With `skip` (deleting seats, outputs, layers, clips: all undone with ⌘Z) the window has
    /// "Don't ask again" for that kind; turned back on in Settings (⌘,).
    func confirm(_ title: String, _ detail: String, ok: String = L("消す", "Delete"), skip: ConfirmKind? = nil,
                 suppressTitle: String? = nil) -> Bool {
        if let k = skip, !asks(k) { return true }
        let skippable = skip != nil
        let a = NSAlert()
        a.messageText = title
        a.informativeText = detail
        a.addButton(withTitle: ok)
        a.addButton(withTitle: L("やめる", "Cancel"))
        if skippable {
            a.showsSuppressionButton = true
            a.suppressionButton?.title = suppressTitle ?? L("次から確かめない（⌘Z で戻せます）", "Don't ask again (⌘Z undoes)")
        }
        panelOpen = true
        refreshLevels()
        defer { panelOpen = false; refreshLevels() }
        NSApp.activate(ignoringOtherApps: true)
        let yes = a.runModal() == .alertFirstButtonReturn
        if let k = skip, yes, a.suppressionButton?.state == .on { setAsks(k, false) }
        return yes
    }

    /// Deletions whose confirm window can be turned off (each on its own; asked by default).
    enum ConfirmKind: String, CaseIterable, Identifiable {
        case layer, clip, output, seat, quit
        var id: String { rawValue }
        var label: String {
            switch self {
            case .layer: return L("レイヤーを消すとき", "Deleting layers")
            case .clip: return L("映像ライブラリから外すとき", "Removing footage")
            case .output: return L("出力を消すとき", "Deleting outputs")
            case .seat: return L("席を消すとき", "Deleting seats")
            case .quit: return L("SyncPlayer を終了するとき（⌘Q・Q）", "Quitting SyncPlayer (⌘Q, Q)")
            }
        }
    }
    /// Changed in the confirm window ("Don't ask again") or in Settings (⌘,). This Mac only.
    @Published private var confirmSkips: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "ui.confirmSkips") ?? [])
    func asks(_ k: ConfirmKind) -> Bool { !confirmSkips.contains(k.rawValue) }
    func setAsks(_ k: ConfirmKind, _ on: Bool) {
        if on { confirmSkips.remove(k.rawValue) } else { confirmSkips.insert(k.rawValue) }
        UserDefaults.standard.set(Array(confirmSkips).sorted(), forKey: "ui.confirmSkips")
    }
    func asksBinding(_ k: ConfirmKind) -> Binding<Bool> {
        Binding(get: { self.asks(k) }, set: { self.setAsks(k, $0) })
    }

    /// Set for quits that must not ask (--quit-after).
    var quitWithoutAsking = false
    /// Asked before quitting by hand (Akira 2026-11-26), with "Don't ask again".
    func confirmQuit() -> Bool {
        confirm(L("SyncPlayer を終了しますか？", "Quit SyncPlayer?"),
                L("この Mac の出力（全画面も）が閉じ、映像が止まります。ほかの Mac はそのまま動きます。", "This Mac's outputs (full screen too) close and its picture stops. Other Macs keep playing."),
                ok: L("終了", "Quit"), skip: .quit, suppressTitle: L("次から確かめない", "Don't ask again"))
    }

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
        p.message = L("マスクの画像（白は見える、黒は隠れる。映像と同じ縦横比にする。ショーと同じフォルダに置くと、ほかの Mac でもそのまま使えます）", "Mask image (white shows, black hides; use the clip's aspect ratio; keep it in the show's folder for other Macs)")
        guard runPanel(p) == .OK, let u = p.url else { return }
        guard let gpu = GPU.shared, GPU.loadMask(u.path, device: gpu.device) != nil else {
            notify(L("画像を読めませんでした: \(u.lastPathComponent)", "Couldn't read the image: \(u.lastPathComponent)")); return
        }
        // The show may have changed while the panel was open: find the layer again.
        guard let o = show.outputs.firstIndex(where: { $0.id == o0 }),
              let l = show.outputs[o].layers.firstIndex(where: { $0.id == l0 }) else { return }
        show.outputs[o].layers[l].mask = u.path
    }

    func toggleEdit(_ m: EditMode) {
        editMode = editMode == m ? .none : m
        // Editing shows its controls on the right: bring the right column back if hidden (check 46 L1).
        if editMode != .none { UserDefaults.standard.set(false, forKey: "ui.hideRight") }
        notify(editMode == .corners ? L("四隅の変形: 点をドラッグ、Tab で次、矢印で 1 px", "Corner pin: drag a point, Tab next, arrows 1 px")
               : editMode == .mesh ? L("曲面メッシュ: 点をドラッグ、Tab で次、矢印で 1 px", "Mesh: drag a point, Tab next, arrows 1 px") : L("変形の編集を終了", "Finished editing the warp"))
    }

    // MARK: keys

    /// What the delete key removes: set when a row of a left list is clicked (seat, output, layer,
    /// clip). Each removal asks first. Cleared after use.
    var deleteTarget: (() -> Void)?
    /// What ↑ ↓ move through, set with deleteTarget when a layer or footage row is clicked and
    /// cleared with it (Akira 2026-11-26: pick a row, then move with the arrow keys).
    var arrowTarget: ((Int) -> Void)?

    /// ↑ ↓ in the layer list: the row above or below becomes the selected one (picks are dropped).
    func stepLayerRow(_ d: Int) {
        let order = (selectedOutputConfig?.layers ?? []).reversed().map(\.id)
        guard let cur = selectedLayer, let i = order.firstIndex(of: cur) else { return }
        let j = min(max(i + d, 0), order.count - 1)
        guard j != i else { return }
        rowClicking = true; defer { rowClicking = false }
        layerPicks = []
        selectedLayer = order[j]
    }
    /// ↑ ↓ in the footage list.
    func stepClipRow(_ d: Int) {
        let order = show.clips.map(\.id)
        guard let cur = selectedClip, let i = order.firstIndex(of: cur) else { return }
        let j = min(max(i + d, 0), order.count - 1)
        guard j != i else { return }
        clipPicks = []
        selectedClip = order[j]
    }

    private func installKeys() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self else { return e }
            // Only in our own windows, and never while a text field is being typed in.
            guard let w = NSApp.keyWindow, w === self.control || self.outputs.values.contains(where: { $0.window === w })
            else { return e }
            if w.firstResponder is NSText {
                // esc leaves the field without keeping what was typed (FieldEsc), so space and the
                // arrows work again.
                if e.keyCode == 53 { FieldEsc.at = ProcessInfo.processInfo.systemUptime; w.makeFirstResponder(nil); return nil }
                return e
            }
            // After a layer or footage row is clicked, ↑ ↓ move the selection in that list, not the playhead.
            if (e.keyCode == 125 || e.keyCode == 126), let step = self.arrowTarget, w === self.control,
               self.editMode == .none, !e.modifierFlags.contains(.command) {
                step(e.keyCode == 125 ? 1 : -1)
                return nil
            }
            if (e.keyCode == 125 || e.keyCode == 126) && w.firstResponder is NSTableView { return e }
            return self.key(e) ? nil : e
        }
        // A click anywhere outside the text field being typed in leaves it. Otherwise a field
        // clicked once (a name, a number) kept the keys, and space no longer played (Pro, 2026-11-25).
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] e in
            // A click outside the left lists (preview, tabs, output windows) forgets what delete
            // would remove, so delete never removes something picked long ago (check 39).
            AppModel.undoHold = false   // a leftover drag's undo hold ends with the next click (check 47 L3)
            if let self, self.deleteTarget != nil || self.arrowTarget != nil {
                var v: NSView? = nil
                if let w = e.window, let cv = w.contentView {
                    v = cv.hitTest(cv.superview?.convert(e.locationInWindow, from: nil) ?? e.locationInWindow)
                }
                var inList = false
                while let x = v { if x is NSTableView { inList = true; break }; v = x.superview }
                if !inList || e.window !== self.control { self.deleteTarget = nil; self.arrowTarget = nil }
            }
            guard let w = e.window, let editor = w.firstResponder as? NSTextView, editor.isFieldEditor,
                  let field = editor.delegate as? NSView else { return e }
            let p = field.convert(e.locationInWindow, from: nil)
            // Leave only if that same field is still being typed in (a click on another field moved there).
            // The field editor is shared by the window, so compare the field it is editing.
            if !field.bounds.contains(p) {
                DispatchQueue.main.async {
                    if let now = w.firstResponder as? NSTextView, now.isFieldEditor, (now.delegate as? NSView) === field {
                        w.makeFirstResponder(nil)
                    }
                }
            }
            return e
        }
    }
    private var clickMonitor: Any?

    /// The overlay to nudge in pixels: the selected output's window, else the preview.
    private var nudgeOverlay: EditOverlay? {
        if let id = selectedOutput, let w = outputs[id] { return w.picture.overlay }
        return preview?.overlay
    }

    /// One frame of the longest movie (s), 1/30 s until known.
    private var frameStep: Double {
        let f = transport.primary?.frameDuration ?? 0
        return f > 0 ? f : 1.0 / 30
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
            switch ch {
            case "o": openShow(); return true
            case "s": saveShowAs(); return true
            case "e" where shift: showCollectWindow(); return true
            case "z": if shift { redoShow() } else { undoShow() }; return true
            case ",": showSettingsWindow(); return true
            case "y" where shift: AppModel.toggleUI("ui.hideStatus"); return true
            case "0": AppModel.toggleUI(e.modifierFlags.contains(.option) ? "ui.hideRight" : "ui.hideLeft"); return true
            default: return false   // ⌘Q, copy / paste and the rest go to the menu
            }
        }

        switch e.keyCode {
        case 51, 117:                                                   // delete, forward delete
            // Deletes the row last clicked in the left lists (seat, output, layer, clip), asking first.
            // Only in the control window, and only until something outside the lists is clicked.
            guard let del = deleteTarget, !shift, NSApp.keyWindow === control else { return false }
            deleteTarget = nil
            del()
            return true
        case 49: master?.togglePlay(); return true                      // space
        case 48: nudgeOverlay?.selectNext(shift ? -1 : 1); return true   // tab
        case 53: if editing { toggleEdit(editMode) }; return true       // esc
        // Like Premiere / After Effects: ← → one frame (shift: 1 s), ↑ to the start, ↓ to 3 s before
        // the loop point (to look at the seam). While editing corners they move the point.
        case 123:                                                       // ←
            if editing { nudgeOverlay?.nudge(dx: -px, dy: 0) } else { master?.jump(by: shift ? -1 : -frameStep) }
            return true
        case 124:                                                       // →
            if editing { nudgeOverlay?.nudge(dx: px, dy: 0) } else { master?.jump(by: shift ? 1 : frameStep) }
            return true
        case 125:                                                       // ↓
            if editing { nudgeOverlay?.nudge(dx: 0, dy: -px) }
            else if transport.duration > 3 { master?.jump(to: transport.duration - 3) }
            return true
        case 126:                                                       // ↑
            if editing { nudgeOverlay?.nudge(dx: 0, dy: px) } else { master?.jump(to: 0) }
            return true
        default: break
        }

        guard let c = e.charactersIgnoringModifiers?.lowercased(), let ch = c.first else { return false }
        switch ch {
        case "r": master?.jump(to: 0)
        case "m": toggleRole()
        case "s": toggleControl()
        case "i": setInfoShown(!infoShownNow)
        case "h", "?":
            showHelp.toggle()
            defer { objectWillChange.send() }   // the I switch under the preview follows both ways (check 48 L5, 49 L4)
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
            guard hasLayer else { notify(L("レイヤーを選んでください", "Select a layer")); return true }
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
        let lines = statusLines()
        if status.lines != lines { status.lines = lines }
        // The whole control window redraws when peers changes: offsets (rounded to 0.1 ms)
        // update at most once a second, a Mac coming, going or changing its version at once.
        let ps = (master?.peers ?? []).map { p -> Master.Peer in
            var q = p; q.at = 0; q.err = q.err.map { ($0 * 10).rounded() / 10 }; return q
        }
        if ps != peers {
            let shape = { (a: [Master.Peer]) in a.map { [$0.name, $0.ver, $0.warn ?? "", $0.file ?? "", $0.seat ?? ""] } }
            let now = hostNow()
            if shape(ps) != shape(peers) || now - peersAt >= 1 { peers = ps; peersAt = now }
        }
        if master != nil && !ps.isEmpty { learned("synced") }
        if tickCount % 100 == 4 { probeNetwork() }
        // Just made full screen by hand (not the exhibition starting): how to get back, for a few seconds.
        let fullNow = Set(outputs.filter { $0.value.isFull }.map(\.key))
        if hostNow() - started > 10 {
            for id in fullNow.subtracting(fullBefore) {
                outputs[id]?.showHint(L("S で操作の窓  ・  I で動作確認の文字  ・  H でキー一覧", "S control window  ·  I info  ·  H keys"), seconds: 4)
            }
        }
        fullBefore = fullNow
        if status.playing && isMaster { learned("played") }   // a follower plays because the master did
        if outputs.values.contains(where: { $0.isFull }) { learned("fullscreen") }
        if showIdent { learned("ident") }
        if let f = follower, f.masterAlive, f.stats.ready, transport.schedule != nil { learned("synced") }
        if show.outputs.contains(where: { $0.layers.contains { $0.mask != nil } }) && !isPractice { learned("mask") }
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
            let disp = real == nil || real == set ? L("ディスプレイ \(set)", "Display \(set)") : L("ディスプレイ \(real!)（設定は \(set)）", "Display \(real!) (set to \(set))")
            w.layoutIdent("\(opts.name)\n\(disp)\n\(o.name)")
        }
        previewBox?.aspect = selectedOutputAspect
        if editMode != .none && tickCount % 20 == 0 { redrawOverlays() }
    }

    /// The state in plain words for the top of the control window. The state word comes first,
    /// so a narrow window cuts the details, not the state. A problem the detailed status warns
    /// about (cannot open, mask, frames not arriving, a large offset) turns it orange and follows
    /// the state word; a movie name different from the master's is only added at the end.
    private func headlineNow() -> (String, Int) {
        var (line, tone) = roleHeadline()
        if let p = problemNow() {
            // The state word stays first (a narrow window cuts the end), the problem right after it.
            var parts = line.components(separatedBy: " ・ ")
            parts.insert("⚠︎ \(p)", at: 1)
            line = parts.joined(separator: " ・ "); tone = 2
        }
        // Each Mac may play its own movies on purpose, so a different name is only noted, not orange.
        if let f = follower, let mf = f.masterFile, mf != show.fileLabel {
            line += L(" ・ 映像の名前がマスターとちがう（Mac ごとに別の映像なら問題ない）", " ・ clip names differ from the master (fine if each Mac plays its own clips)")
        }
        return (line, tone)
    }

    private func roleHeadline() -> (String, Int) {
        let playing = transport.schedule?.playing ?? false
        if isMaster {
            let n = peers.isEmpty ? L("フォロワーはまだ見えない", "no followers yet") : L("フォロワー \(peers.count) 台", "\(peers.count) follower(s)")
            return playing ? (L("再生中 ・ この Mac がマスター ・ \(n)", "Playing ・ this Mac is master ・ \(n)"), 1) : (L("停止中 ・ この Mac がマスター（space で再生） ・ \(n)", "Stopped ・ this Mac is master (space to play) ・ \(n)"), 0)
        }
        guard let f = follower else { return (L("準備中", "Starting"), 2) }
        let who = String((f.masterName ?? f.masterHost).prefix(16))
        if transport.schedule == nil {
            return f.masterAlive ? (L("マスター（\(who)）と時計を合わせている…", "Syncing clock with the master (\(who))…"), 2)
                                     : (L("マスター待ち ・ マスターの Mac を開くと、そろって始まる", "Waiting for the master ・ open SyncPlayer on the master Mac"), 2)
        }
        if !f.masterAlive {
            return playing ? (L("再生中 ・ マスターが見えない（この Mac だけで続けている）", "Playing ・ master not seen (continuing alone)"), 2)
                           : (L("停止中 ・ マスターが見えない", "Stopped ・ master not seen"), 2)
        }
        if !f.stats.ready { return (L("マスター（\(who)）と時計を合わせている…", "Syncing clock with the master (\(who))…"), 2) }
        let err = String(format: "%.1f", abs(transport.maxError) * 1000)
        return playing ? (L("再生中 ・ マスター（\(who)）に合わせている ・ ずれ \(err) ms", "Playing ・ following the master (\(who)) ・ error \(err) ms"), 1)
                       : (L("停止中 ・ マスター（\(who)）が止めている", "Stopped ・ stopped by the master (\(who))"), 0)
    }

    /// A small datagram to the broadcast address every 5 s: if it cannot go out, this Mac cannot
    /// reach the others (no Local Network permission, or no network).
    private func probeNetwork() {
        if probe == nil { probe = try? UDPSocket(port: 0, broadcast: true) }
        guard let p = probe else { return }
        p.send(Message(k: "x").encoded(), to: UDPSocket.address(opts.broadcast, Ports.beacon))
        let blocked = [EHOSTUNREACH, ENETUNREACH, EPERM, EACCES].contains(p.lastError)
        if blocked != netBlocked { netBlocked = blocked }
    }

    // MARK: the check before an exhibition (展示の前の点検)

    struct CheckItem: Identifiable {
        let id = UUID()
        /// true = fine, false = needs doing, nil = could not be checked from the app.
        let ok: Bool?
        let text: String
        let fix: String
    }
    @Published private(set) var checks: [CheckItem] = []
    @Published private(set) var checkedAt: Date?
    /// Clear the check results (Akira 2026-11-26: a Clear after checking).
    func clearExhibitCheck() { checks = []; checkedAt = nil }

    func runExhibitCheck() {
        var c: [CheckItem] = []
        func add(_ ok: Bool?, _ text: String, _ fix: String) { c.append(CheckItem(ok: ok, text: text, fix: fix)) }
        add(showFile != nil, L("ショーを保存してある", "The show is saved"), L("上の「保存…」で保存する（再起動のあと、このショーが開く）", "Save with the save button at the top (it opens after a restart)"))
        add(!show.clips.contains { clipBroken($0.id) }, L("映像が全部開ける", "All clips open"), L("左の映像ライブラリで「⚠︎ 開けない」の行を右クリックして「差し替え」", "In Footage, right-click the rows marked ⚠︎ › Replace Footage"))
        let masks = show.outputs.flatMap { $0.layers.compactMap(\.mask) }
        add(!masks.contains { !FileManager.default.fileExists(atPath: $0) || GPU.shared?.maskReady($0) == false },
            L("マスクが全部読める", "All masks are readable"), L("「画面の調整」のマスクで画像を選び直す", "Choose the image again under Mask in the Layer tab"))
        add(show.outputs.contains { $0.fullscreen }, L("全画面の出力がある", "An output is full screen"), L("左の出力で「全画面にする（F）」を入れる", "Turn on Full Screen (F) under Outputs"))
        add(openAtLogin, L("ログインしたら SyncPlayer を開く", "SyncPlayer opens at login"), L("下の「ログインしたら SyncPlayer を開く」を入れる（全台）", "Turn on Open SyncPlayer at Login below (all Macs)"))
        if isMaster {
            add(exhibitMaster, L("この Mac は展示のマスター", "This Mac is the exhibition master"), L("マスターの Mac なら「この Mac を展示のマスターにする」を入れる（1 台だけ）", "On the master Mac, turn on Make This Mac the Exhibition Master (one Mac only)"))
            let other = peers.filter { $0.ver != AppModel.version }.count
            add(peers.isEmpty ? nil : other == 0,
                peers.isEmpty ? L("フォロワーが見えない（ほかの Mac を開いてから点検すると、版もそろっているか見られる）", "No followers seen (open the other Macs first to also check their versions)")
                    : other == 0 ? L("フォロワー \(peers.count) 台が同じ版（\(AppModel.version)）", "\(peers.count) follower(s) on the same version (\(AppModel.version))")
                    : L("フォロワー \(peers.count) 台のうち \(other) 台が別の版か古い版（この Mac は \(AppModel.version)）", "\(other) of \(peers.count) follower(s) on another or old version (this Mac: \(AppModel.version))"),
                L("版のちがう Mac に、同じ版の SyncPlayer を入れ直す", "Install the same SyncPlayer version on those Macs"))
        } else {
            add(follower?.masterAlive ?? false, L("マスターが見えている", "The master is seen"), L("マスターの Mac を開く。開いているなら同じネットワークか確かめる", "Open the master Mac. If it is open, check the network"))
            add(follower.flatMap { f in f.masterAlive ? (f.masterVer.map { $0 == AppModel.version } ?? false) : nil },
                L("マスターと同じ版", "Same version as the master"), L("同じ版の SyncPlayer を全台に入れる（版が分からないときはマスターが古い版）", "Install the same version on all Macs (unknown means the master is old)"))
        }
        add(!(exhibitTakenOver && exhibitMaster && master == nil), L("展示のマスターは 1 台だけ", "Only one exhibition master"), L("ほかの Mac の「展示のマスター」を切る", "Turn off Exhibition Master on the other Mac"))
        add(!netBlocked, L("ネットワークに届く", "The network is reachable"), L("システム設定 → プライバシーとセキュリティ → ローカルネットワークで SyncPlayer を入れる", "Turn on SyncPlayer in System Settings → Privacy & Security → Local Network"))
        add(!infoShownNow && !showIdent, L("動作確認の文字と名前の表示（I・N）を消してある", "Info text and names (I, N) are off"), L("I と N を切る", "Turn off I and N"))
        add(AppModel.pmsetValue("autorestart").map { $0 == "1" }, L("停電のあと電源が戻ると Mac が起動する", "The Mac starts when power returns"),
            L("ターミナルで sudo pmset -a autorestart 1、またはシステム設定の「停電後に自動的に起動」", "sudo pmset -a autorestart 1 in Terminal, or Start up automatically after a power failure in System Settings"))
        add(AppModel.plist("/Library/Preferences/com.apple.loginwindow.plist").map { $0["autoLoginUser"] != nil },
            L("電源を入れると自動でログインする", "It logs in automatically"), L("システム設定 → ユーザとグループ → 自動ログイン", "System Settings → Users & Groups → Automatic login"))
        let su = AppModel.plist("/Library/Preferences/com.apple.SoftwareUpdate.plist")
        add(su.flatMap { ($0["AutomaticallyInstallMacOSUpdates"] as? Bool).map { !$0 } }, L("macOS が勝手にアップデートしない", "macOS doesn't update by itself"),
            L("システム設定 → 一般 → ソフトウェアアップデート → 自動アップデートで「macOS アップデートをインストール」を切る", "System Settings → General → Software Update → Automatic Updates: turn off Install macOS updates"))
        checks = c
        checkedAt = Date()
    }

    private static func plist(_ path: String) -> [String: Any]? {
        NSDictionary(contentsOfFile: path) as? [String: Any]
    }

    /// A value from `pmset -g` (nil when it cannot be read).
    private static func pmsetValue(_ key: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["-g"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        for line in text.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if parts.first.map(String.init) == key, parts.count >= 2 { return String(parts[1]) }
        }
        return nil
    }

    /// System Settings at Privacy & Security > Local Network.
    func openLocalNetworkSettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") {
            NSWorkspace.shared.open(u)
        }
    }

    /// The first thing the detailed status warns about, in a few words (nil when all is well).
    func problemNow() -> String? {
        if let mv = follower?.masterVer, mv != AppModel.version { return L("版がちがう（マスター \(mv)、この Mac \(AppModel.version)）", "Version differs (master \(mv), this Mac \(AppModel.version))") }
        // A master older than v0.3.3 does not send its version: say so rather than look all right.
        if let f = follower, f.masterAlive, f.masterVer == nil { return L("マスターの版が分からない（古い版かも。全台を同じ版にする）", "Master version unknown (maybe old; use one version on all Macs)") }
        if master != nil {
            if let p = peers.first(where: { $0.ver == "?" }) { return L("古い版の Mac がある: \(String(p.name.prefix(16)))（全台を同じ版にする）", "A Mac has an old version: \(String(p.name.prefix(16))) (use one version on all Macs)") }
            if let p = peers.first(where: { $0.ver != AppModel.version }) { return L("版がちがう Mac がある: \(String(p.name.prefix(16)))（\(p.ver)）", "A Mac has another version: \(String(p.name.prefix(16))) (\(p.ver))") }
            if let p = peers.first(where: { $0.warn != nil }) { return L("\(String(p.name.prefix(16))) に注意: \(p.warn!)", "Check \(String(p.name.prefix(16))): \(p.warn!)") }
        }
        if exhibitTakenOver && exhibitMaster && master == nil { return L("ほかの Mac がマスター（展示のマスターは 1 台だけ）", "Another Mac is master (only one exhibition master)") }
        for (id, n) in transport.orderedNodes {
            if n.items.contains(where: { $0.status == .failed }) || missingFiles().contains(n.url.path) {
                return L("映像が開けない: \(String(clipName(id).prefix(20)))", "Can't open clip: \(String(clipName(id).prefix(20)))")
            }
        }
        for o in show.outputs {
            for l in o.layers {
                guard let m = l.mask else { continue }
                if missingFiles().contains(m) || GPU.shared?.maskReady(m) == false {
                    return L("マスクが読めない: \(String((m as NSString).lastPathComponent.prefix(20)))", "Can't read mask: \(String((m as NSString).lastPathComponent.prefix(20)))")
                }
            }
        }
        for (id, n) in transport.orderedNodes {
            if !n.ready { return L("読み込み中: \(String(clipName(id).prefix(20)))", "Loading: \(String(clipName(id).prefix(20)))") }
            if transport.frames[id]?.gaveUp == true { return L("コマが届かない: \(String(clipName(id).prefix(20)))", "Frames not arriving: \(String(clipName(id).prefix(20)))") }
        }
        if (transport.schedule?.playing ?? false), follower?.stats.ready ?? isMaster,
           abs(transport.maxError) > 0.02 {
            return String(format: L("ずれが大きい %.0f ms", "Large error %.0f ms"), abs(transport.maxError) * 1000)
        }
        // Last, so it does not hide the problems above; and not for a master on its own (one Mac
        // practising without a network is fine — the exhibition tab still shows the warning).
        if netBlocked && !(master != nil && peers.isEmpty) {
            return L("ネットワークに届かない（ローカルネットワークの許可か、つなぎ方を確かめる）", "Can't reach the network (check Local Network permission or the connection)")
        }
        return nil
    }

    private func roleLine() -> String {
        String(format: "%@ %@  %@\npos %.3f s  error %+.1f ms  jumps %d",
               isMaster ? "MASTER" : "follower", opts.name, show.fileLabel, transport.displayTime(),
               transport.maxError * 1000, transport.resyncCount)
    }

    private func clockLines() -> String {
        var s = ""
        if let c = transport.schedule?.cycle, c > 0 {
            s += String(format: L("\nループ %.3f s（全員いっしょ、短い映像は最後のコマで待つ）", "\nLoop %.3f s (all together; shorter clips hold their last frame)"), c)
        } else if transport.schedule != nil {
            s += L("\nループ: 映像ごとの尺", "\nLoop: each clip's own length")
        }
        if let f = follower {
            let st = f.stats
            s += String(format: "\nmaster %@  clock %@ offset %+.3f ms  rtt %.3f ms",
                        f.masterName.map { "\($0) (\(f.masterHost))" } ?? f.masterHost, st.ready ? "ok" : "learning", st.offset * 1000, st.rtt * 1000)
            if transport.schedule == nil { s += "  (waiting for master)" }
            if let mf = f.masterFile, mf != show.fileLabel { s += L("\n⚠︎ マスターの映像は \(mf)", "\n⚠︎ the master plays \(mf)") }
        } else if let m = master {
            s += m.schedule.playing ? L("\n再生中 — space で停止", "\nPlaying — space to stop") : L("\n停止中 — space で再生", "\nStopped — space to play")
        }
        return s
    }

    /// Text on the output windows.
    private func outputInfo() -> String {
        var s = roleLine() + clockLines()
        if editMode != .none, nudgeOverlay != nil {
            s += L("\n編集: ", "\nEditing: ") + (editMode == .corners ? L("四隅", "corner pin") : L("曲面メッシュ", "mesh")) + L("  点 ", "  point ") + "\(selectedHandle + 1)/\(nudgeOverlay?.handleCount ?? 0)"
        }
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

    /// Rows of the detailed status: each clip's state as well, problems coloured and with what to do.
    private func statusLines() -> [StatusLine] {
        var out: [StatusLine] = []
        func add(_ t: String, _ level: Int = 0, _ fix: String? = nil) {
            out.append(StatusLine(id: out.count, text: t, level: level, fix: fix))
        }
        let maxErr = transport.maxError * 1000
        add(String(format: "%@ %@  %@", isMaster ? "MASTER" : "follower", opts.name, show.fileLabel))
        add(String(format: "pos %.3f s  error %+.1f ms  jumps %d", transport.displayTime(), maxErr, transport.resyncCount),
            abs(maxErr) > 40 ? 3 : abs(maxErr) > 8 ? 2 : 0,
            abs(maxErr) > 8 ? L("ずれが大きい。数秒で戻らないときは、映像の本数か大きさを減らす（目安 1080p 以下、H.264/HEVC）", "Large error. If it doesn't settle in a few seconds, use fewer or smaller clips (about 1080p or less, H.264/HEVC)") : nil)
        if exhibitTakenOver && exhibitMaster && master == nil {
            add(L("この Mac は「展示のマスター」ですが、ほかの Mac がマスターです", "This Mac is Exhibition Master, but another Mac is master"), 3,
                L("「展示のマスター」を入れるのは 1 台だけ。ほかの Mac の設定から外す", "Only one Mac may be Exhibition Master. Turn it off on the other Mac"))
        }
        for o in show.outputs {
            for l in o.layers {
                guard let m = l.mask else { continue }
                let name = (m as NSString).lastPathComponent
                if missingFiles().contains(m) {
                    add(L("マスク \(name) が見つかりません（\(o.name)）— マスクなしで映っています", "Mask \(name) not found (\(o.name)) — showing without it"), 3,
                        L("マスク画像の場所が変わっていないか確かめ、レイヤーのマスクを選び直す", "Check whether the mask image moved, and choose it again for the layer"))
                } else if GPU.shared?.maskReady(m) == false {
                    add(L("マスク \(name) を読めません（\(o.name)）— マスクなしで映っています", "Can't read mask \(name) (\(o.name)) — showing without it"), 3,
                        L("PNG か JPEG の白黒画像にして選び直す", "Use a black-and-white PNG or JPEG and choose it again"))
                }
            }
        }
        if let c = transport.schedule?.cycle, c > 0 {
            add(String(format: L("ループ %.3f s（全員いっしょ、短い映像は最後のコマで待つ）", "Loop %.3f s (all together; shorter clips hold their last frame)"), c))
        } else if transport.schedule != nil {
            add(L("ループ: 映像ごとの尺", "Loop: each clip's own length"))
        }
        if let f = follower {
            let st = f.stats
            add(String(format: "master %@  clock %@  offset %+.3f ms  rtt %.3f ms",
                       f.masterName.map { "\($0) (\(f.masterHost))" } ?? f.masterHost, st.ready ? "ok" : "learning",
                       st.offset * 1000, st.rtt * 1000),
                st.ready ? (st.rtt > 0.020 ? 2 : 1) : 2,
                !st.ready ? L("時計を合わせています。数秒で ok になります", "Syncing the clock. It turns ok in a few seconds")
                    : st.rtt > 0.020 ? L("ネットワークが遅い（rtt 20 ms 超）。有線 LAN か、同じルーターにつなぐ", "Slow network (rtt over 20 ms). Use wired LAN or the same router") : nil)
            if transport.schedule == nil {
                add(L("マスター待ち", "Waiting for the master"), 2, L("マスターの Mac で SyncPlayer が開いているか、同じネットワークか、ローカルネットワークの許可を確かめる", "Check that SyncPlayer is open on the master, the network, and Local Network permission"))
            }
            if let mf = f.masterFile, mf != show.fileLabel {
                add(L("マスターの映像は \(mf)", "The master plays \(mf)"), 2, L("マスターと同じショーファイルを開く", "Open the same show file as the master"))
            }
        } else if let m = master {
            add(m.schedule.playing ? L("再生中 — space で停止", "Playing — space to stop") : L("停止中 — space で再生", "Stopped — space to play"), m.schedule.playing ? 1 : 0)
        }
        for (id, n) in transport.orderedNodes {
            let name = clipName(id)
            if n.items.contains(where: { $0.status == .failed }) || missingFiles().contains(n.url.path) {
                add(L("\(name): 開けません", "\(name): can't open"), 3, L("ファイルの場所が変わったか確かめ、映像ライブラリの行を右クリックして「差し替え」で選び直す。開けない形式なら H.264/HEVC の mov・mp4 に書き出す", "Check whether the file moved and choose it again with right-click › Replace Footage in Footage. If the format won't open, export H.264/HEVC mov or mp4"))
            } else if !n.ready {
                add(L("\(name): 読み込み中", "\(name): loading"))
            } else {
                var t = String(format: "%@: %.1f s  error %+.2f ms  avg %+.2f ms  jumps %d  loops %d",
                               name, n.duration, n.lastError * 1000, n.errorEMA * 1000, n.resyncCount, n.loopCount)
                var level = 1
                var fix: String? = nil
                let avg = abs(n.errorEMA * 1000)
                if abs(n.lastError) > n.hardLimit { level = 3; fix = L("大きくずれた。続くときは映像を軽くする（解像度を下げる・本数を減らす）", "Large jump. If it continues, lighten the clips (lower resolution, fewer clips)") }
                else if avg > n.softLimit * 1000 { level = 2; fix = L("少しずれている。jumps が増え続けるなら映像を軽くする", "Slightly off. If jumps keep rising, lighten the clips") }
                if let f = transport.frames[id] {
                    t += String(format: "  %dx%d %@  dropped %d",
                                Int(n.videoSize.width), Int(n.videoSize.height), f.format, f.framesDropped)
                    let total = f.framesShown + f.framesDropped
                    if f.gaveUp {
                        t += L("  コマが届かない", "  frames not arriving"); level = 3
                        fix = L("この Mac では表示しきれない。解像度を下げるか本数を減らす", "This Mac can't keep up. Lower the resolution or use fewer clips")
                    } else if f.fellBack {
                        t += L("  形を下げた", "  fell back"); level = max(level, 2)
                        fix = fix ?? L("コマの形を下げて表示中。気になるなら解像度を下げる", "Showing frames in a simpler format. Lower the resolution if it matters")
                    } else if total > 300 && Double(f.framesDropped) / Double(total) > 0.05 {
                        level = max(level, 2)
                        fix = fix ?? L("コマが落ちている（5% 超）。ほかのアプリや画面共有を閉じる、映像を軽くする", "Frames dropping (over 5%). Close other apps or screen sharing, or lighten the clips")
                    }
                }
                add(t, level, fix)
            }
        }
        for o in show.outputs {
            guard let w = outputs[o.id] else { continue }
            let r = w.picture.renderer.drawRate
            add(String(format: L("描画 %@ %.0f fps", "Draw %@ %.0f fps"), o.name, r), r > 0 && r < 50 ? 2 : 0,
                r > 0 && r < 50 ? L("描画が遅い。出力・レイヤーの数か映像の大きさを減らす", "Drawing is slow. Use fewer outputs or layers, or smaller clips") : nil)
        }
        if hostNow() < messageUntil { add(message) }
        return out
    }

    func printLog() {
        guard let p = transport.primary else { return }
        let pos = p.position
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

/// A menu item that runs a closure (AppModel is not an NSObject).
final class MenuAction: NSObject {
    private static var all: [MenuAction] = []
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
    @objc func fire(_ sender: Any?) { run() }
    static func item(_ title: String, key: String, _ run: @escaping () -> Void) -> NSMenuItem {
        let a = MenuAction(run)
        all.append(a)
        let i = NSMenuItem(title: title, action: #selector(fire(_:)), keyEquivalent: key)
        i.target = a
        return i
    }
}

struct KeyItem { let key: String; let what: String }
struct KeyGroup { let title: String; let keys: [KeyItem] }

/// When esc left a text field: the field then drops what was typed instead of keeping it.
enum FieldEsc {
    static var at = -10.0
    /// esc was pressed just now (the focus change that follows comes within a moment).
    static var recent: Bool { ProcessInfo.processInfo.systemUptime - at < 0.5 }
}
