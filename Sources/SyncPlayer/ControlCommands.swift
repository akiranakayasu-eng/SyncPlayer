import AppKit

/// The commands the command port takes (ControlPort). Each one goes through the same functions as
/// the controls on screen, so saving, ⌘Z and the messages to the other Macs are the same.
/// Nothing that cannot be undone (delete, quit, overwrite, settings, the port itself).
extension AppModel {
    // Settings (per Mac). Command-line options win for this launch.
    static let controlModeKey = "control.mode", controlPortKey = "control.port", controlKeyKey = "control.key"

    var controlMode: ControlPort.Mode {
        if let m = opts.control { return m }
        return ControlPort.Mode(rawValue: UserDefaults.standard.integer(forKey: AppModel.controlModeKey)) ?? .off
    }
    var controlPortNumber: UInt16 {
        if let p = opts.controlPort { return p }
        let v = UserDefaults.standard.integer(forKey: AppModel.controlPortKey)
        return (1024...65535).contains(v) ? UInt16(v) : ControlPort.defaultPort
    }
    /// The key: from --control-key, else the one kept for this Mac (made the first time it is needed).
    var controlKey: String {
        // A short --control-key is ignored (check 56); said once in the log (check 58 L1).
        if let k = opts.controlKey, k.count >= 8 { return k }
        if let k = UserDefaults.standard.string(forKey: AppModel.controlKeyKey), !k.isEmpty { return k }
        let k = ControlPort.newKey()
        UserDefaults.standard.set(k, forKey: AppModel.controlKeyKey)
        return k
    }

    /// Opens, moves or closes the port to match the settings. Called at launch and from Settings.
    func applyControlPort() {
        controlPort.handle = { [weak self] r in self?.runCommand(r) ?? .error(503, "not ready") }
        controlPort.onState = { [weak self] e in
            guard let self else { return }
            self.controlError = e
            if let e { self.notify(e); print("control: \(e)"); fflush(stdout) }
        }
        let m = controlMode
        if let k = opts.controlKey, k.count < 8, m != .off { print("control: --control-key is shorter than 8 characters; using the key in Settings"); fflush(stdout) }
        controlError = nil
        controlPort.start(mode: m, port: controlPortNumber, key: m == .off ? "" : controlKey)
        controlOn = m != .off
        if m != .off { print("control: \(m == .local ? "this Mac only" : "network") port \(controlPortNumber)"); fflush(stdout) }
    }

    func newControlKey() {
        UserDefaults.standard.set(ControlPort.newKey(), forKey: AppModel.controlKeyKey)
        applyControlPort()
    }

    // MARK: commands

