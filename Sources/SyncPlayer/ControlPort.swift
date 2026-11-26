import Foundation
import Network

/// Commands from other programs (Claude through Remote Control, Max, TouchDesigner) over HTTP
/// (Akira 2026-11-26). Off by default; turned on in Settings or with --control. Every request needs
/// the key (X-Key header or ?key=), even the ones that only read. Meant for a closed exhibition
/// network (a router not connected to the internet): the traffic is not encrypted.
///
/// Requests are read on a queue of their own; only the short command itself runs on the main
/// thread (the earlier freeze came from a blocked main thread).
final class ControlPort {
    enum Mode: Int { case off = 0, local = 1, lan = 2 }

    struct Request {
        let method: String
        let path: String
        let query: [String: String]
        let from: String
    }
    struct Reply {
        var status = 200
        var body: [String: Any]
        static func error(_ status: Int, _ text: String) -> Reply { Reply(status: status, body: ["ok": false, "error": text]) }
    }

    static let defaultPort: UInt16 = 9310

    /// Runs one command on the main thread and answers.
    var handle: ((Request) -> Reply)?
    /// The port is listening (nil) or could not open (a message), on the main thread.
    var onState: ((String?) -> Void)?

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "sync.control-port")
    private var key = ""
    /// On the queue: wrong keys per sender, and until when a sender is refused.
    private var fails: [String: (count: Int, until: Double)] = [:]
    private var openCount = 0

    /// Counts starts, so a retry of an older start does nothing.
    private var generation = 0

    func start(mode: Mode, port: UInt16, key: String) {
        stop()
        generation += 1
        open(mode: mode, port: port, key: key, gen: generation, tries: 0)
    }

    /// Opens the port. The previous port (or a just-closed connection) may still hold it for a
    /// moment after stop: try again every 2 s, and show the error only after 5 tries (check 58 M1).
    private func open(mode: Mode, port: UInt16, key: String, gen: Int, tries: Int) {
        guard gen == generation else { return }
        guard mode != .off, !key.isEmpty, let p = NWEndpoint.Port(rawValue: port) else { return }
        let params = NWParameters.tcp
        // No reuse: a port another program holds must fail here, not be shared (check 56 M3).
        params.allowLocalEndpointReuse = false
        // "This Mac only": listen on the loopback interface, so nothing from the network reaches it.
        if mode == .local { params.requiredInterfaceType = .loopback }
        let k = key
        queue.async { self.key = k; self.fails = [:] }
        do {
            let l = try NWListener(using: params, on: p)
            l.stateUpdateHandler = { [weak self] st in
                switch st {
                case .ready: DispatchQueue.main.async { self?.onState?(nil) }
                case .waiting(let e), .failed(let e):   // .waiting: e.g. the port is taken (check 56 M3)
                    l.cancel()
                    DispatchQueue.main.async {
                        guard let self, gen == self.generation else { return }
                        if self.listener === l { self.listener = nil }
                        if tries < 4 {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                self.open(mode: mode, port: port, key: key, gen: gen, tries: tries + 1)
                            }
                        } else {
                            self.onState?(L("命令を受ける口を開けない（ポート \(port)）: \(e.localizedDescription)",
                                            "Cannot open the command port (\(port)): \(e.localizedDescription)"))
                        }
                    }
                default: break
                }
            }
            l.newConnectionHandler = { [weak self] c in self?.accept(c) }
            l.start(queue: queue)
            listener = l
        } catch {
            onState?(L("命令を受ける口を開けない（ポート \(port)）: \(error.localizedDescription)",
                       "Cannot open the command port (\(port)): \(error.localizedDescription)"))
        }
    }

    func stop() {
        generation += 1
        listener?.cancel()
        listener = nil
    }

    // MARK: on the queue

    private func accept(_ c: NWConnection) {
        guard openCount < 8 else { c.cancel(); return }   // a few at a time is all a script needs
        openCount += 1
        var done = false
        func finish() { if !done { done = true; openCount -= 1; c.cancel() } }
        c.stateUpdateHandler = { st in
            switch st {
            case .failed, .cancelled: if !done { done = true; self.openCount -= 1 }
            default: break
            }
        }
        c.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 5) { finish() }   // a sender that never finishes its request
        read(c, Data(), finish)
    }

    private func read(_ c: NWConnection, _ have: Data, _ finish: @escaping () -> Void) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, end, err in
            guard let self else { return }
            var buf = have
            if let d = data { buf.append(d) }
            if let r = buf.range(of: Data("\r\n\r\n".utf8)) {
                self.answer(c, head: buf[..<r.lowerBound], finish)
            } else if err != nil || end || buf.count > 16384 {
                finish()
            } else {
                self.read(c, buf, finish)
            }
        }
    }

    private func answer(_ c: NWConnection, head: Data, _ finish: @escaping () -> Void) {
        let from: String = {
            if case let .hostPort(h, _) = c.endpoint { return "\(h)" }
            return "?"
        }()
        func send(_ r: Reply) {
            let json = (try? JSONSerialization.data(withJSONObject: r.body, options: [.sortedKeys])) ?? Data("{}".utf8)
            let reason = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found", 405: "Method Not Allowed", 409: "Conflict", 429: "Too Many Requests"][r.status] ?? "Error"
            var out = Data("HTTP/1.1 \(r.status) \(reason)\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: \(json.count)\r\nConnection: close\r\n\r\n".utf8)
            out.append(json)
            c.send(content: out, completion: .contentProcessed { _ in finish() })
        }
        let now = Date().timeIntervalSince1970
        if let f = fails[from], f.until > now { send(.error(429, "too many wrong keys; wait a minute")); return }
        guard let text = String(data: head, encoding: .utf8) else { send(.error(400, "bad request")); return }
        let lines = text.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        guard first.count >= 2 else { send(.error(400, "bad request")); return }
        let method = String(first[0]).uppercased()
        let target = String(first[1])
        var headers: [String: String] = [:]
        for l in lines.dropFirst() {
            guard let i = l.firstIndex(of: ":") else { continue }
            headers[l[..<i].trimmingCharacters(in: .whitespaces).lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces)
        }
        let comps = URLComponents(string: "http://x" + target)
        var query: [String: String] = [:]
        for q in comps?.queryItems ?? [] { query[q.name] = q.value ?? "" }
        let given = headers["x-key"] ?? query["key"] ?? ""
        guard ControlPort.same(given, key) else {
            let n = (fails[from]?.count ?? 0) + 1
            fails[from] = n >= 5 ? (0, now + 60) : (n, 0)
            send(.error(401, "wrong or missing key (X-Key header)"))
            return
        }
        fails[from] = nil
        query["key"] = nil
        let req = Request(method: method, path: comps?.path ?? "/", query: query, from: from)
        DispatchQueue.main.async { [weak self] in
            let r = self?.handle?(req) ?? .error(503, "not ready")
            self?.queue.async { send(r) }
        }
    }

    /// Compares every character, so the time taken does not tell how much of a guess was right.
    static func same(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count, !y.isEmpty else { return false }
        var d: UInt8 = 0
        for i in 0..<x.count { d |= x[i] ^ y[i] }
        return d == 0
    }

    /// A new key: 12 letters and digits in groups of 4 (easy to read out and type).
    static func newKey() -> String {
        let chars = Array("abcdefghjkmnpqrstuvwxyz23456789")
        var g = SystemRandomNumberGenerator()
        return (0..<3).map { _ in String((0..<4).map { _ in chars.randomElement(using: &g)! }) }.joined(separator: "-")
    }
}
