import Foundation

/// Just the parts of a Mac .syncshow (version 3) that stage 2 of the iOS follower uses: clips, the
/// seats, and each seat's first output's layers (order, visible, opacity) and sound. Everything else
/// (warp, crop, mask, edge blend, loop settings) is ignored for now.
struct ShowFile {
    struct Clip { var id: String; var path: String }
    struct Layer { var clipID: String; var visible: Bool; var opacity: Double; var name: String? }
    struct Output { var name: String; var layers: [Layer] }
    struct Seat { var id: String; var name: String; var outputs: [Output]; var audioClip: String?; var audioOn: Bool? }
    var id: String
    var folder: URL
    var title: String
    var clips: [Clip]
    var seats: [Seat]

    func clipURL(_ id: String) -> URL? {
        guard let c = clips.first(where: { $0.id == id }) else { return nil }
        let fm = FileManager.default
        let name = (c.path as NSString).lastPathComponent
        // Paths of a Collect Files folder are relative; others are Mac paths: look next to the show.
        var cands: [URL] = []
        if !c.path.hasPrefix("/") { cands.append(folder.appendingPathComponent(c.path)) }
        cands += [folder.appendingPathComponent(name), folder.appendingPathComponent("movies").appendingPathComponent(name)]
        return cands.first { fm.fileExists(atPath: $0.path) }
    }

    static func read(_ url: URL) -> ShowFile? {
        guard let d = try? Data(contentsOf: url),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let clipsJ = j["clips"] as? [[String: Any]] else { return nil }
        let clips = clipsJ.compactMap { c -> Clip? in
            guard let id = c["id"] as? String, let p = c["path"] as? String else { return nil }
            return Clip(id: id, path: p)
        }
        var seats: [Seat] = []
        for (k, s) in ((j["seats"] as? [[String: Any]]) ?? []).enumerated() {
            let outs = ((s["outputs"] as? [[String: Any]]) ?? []).map { o -> Output in
                let layers = ((o["layers"] as? [[String: Any]]) ?? []).compactMap { l -> Layer? in
                    guard let cid = l["clipID"] as? String else { return nil }
                    return Layer(clipID: cid, visible: (l["visible"] as? Bool) ?? true,
                                 opacity: (l["opacity"] as? Double) ?? 1, name: l["name"] as? String)
                }
                return Output(name: (o["name"] as? String) ?? "Screen", layers: layers)
            }
            seats.append(Seat(id: (s["id"] as? String) ?? "seat\(k)", name: (s["name"] as? String) ?? "A",
                              outputs: outs, audioClip: s["audioClip"] as? String, audioOn: s["audioOn"] as? Bool))
        }
        if seats.isEmpty { return nil }
        return ShowFile(id: (j["id"] as? String) ?? url.path, folder: url.deletingLastPathComponent(),
                        title: url.deletingPathExtension().lastPathComponent, clips: clips, seats: seats)
    }

    /// Shows found in Documents (a .syncshow there, or in a folder one level down, e.g. Documents/shows/<name>/).
    static func scanDocuments() -> [URL] {
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return [] }
        var out: [URL] = []
        func look(_ dir: URL, depth: Int) {
            for u in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? [] {
                if u.pathExtension == "syncshow" { out.append(u) }
                else if depth > 0, (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { look(u, depth: depth - 1) }
            }
        }
        look(docs, depth: 2)
        return out.sorted { $0.path < $1.path }
    }
}
