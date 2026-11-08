// The player's games as NX Pocket for Mac sees them: one folder per game (as scripts/build_ipa_from_nsp.py takes it), its NSP / XCI / NSZ / XCZ files paired by the
// title ID in their names (base game: …000, update: …800, add-on content: the others), its name, version and icon from its own control data once the build has
// extracted it (<title ID>_build/extract/<version>/control.nacp, icon.jpg; nothing is fetched from anywhere), and its game pack once made: in the game pack folder
// (Settings, kept apart from the games' build files), found by the title ID in its pack.json, else in the game's folder (packs made before there was one).
import AppKit

/// A game pack in the game pack folder: its title ID and name from its pack.json, when it was made
struct PackEntry: Equatable {
    let url: URL
    let titleID: String?
    let name: String?
    let made: Date

    /// The folder's packs (single files and pack folders, not build_pack.py's work in progress: .<name>…), newest first
    static func index(_ folder: URL?) -> [PackEntry] {
        guard let folder, let items = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        return items.filter { $0.pathExtension == "nxpack" && !$0.lastPathComponent.hasPrefix(".") }.map { u in
            let json = PackFile.isFile(u) ? (try? PackFile(u))?.data("pack.json") : try? Data(contentsOf: u.appendingPathComponent("pack.json"))
            let info = json.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            return PackEntry(url: u, titleID: (info["titleID"] as? String)?.uppercased(), name: info["name"] as? String,
                             made: (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast)
        }
        .sorted { $0.made > $1.made }
    }
}

/// One file of a game: what it is and its version
struct GameFile: Identifiable, Equatable {
    enum Kind: Int { case base, update, dlc }
    let url: URL
    let kind: Kind
    let titleID: String?
    let version: Int?       // [v65536] in the name
    let size: Int64
    var id: String { url.path }
}

struct MacGame: Identifiable, Equatable {
    let folder: URL
    var files: [GameFile] = []
    var titleID: String?            // the base game's
    var name: String
    var version: String?            // the display version from the control data
    var icon: NSImage?
    var buildDir: URL?              // <title ID>_build: the NSP script's work folder
    var pack: URL?                  // the game pack made from it
    var macApp: URL?                // its Mac version (MacVersion), in its build folder
    var packMade: Date?
    var scanned = false             // false: only its folder is known yet (the scan runs off the main thread)
    var switch2: Switch2Source?     // a Switch 2 game: its files as a dump folder or one NUP container, which need no prod.keys
    var id: String { folder.path }

