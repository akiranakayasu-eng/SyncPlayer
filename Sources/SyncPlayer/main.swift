import AppKit

// SyncPlayer
//   SyncPlayer [--master | --follower] [<movie> ...] [--show FILE.syncshow]
// Options: --name A  --seat NAME  --fullscreen  --screen 1 (first output)  --audio | --mute
//          --broadcast 192.168.1.255  --to 192.168.1.23 (extra master->follower address, repeatable)
//          --log  --log-interval 0.1  --autoplay 2 (master starts by itself)  --quit-after 60
//          --switch-after 30 (test: switch master <-> follower after 30 s)
//          --bgra (test: ask for BGRA frames instead of YUV, to compare the GPU load)
//          --frames 420v|422v|x422|BGRA (test: ask for this frame layout only)

struct Options {
    var master = false
    /// --master or --follower was given (otherwise the show's remembered role is used).
    var roleGiven = false
    var files: [String] = []
    var showFile: String?
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
    /// The seat this Mac is, by name (else the one it remembers, else it asks).
    var seat: String?
    var switchAfter: Double? = nil   // test: switch role (master <-> follower) after N seconds

    init(_ args: [String]) {
        var i = 1
        func next() -> String { i += 1; return i < args.count ? args[i] : "" }
        while i < args.count {
            switch args[i] {
            case "--master": master = true; roleGiven = true
            case "--follower": master = false; roleGiven = true
            case "--name": name = next()
            case "--fullscreen": fullscreen = true
            case "--screen": screen = Int(next())
            case "--audio": audio = true
            case "--mute": audio = false
            case "--broadcast": broadcast = next()
            case "--to": extra.append(next())
            case "--log": log = true
            case "--help", "-h":
                // Print the options and stop, before any window opens or the show is saved
                // (2026-11-25: --help used to start the app and rewrite current.syncshow).
                print("usage: SyncPlayer [movies…] [--show file] [--master|--follower] [--name n] [--fullscreen] [--screen i] [--audio|--mute] [--broadcast a] [--to host] [--log] [--log-interval s] [--autoplay s] [--quit-after s] [--switch-after s] [--seat name] [--bgra] [--frames 420v|422v|x422|BGRA]")
                exit(0)
            case "--log-interval": log = true; logInterval = Double(next()) ?? 1
            case "--autoplay": autoplay = Double(next()) ?? 2
            case "--quit-after": quitAfter = Double(next())
            case "--preset": preset = next()
            case "--seat": seat = next()
            case "--switch-after": switchAfter = Double(next())
            case "--show": showFile = next()
            case "--bgra": FrameFormat.bgra = true   // test: frames as BGRA (the v0.3 way) instead of YUV
            case "--frames":   // test: 420v, 422v, x422, BGRA
                let v = next()
                if let c = FrameFormat.code(v) { FrameFormat.forced = c } else { print("--frames: not a 4-letter layout: \(v) (ignored)"); fflush(stdout) }
            default: if !args[i].hasPrefix("-") { files.append(args[i]) }   // skip -psn_… and other system flags
            }
            i += 1
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model: AppModel
    init(opts: Options) { model = AppModel(opts: opts) }
    private var started = false
    func applicationDidFinishLaunching(_ n: Notification) { model.start(); started = true }
    /// A .syncshow double-clicked in Finder (or dropped on the app): open it. At launch it is
    /// read instead of the last show.
    func application(_ sender: NSApplication, open urls: [URL]) {
        guard let u = urls.first(where: { $0.pathExtension.lowercased() == "syncshow" }) else { return }
        if started { model.openShow(at: u) } else { model.opts.showFile = u.path }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }
    /// ⌘Q, Q or the menu asks first (Akira 2026-11-26; can be turned off). A restart, shut down or
    /// log out of the Mac (exhibitions) and --quit-after never ask.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let ev = NSAppleEventManager.shared().currentAppleEvent
        let bySystem = ev?.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason)) != nil
        if bySystem || model.quitWithoutAsking || !started { return .terminateNow }
        return model.confirmQuit() ? .terminateNow : .terminateCancel
    }
    func applicationWillTerminate(_ n: Notification) { model.willTerminate() }
}

let opts = Options(CommandLine.arguments)
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate(opts: opts)
app.delegate = delegate
app.run()