    func runCommand(_ r: ControlPort.Request) -> ControlPort.Reply {
        let q = r.query
        func flag(_ k: String) -> Bool? {
            guard let v = q[k]?.lowercased() else { return nil }
            return ["1", "true", "on", "yes"].contains(v) ? true : ["0", "false", "off", "no"].contains(v) ? false : nil
        }
        let path = r.path.lowercased()
        if path == "/status" || path == "/" {
            guard r.method == "GET" || r.method == "POST" else { return .error(405, "use GET") }
            return ControlPort.Reply(body: controlStatus())
        }
        guard r.method == "POST" else { return .error(405, "use POST for \(r.path)") }
        // Addressed to another Mac or seat (a command sent to the wrong address): refuse.
        if let m = q["mac"], m != opts.name { return .error(409, "this is \(opts.name), not \(m)") }
        if let s = q["seat"], s != seatName && s != show.seatID { return .error(409, "this Mac is seat \(seatName), not \(s)") }
        controlLastAt = hostNow()
        func log(_ what: String) { print("control: \(r.from) \(what)"); fflush(stdout) }

        switch path {
        case "/play", "/pause", "/toggle", "/home", "/seek":
            guard let m = master else { return .error(409, "only the master plays and moves; this Mac is a follower") }
            switch path {
            case "/play": if !m.schedule.playing { m.play() }
            case "/pause": if m.schedule.playing { m.pause() }
            case "/toggle": m.togglePlay()
            case "/home": m.jump(to: 0)
            default:
                guard let t = q["t"].flatMap(Double.init), t.isFinite, t >= 0 else { return .error(400, "seek needs t (seconds)") }
                m.jump(to: t)
            }
            log(path)
        case "/role":
            guard let b = flag("master") else { return .error(400, "role needs master=1 or master=0") }
            if (master != nil) != b { setRoleByHand(master: b) }
            log("role master=\(b)")
        case "/audio":
            guard let b = flag("on") else { return .error(400, "audio needs on=1 or on=0") }
            setAudio(b)
            log("audio \(b)")
        case "/layer":
            // n: 1 = front, as numbered in the layer list. o: output number (default the first).
            let o = (q["o"].flatMap(Int.init) ?? 1) - 1
            guard show.outputs.indices.contains(o) else { return .error(404, "no output \(o + 1)") }
            // The list numbers the layers from the front, which is the end of the array (check 56 M1).
            let count = show.outputs[o].layers.count
            guard let n = q["n"].flatMap(Int.init), (1...max(1, count)).contains(n), count > 0 else { return .error(404, "no layer n in output \(o + 1)") }
            let li = count - n
            var l = show.outputs[o].layers[li]
            if let v = flag("visible") { l.visible = v }
            if let a = q["opacity"].flatMap(Double.init), a.isFinite { l.opacity = min(1, max(0, a)) }
            if l != show.outputs[o].layers[li] { show.outputs[o].layers[li] = l }   // one ⌘Z; saved like a change on screen
            log("layer \(o + 1)/\(n) visible=\(l.visible) opacity=\(l.opacity)")
        case "/overlay":
            if let b = flag("names") { showIdent = b }
            if let b = flag("info") { setInfoShown(b) }
            if let b = flag("grid") {
                var s = show
                for o in s.outputs.indices { for l in s.outputs[o].layers.indices { s.outputs[o].layers[l].look.showGrid = b } }
                if s != show { show = s }
            }
            log("overlay")
        case "/open":
            // Only a .syncshow in the same folder as the show open now (not anywhere on the Mac).
            guard let name = q["show"], !name.isEmpty, !name.contains("/"), name.lowercased().hasSuffix(".syncshow") else {
                return .error(400, "open needs show=NAME.syncshow (a file next to the show open now)")
            }
            guard let cur = showFile else { return .error(409, "no show file is open; open one on screen first") }
            let u = URL(fileURLWithPath: cur).deletingLastPathComponent().appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: u.path) else { return .error(404, "not found next to the open show: \(name)") }
            // After answering: a show with several seats may ask which seat this Mac is.
            DispatchQueue.main.async { [weak self] in self?.openShow(at: u) }
            log("open \(name)")
            return ControlPort.Reply(body: ["ok": true, "opening": name])
        case "/reset-counts":
            transport.resetCounts()
            log("reset counts")
        default:
            return .error(404, "unknown command \(r.path). Commands: /status /play /pause /toggle /home /seek?t= /role?master= /audio?on= /layer?o=&n=&visible=&opacity= /overlay?grid=&names=&info= /open?show= /reset-counts")
        }
        notify(L("外からの命令: \(r.path)", "Command from outside: \(r.path)"))
        var b = controlStatus()
        b["ok"] = true
        return ControlPort.Reply(body: b)
    }

    var seatName: String { show.seats.first { $0.id == show.seatID }?.name ?? "" }

    /// What /status answers: the values of the log line, and the outputs and layers.
    func controlStatus() -> [String: Any] {
        var b: [String: Any] = [
            "ok": true, "app": "SyncPlayer", "version": AppModel.version, "mac": opts.name, "seat": seatName,
            "role": master != nil ? "master" : "follower", "audio": audioOn,
            "show": showFile.map { ($0 as NSString).lastPathComponent } ?? "",
            "position": transport.currentPosition(), "duration": transport.duration,
            "jumps": transport.resyncCount, "maxErrorMs": transport.maxError * 1000,
        ]
        if let m = master { b["playing"] = m.schedule.playing }
        else if let s = follower?.localSchedule() { b["playing"] = s.playing }
        if let p = transport.primary {
            b["loops"] = p.loopCount
            b["errorMs"] = p.lastError * 1000
            b["avgErrorMs"] = p.errorEMA * 1000
        }
        if let f = follower { b["masterAlive"] = f.masterAlive }
        let fs = Array(transport.frames.values)
        b["framesShown"] = fs.reduce(0) { $0 + $1.framesShown }
        b["framesDropped"] = fs.reduce(0) { $0 + $1.framesDropped }
        b["outputs"] = show.outputs.enumerated().map { (i, o) -> [String: Any] in
            [
                "number": i + 1, "name": o.name, "display": o.screen + 1, "fullscreen": o.fullscreen,
                "drawFps": outputs[o.id]?.picture.renderer.drawRate ?? 0,
                "layers": o.layers.reversed().enumerated().map { (j, l) -> [String: Any] in
                    ["number": j + 1,   // 1 = front, as in the layer list
                     "name": l.name ?? clipName(l.clipID), "visible": l.visible, "opacity": l.opacity]
                },
            ]
        }
        if master != nil {
            b["followers"] = peers.map { p -> [String: Any] in
                var d: [String: Any] = ["name": p.name, "version": p.ver, "seat": p.seat ?? ""]
                if let e = p.err { d["errorMs"] = e }   // already ms
                if let w = p.warn { d["warning"] = w }
                return d
            }
        }
        b["names"] = showIdent
        b["info"] = infoShownNow
        return b
    }
}