    var base: GameFile? { files.first { $0.kind == .base } }
    var updates: [GameFile] { files.filter { $0.kind == .update }.sorted { ($0.version ?? 0) < ($1.version ?? 0) } }
    var dlc: [GameFile] { files.filter { $0.kind == .dlc } }
    var prepared: Bool { buildDir.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("xcode/Gen/resources.env").path) } ?? false }

    static func == (a: MacGame, b: MacGame) -> Bool {
        a.folder == b.folder && a.scanned == b.scanned && a.files == b.files && a.name == b.name && a.version == b.version && a.buildDir == b.buildDir && a.pack == b.pack && a.packMade == b.packMade && a.macApp == b.macApp && a.switch2 == b.switch2 && (a.icon == nil) == (b.icon == nil)
    }

    static let gameExtensions: Set<String> = ["nsp", "xci", "nsz", "xcz"]

    /// Reads a game folder: its files, its build folder and what the build extracted, its game pack (`packs`: the game pack folder's, PackEntry.index); `repo`: the
    /// checkout whose profile names a Switch 2 game, whose files carry no control data
    static func scan(_ folder: URL, packs: [PackEntry] = [], repo: String = "") -> MacGame {
        let fm = FileManager.default
        var g = MacGame(folder: folder, name: folder.lastPathComponent, scanned: true)
        let items = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
        for u in items where gameExtensions.contains(u.pathExtension.lowercased()) && !u.lastPathComponent.hasPrefix("._") {
            let size = Int64((try? u.resolvingSymlinksInPath().resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)   // a link's file, not the link
            guard size > 0 else { continue }
            let name = u.lastPathComponent
            let tid = name.firstMatch(of: /\[([0-9A-Fa-f]{16})\]/).map { String($0.1).uppercased() }
            let ver = name.firstMatch(of: /\[v(\d+)\]/).flatMap { Int($0.1) }
            var kind = GameFile.Kind.base
            if let tid, let v = UInt64(tid, radix: 16) { kind = v & 0xFFF == 0 ? .base : v & 0xFFF == 0x800 ? .update : .dlc }
            else if let ver, ver > 0 { kind = .update }
            g.files.append(GameFile(url: u, kind: kind, titleID: tid, version: ver, size: size))
        }
        g.files.sort { ($0.kind.rawValue, $0.url.lastPathComponent) < ($1.kind.rawValue, $1.url.lastPathComponent) }
        if g.files.isEmpty, let s = Switch2Source.scan(folder, items: items) { g.switch2 = s.source; g.files = s.files; g.titleID = s.titleID; g.version = s.files.last { $0.kind == .update }.map { "v\($0.version ?? 0)" } }
        // the base game's title ID: the base file's, else derived from an update's or a DLC's
        if g.titleID == nil, let t = g.base?.titleID { g.titleID = t }
        else if g.titleID == nil, let t = g.files.compactMap(\.titleID).first, let v = UInt64(t, radix: 16) {
            let base = v & 0xFFF == 0x800 ? v & ~0xFFF : (v & ~0xFFF) - 0x1000
            g.titleID = String(format: "%016llX", base)
        }
        // the build folder: <title ID>_build, else the only one there
        let builds = items.filter { $0.lastPathComponent.hasSuffix("_build") && $0.hasDirectoryPath }
        let tid = g.titleID
        g.buildDir = builds.first { b in tid.map { b.lastPathComponent.uppercased().hasPrefix($0) } ?? false } ?? (builds.count == 1 ? builds[0] : nil)
        if g.titleID == nil, let b = g.buildDir { g.titleID = String(b.lastPathComponent.prefix(16)).uppercased() }
        // what the build extracted: the newest version's control data and icon; before a build, what --control-only read of the packages (<title ID>_build/control)
        if let b = g.buildDir {
            let extract = b.appendingPathComponent("extract")
            let versions = ((try? fm.contentsOfDirectory(atPath: extract.path)) ?? []).filter { $0.hasPrefix("v") }.sorted { (Int($0.dropFirst()) ?? 0) < (Int($1.dropFirst()) ?? 0) }
            for d in versions.reversed().map({ extract.appendingPathComponent($0) }) + [b.appendingPathComponent("control")] {
                if g.icon == nil, let i = NSImage(contentsOf: d.appendingPathComponent("icon.jpg")) { g.icon = i }
                if let n = NACP(contentsOf: d.appendingPathComponent("control.nacp")) {
                    if g.name == folder.lastPathComponent, let t = n.title { g.name = t }
                    if g.version == nil { g.version = n.displayVersion }
                }
            }
        }
        // a Switch 2 dump has no control data (a NUP may carry some, which the build extracts as above): its name is its profile's
        if g.switch2 != nil, g.name == folder.lastPathComponent, let n = Switch2Source.profileName(g.titleID, repo: repo) { g.name = n }
        g.macApp = g.buildDir.flatMap { MacVersion.app(in: $0) }
        // its game pack: the game pack folder's newest with its title ID (else, before the title ID is known, with its file name), else the newest .nxpack in its own folder
        if let p = packs.first(where: { e in g.titleID.map { e.titleID == $0 } ?? (e.url.lastPathComponent == g.packName) }) { g.pack = p.url; g.packMade = p.made }
        else if let p = items.filter({ $0.pathExtension == "nxpack" && !$0.lastPathComponent.hasPrefix(".") })   // not build_pack.py's work in progress (.<name>…)
            .map({ ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast) }).max(by: { $0.1 < $1.1 }) {
            g.pack = p.0; g.packMade = p.1
        }
        // the pack's icon@4x.png (1024×1024, made from the game's 256 icon: build_pack.py) before the 256 one the build extracted
        if let p = g.pack {
            let f = PackFile.isFile(p) ? try? PackFile(p) : nil
            let big = f != nil ? f?.data("icon@4x.png").flatMap(NSImage.init(data:)) : NSImage(contentsOf: p.appendingPathComponent("icon@4x.png"))
            if let big { g.icon = big }
            else if g.icon == nil { g.icon = f != nil ? f?.data("icon.png").flatMap(NSImage.init(data:)) : NSImage(contentsOf: p.appendingPathComponent("icon.png")) }
        }
        return g
    }

    /// The game pack's file name: the game's name without characters a file name should not have
    var packName: String {
        let clean = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: " -").trimmingCharacters(in: .whitespaces)
        return (clean.isEmpty ? titleID ?? "Game" : clean) + ".nxpack"
    }

    /// Where a new pack of it goes in the game pack folder: its pack there already (made again in place), else its name, with its title ID added when another
    /// game's pack has that name
    func packOutput(in folder: URL, packs: [PackEntry]) -> URL {
        if let p = pack, p.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL { return p }
        let plain = folder.appendingPathComponent(packName)
        guard let tid = titleID, packs.contains(where: { $0.url.lastPathComponent == packName && $0.titleID != tid }) else { return plain }
        return folder.appendingPathComponent(String(packName.dropLast(7)) + " [\(tid)].nxpack")
    }
}

// The control data's names (NX Play's NACP.swift, MIT, the notice in BuildProgress.swift): 16 language entries of name (0x200 bytes) and publisher (0x100 bytes),
// the display version at 0x3060. NX Pocket prefers the entry in the Mac's language (Simplified Chinese is entry 14)
struct NACP {
    let title: String?
    let displayVersion: String?

    init?(contentsOf url: URL) {
        guard let data = try? Data(contentsOf: url), data.count >= 0x3070 else { return nil }
        let bytes = [UInt8](data)
        func string(_ o: Int, _ n: Int) -> String? {
            let field = bytes[o..<o + n], end = field.firstIndex(of: 0) ?? field.endIndex
            let t = String(decoding: bytes[o..<end], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        let lang = AppLanguage.effective   // the app's language (Settings › Language)
        let preferred = lang.hasPrefix("zh-Hans") || lang == "zh-CN" ? [14, 13, 0] : lang.hasPrefix("zh") ? [13, 14, 0] : lang.hasPrefix("ja") ? [2, 0] : lang.hasPrefix("ko") ? [12, 0] : [0, 1]
        title = (preferred + Array(0..<16)).lazy.compactMap { string($0 * 0x300, 0x200) }.first
        displayVersion = string(0x3060, 0x10)
    }
}
