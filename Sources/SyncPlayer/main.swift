import AppKit

// SyncPlayer
//   SyncPlayer [--master | --follower] [<movie> ...] [--show FILE.syncshow]
// Options: --name A  --preset NAME  --fullscreen  --screen 1 (first output)  --audio | --mute
//          --broadcast 192.168.1.255  --to 192.168.1.23 (extra master->follower address, repeatable)
//          --log  --log-interval 0.1  --autoplay 2 (master starts by itself)  --quit-after 60
//          --switch-after 30 (test: switch master <-> follower after 30 s)

struct Options {
    var master = false
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
            case "--show": showFile = next()
            default: if !args[i].hasPrefix("-") { files.append(args[i]) }   // skip -psn_… and other system flags
            }
            i += 1
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model: AppModel
    init(opts: Options) { model = AppModel(opts: opts) }
    func applicationDidFinishLaunching(_ n: Notification) { model.start() }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ n: Notification) { model.willTerminate() }
}

let opts = Options(CommandLine.arguments)
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate(opts: opts)
app.delegate = delegate
app.run()
