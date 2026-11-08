// The games the launcher's home screen shows (LauncherHome.swift). In a game's own app that is the one game packed into it: its name, version and icon come from the bundle, its title
// ID and settings from dm/launcher.json. In NX Pocket (dm/ios/pocket) it is the game packs the player imported (dm/ios/tools/build_pack.py): each a folder with pack.json, the game's
// signed library and its files, copied into Documents/Games or used where it is through a bookmark (a pack on a drive). Each game keeps its own settings (LauncherModel) and its
// own data folder (Documents/Data/<title ID>: save, log.txt, env.txt).
// LAUNCHER_DEMO (defined only by the launcher preview app, dm/ios/preview) adds made-up entries to show several games; release builds never define it.
import SwiftUI
import UIKit
import Combine

/// The team that signed this app, as iOS will hold libraries to it (library validation): the TeamIdentifier of the provisioning profile inside the app
/// (embedded.mobileprovision, whatever signed it: Xcode, Sideloadly, AltStore, SideStore), else Info.plist's NXPocketTeam (the team it was built for; an app run
/// with no profile, as on a Mac). NX Pocket checks certificates and packs against it
enum AppSigning {
    static let team: String? = profileTeam() ?? (Bundle.main.object(forInfoDictionaryKey: "NXPocketTeam") as? String).flatMap { $0.isEmpty ? nil : $0 }

    /// The profile is a CMS envelope around an XML property list: the list is read from between its <?xml and </plist>
    static func profileTeam(_ url: URL? = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision")) -> String? {
        guard let url, let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)), let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(from: data[start.lowerBound..<end.upperBound], format: nil) as? [String: Any] else { return nil }
        if let teams = plist["TeamIdentifier"] as? [String], let t = teams.first, !t.isEmpty { return t }
        return (plist["Entitlements"] as? [String: Any])?["com.apple.developer.team-identifier"] as? String
    }
}

/// NX Pocket's developer certificate, which signs packs on the phone (PackSigner.swift fills these in; a game's own app has none, and its Settings page shows no certificate)
enum PocketCertificate {
    struct Info { let name, team: String; let expires: Date }
    static var current: (() -> Info?)?
    static var importP12: ((Data, String) throws -> Info)?
    static var remove: (() -> Void)?
}

struct GameEntry: Identifiable, Equatable {
    let titleID: String   // the base game's title ID (dm/games/<id>)
    let name: String
    let version: String
    let icon: UIImage?    // the game's own icon, 256×256 from its control data; the home screen also blurs it into the background
    var lastPlayed: Date?
    let playable: Bool    // Play starts it: the app's own game, or a pack that passed its checks; demo entries are not
    var settings: [Setting] = []   // the game's launcher settings (its dm/launcher.json)
    var pack: GamePack? = nil      // NX Pocket: where the game's pack is
    var id: String { titleID }
    static let none = GameEntry(titleID: "", name: tr("No games yet"), version: "", icon: nil, lastPlayed: nil, playable: false)   // NX Pocket before the first import
    static func == (a: GameEntry, b: GameEntry) -> Bool { a.titleID == b.titleID && a.lastPlayed == b.lastPlayed && a.pack == b.pack }
}

/// An imported game pack: its folder, its pack.json, and whether it was copied in (Documents/Games) or is used in place (bookmark: its data is the bookmark)
struct GamePack: Equatable {
    let url: URL
    let info: PackInfo
    let bookmark: Data?
    var linked: Bool { bookmark != nil }
    var single: Bool { info.format >= 3 }   // one file (PackFile.swift): its parts other than the game files are unpacked into GameLibrary.unpackedFolder
    /// The folder the game starts from (pack.json, Game.framework, dm/, msl/): the pack's own, or a single-file pack's unpacked parts
    var folder: URL { single ? GameLibrary.unpackedFolder(info.titleID) : url }
}

/// pack.json (build_pack.py)
struct PackInfo: Decodable, Equatable {
    let format: Int
    let titleID, name, version: String
    let language: String?
    let shaders: String   // msl/<shaders>: the shader libraries the pack's host loads
    let library: String   // the signed library, from the pack's folder
    let team: String?     // the team that signed it: iOS loads it only into an app signed by the same team
    let romfsInPack: Bool?     // its host reads the game files from a single-file pack (DM_ROMFS_SIZE, hle_fs.c); a format 3 pack needs it
    let archives: [Archive]?   // format 2: folders that travel as one Apple Archive each (msl.aar), unpacked before the game first starts (PackArchive.swift)
    struct Archive: Decodable, Equatable { let file, folder: String; let files: Int? }
    static let format = 3   // the newest format this NX Pocket reads (1: msl/ as a folder; 2: msl.aar; 3: one file, PackFile.swift)
    static var signsHere: () -> Bool = { false }   // NX Pocket: it holds a certificate, so a pack of another team or none is signed at Play (PackSigner.swift)

    /// The checks an import makes, in the order the import dialog lists them; nil = passed
    struct Checks { var files: String?; var signature: String?; var shaders: String?; var passed: Bool { files == nil && signature == nil && shaders == nil } }

    /// Reads and checks a pack folder: its format and files, the team that signed its library, and its shader libraries. A single-file pack: its trailer and table of
    /// contents (whether it came complete) and its pack.json; its files are checked part by part on import (PackFile.verify)
    static func load(_ url: URL) -> (PackInfo?, Checks) {
        var c = Checks()
        let file = PackFile.isFile(url)
        let data: Data?
        if file {
            do { data = try PackFile(url).data("pack.json") } catch { c.files = error.localizedDescription; return (nil, c) }
        } else { data = try? Data(contentsOf: url.appendingPathComponent("pack.json")) }
        guard let data else { c.files = tr("Not a game pack (pack.json is missing)."); return (nil, c) }
        guard let p = try? JSONDecoder().decode(PackInfo.self, from: data) else { c.files = tr("pack.json could not be read."); return (nil, c) }
        let fm = FileManager.default
        if file && p.format < 3 { c.files = tr("pack.json could not be read.") }
        else if file && p.romfsInPack != true { c.files = tr("This game pack's library is too old to read its game data from a single file. Make the pack again with the current tools.") }
        else if p.format < 1 || p.format > format { c.files = String(format: tr("Pack format %d is not supported (this version of NX Pocket supports format %d). Update NX Pocket to play it."), p.format, format) }
        else if p.titleID.count != 16 || p.titleID.contains(where: { !$0.isHexDigit }) { c.files = tr("pack.json does not contain a valid title ID.") }
        else if !file && !fm.fileExists(atPath: url.appendingPathComponent(p.library).path) { c.files = tr("The game library is missing.") }
        else if !file && !fm.fileExists(atPath: url.appendingPathComponent("romfs.img").path) && !fm.fileExists(atPath: url.appendingPathComponent("romfs").path) { c.files = tr("Game data (romfs.img) is missing.") }
        if let mine = AppSigning.team, p.team != mine, !signsHere() {   // NX Pocket signs it on the phone when it holds a certificate (PackSigner.swift)
            c.signature = p.team.map { String(format: tr("Signed by team %@, which differs from NX Pocket (team %@). Import a developer certificate in Settings to re-sign it on this device."), $0, mine) }
                ?? tr("Unsigned. Import a developer certificate in Settings to sign it on this device.")
        }
        if file { return (p, c) }   // the library and the shaders are in its extract.aar
        let shadersPacked = p.archives?.contains { $0.folder == "msl" && fm.fileExists(atPath: url.appendingPathComponent($0.file).path) } ?? false
        let msls = [url, GameLibrary.unpackedFolder(p.titleID)].map { $0.appendingPathComponent("msl") }   // msl/<shaders>/, or msl/<shaders>.img (one file, the host reads either)
        if !shadersPacked && !msls.contains(where: { fm.fileExists(atPath: $0.appendingPathComponent(p.shaders).path) || fm.fileExists(atPath: $0.appendingPathComponent(p.shaders + ".img").path) }) {
            c.shaders = String(format: tr("Shader libraries (msl/%@) are missing."), p.shaders)
        }
        return (p, c)
    }
}

final class GameLibrary: ObservableObject {
    @Published private(set) var games: [GameEntry]
    @Published var selectedID: String
    @Published var runningID: String?   // NX Pocket: the game paused under the home screen (Resume carries on with it)
    @Published var opening: URL?        // NX Pocket: a pack opened from another app (the Files app, AirDrop): the import dialog takes it
    let canImport: Bool   // NX Pocket: Import game pack adds games; a game's own app has only its game

    private let defaults: UserDefaults
    private var models: [String: LauncherModel] = [:]
    private var watching: [String: AnyCancellable] = [:]
    private static func playedKey(_ id: String) -> String { "library.lastPlayed." + id }

    init(_ games: [GameEntry], canImport: Bool = false, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.canImport = canImport
        let list = games.map { var g = $0; g.lastPlayed = defaults.object(forKey: Self.playedKey(g.titleID)) as? Date ?? g.lastPlayed; return g }
        self.games = list
        selectedID = games.first?.titleID ?? ""   // the app's own game first (embedded); NX Pocket picks the last played (reload)
    }

    var selected: GameEntry { games.first { $0.titleID == selectedID } ?? games.first ?? GameEntry.none }

    /// The selected game's settings, kept per game: the app's own game in the app's preferences (as before NX Pocket), a pack's in a preferences file of its own
    var model: LauncherModel { model(for: selected) }
    func model(for g: GameEntry) -> LauncherModel {
        if let m = models[g.titleID] { return m }
        let m = LauncherModel(g.settings, defaults: g.pack == nil ? defaults : (UserDefaults(suiteName: "game." + g.titleID) ?? defaults))
        models[g.titleID] = m
        watching[g.titleID] = m.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }   // the home screen's local-play pill follows the settings
        return m
    }

    /// Removes a pack from NX Pocket (GameLibrary.remove) and the list
    func remove(_ id: String) {
        Self.remove(titleID: id, defaults: defaults)
        reload()
    }

    // At Play: the game's last-played time, shown under its name from then on
    func markPlayed(_ id: String, at now: Date = Date()) {
        defaults.set(now, forKey: Self.playedKey(id))
        if let i = games.firstIndex(where: { $0.titleID == id }) { games[i].lastPlayed = now }
    }

    // The game packed into this app (title ID: launcher.json's "game", else DMTitleID; the bundle's display name, version and icon)
    static func embedded(titleID: String?, settings: [Setting]) -> GameLibrary {
        let info = Bundle.main.infoDictionary ?? [:]
        let game = GameEntry(titleID: titleID ?? (info["DMTitleID"] as? String) ?? "0000000000000000",
                             name: (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? tr("Game"),
                             version: (info["CFBundleShortVersionString"] as? String) ?? "",
                             icon: appIcon(info), lastPlayed: nil, playable: true, settings: settings)
#if LAUNCHER_DEMO
        return GameLibrary([game] + demoGames())
#else
        return GameLibrary([game])
#endif
    }

    private static func appIcon(_ info: [String: Any]) -> UIImage? {
        if let i = UIImage(named: "AppIcon") { return i }
        guard let icons = info["CFBundleIcons"] as? [String: Any], let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
              let files = primary["CFBundleIconFiles"] as? [String], let last = files.last else { return nil }
        return UIImage(named: last)
    }

    // MARK: - NX Pocket's packs

    static var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    static var packsFolder: URL { documents.appendingPathComponent("Games", isDirectory: true) }   // copied packs; the Files app shows it (UIFileSharingEnabled), so a pack can be dropped in from a Mac too
    /// Where a pack used in place has its archives unpacked (its own folder may not be writable)
    static func unpackedFolder(_ titleID: String) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Unpacked/\(titleID)", isDirectory: true)
    }
    /// Whether the pack has an archive still to unpack before its game starts
    static func needsUnpacking(_ pack: GamePack) -> Bool {
        if pack.single { return !FileManager.default.fileExists(atPath: pack.folder.appendingPathComponent(".unpacked").path) }   // written once every archive is out
        return (pack.info.archives ?? []).contains { a in
            !FileManager.default.fileExists(atPath: (pack.linked ? unpackedFolder(pack.info.titleID) : pack.url).appendingPathComponent(a.folder).path)
        }
    }
    /// Unpacks the pack's archives (format 2) once: a copied pack's into its own folder, the archive then deleted (no second copy of the data); a pack used in place's
    /// into unpackedFolder. Returns the shader folder to give the game when it is not the pack's own (DM_MSL_DIR, main.m), else nil. Slow the first time: off the main thread.
    /// `progress` (any thread) gets how far it is over all the archives still to unpack, 0…1, by their sizes
    static func unpack(_ pack: GamePack, progress: ((Double) -> Void)? = nil, checked: Bool = false) throws -> URL? {
        let base = pack.linked ? unpackedFolder(pack.info.titleID) : pack.url, fm = FileManager.default
        if pack.single {   // its archives, out of the pack file into its own folder: extract.aar into it, then msl.aar into its msl/
            guard needsUnpacking(pack) else { return nil }
            let f = try PackFile(pack.url)
            // a pack that did not come through the import (copied into Documents/Games from a Mac over the cable) gets the quick check here, before its first start
            if !checked { try f.quickCheck(); fputs("pocket: \(pack.info.name): quick check passed\n", stderr) }
            let archives = f.archives
            guard !archives.isEmpty else { throw PackFile.Failure.unreadable("extract.aar") }
            let t0 = Date(), folder = pack.folder, total = Double(max(archives.reduce(0) { $0 + $1.size }, 1))
            try? fm.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
            var before = 0.0
            for a in archives {
                let into = (a.folder ?? "").isEmpty ? folder : folder.appendingPathComponent(a.folder!, isDirectory: true), done = before
                let n = try PackArchive.unpack(pack.url, range: a.offset..<a.offset + a.size, into: into, progress: progress.map { p in { x in p((done + x * Double(a.size)) / total) } })
                before += Double(a.size)
                fputs(String(format: "pocket: unpacked %@'s %@ (%d entries) in %.1f s\n", pack.info.name, a.name, n, Date().timeIntervalSince(t0)), stderr)
            }
            FileManager.default.createFile(atPath: folder.appendingPathComponent(".unpacked").path, contents: Data())
            var r = URLResourceValues(); r.isExcludedFromBackup = true; var d = folder; try? d.setResourceValues(r)
            return nil
        }
        let todo = (pack.info.archives ?? []).filter { !fm.fileExists(atPath: base.appendingPathComponent($0.folder).path) }
        let sizes = todo.map { Double((try? fm.attributesOfItem(atPath: pack.url.appendingPathComponent($0.file).path)[.size] as? Int64) ?? 0) }
        let total = max(sizes.reduce(0, +), 1)
        var before = 0.0
        for (i, a) in todo.enumerated() {
            let folder = base.appendingPathComponent(a.folder, isDirectory: true), archive = pack.url.appendingPathComponent(a.file)
            let t0 = Date(), done = before
            let n = try PackArchive.unpack(archive, into: folder, progress: progress.map { p in { f in p((done + f * sizes[i]) / total) } })
            before += sizes[i]
            fputs(String(format: "pocket: unpacked %@ (%d entries) in %.1f s\n", a.file, n, Date().timeIntervalSince(t0)), stderr)
            if !pack.linked { try? fm.removeItem(at: archive) }
            var r = URLResourceValues(); r.isExcludedFromBackup = true; var f = folder; try? f.setResourceValues(r)
        }
        guard pack.linked, pack.info.archives?.contains(where: { $0.folder == "msl" }) == true else { return nil }
        return base.appendingPathComponent("msl", isDirectory: true)
    }

    static func dataFolder(_ titleID: String) -> URL { documents.appendingPathComponent("Data", isDirectory: true).appendingPathComponent(titleID, isDirectory: true) }
    private static let linkedKey = "pocket.linkedPacks"   // bookmarks of the packs used in place

    /// NX Pocket's library: every pack in Documents/Games and every linked pack that can still be reached
    static func pocket() -> GameLibrary {
        let lib = GameLibrary([], canImport: true)
        lib.reload()
        return lib
    }

    func reload() {
        var found: [String: GameEntry] = [:]
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.packsFolder, withIntermediateDirectories: true)
        for url in (try? fm.contentsOfDirectory(at: Self.packsFolder, includingPropertiesForKeys: nil)) ?? [] where url.pathExtension == "nxpack" {
            if let g = Self.entry(url, bookmark: nil) { found[g.titleID] = g }
        }
        var keep: [Data] = []
        for b in (defaults.array(forKey: Self.linkedKey) as? [Data]) ?? [] {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: b, bookmarkDataIsStale: &stale) else { fputs("pocket: a linked pack can no longer be found; forgotten\n", stderr); continue }
            let ok = url.startAccessingSecurityScopedResource(); defer { if ok { url.stopAccessingSecurityScopedResource() } }
            let mark = stale ? ((try? url.bookmarkData()) ?? b) : b
            keep.append(mark)
            if let g = Self.entry(url, bookmark: mark), found[g.titleID] == nil { found[g.titleID] = g }
        }
        defaults.set(keep, forKey: Self.linkedKey)
        var list = found.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        for i in list.indices { list[i].lastPlayed = defaults.object(forKey: Self.playedKey(list[i].titleID)) as? Date }
#if LAUNCHER_DEMO
        list += Self.demoGames().filter { d in !list.contains { $0.titleID == d.titleID } }   // the preview shows several games to scroll through
#endif
        games = list
        for id in Array(models.keys) where !list.contains(where: { $0.titleID == id }) { models[id] = nil; watching[id] = nil }
        if selectedID.isEmpty || !list.contains(where: { $0.titleID == selectedID }) { selectedID = list.max { ($0.lastPlayed ?? .distantPast) < ($1.lastPlayed ?? .distantPast) }?.titleID ?? "" }
        fputs("pocket: \(list.count) game pack(s)\n", stderr)
    }

    private static func entry(_ url: URL, bookmark: Data?) -> GameEntry? {
        let (info, checks) = PackInfo.load(url)
        guard let info else { fputs("pocket: \(url.lastPathComponent): \(checks.files ?? "not a pack")\n", stderr); return nil }
        if !checks.passed { fputs("pocket: \(url.lastPathComponent): \([checks.files, checks.signature, checks.shaders].compactMap { $0 }.joined(separator: "; "))\n", stderr) }
        let pack = GamePack(url: url, info: info, bookmark: bookmark)
        let settings = (try? Data(contentsOf: pack.folder.appendingPathComponent("dm/launcher.json"))).flatMap { try? JSONDecoder().decode(SettingsFile.self, from: $0) }?.settings ?? []
        // icon@4x.png (1024×1024, made from the game's 256 icon on the Mac: build_pack.py) for the large tile, else the icon as it is
        let file = pack.single ? try? PackFile(url) : nil
        let icon = pack.single ? (file?.data("icon@4x.png") ?? file?.data("icon.png")).flatMap(UIImage.init(data:))
            : UIImage(contentsOfFile: url.appendingPathComponent("icon@4x.png").path) ?? UIImage(contentsOfFile: url.appendingPathComponent("icon.png").path)
        return GameEntry(titleID: info.titleID, name: info.name, version: info.version, icon: icon, lastPlayed: nil, playable: checks.passed, settings: settings,
                         pack: pack)
    }

    enum ImportError: LocalizedError {
        case checks(PackInfo.Checks), copy(String), cancelled
        var errorDescription: String? {
            switch self {
            case .checks(let c): return [c.files, c.signature, c.shaders].compactMap { $0 }.joined(separator: "\n")
            case .copy(let s): return s
            case .cancelled: return tr("Copy cancelled. Nothing was imported.")
            }
        }
    }

    /// Where a picked pack is: already among NX Pocket's games, elsewhere in NX Pocket's own Documents (put there through the Finder or the Files app), or outside them
    enum Location { case games, documents, elsewhere }
    static func location(_ url: URL) -> Location {
        let p = url.standardizedFileURL.resolvingSymlinksInPath().path, games = packsFolder.standardizedFileURL.resolvingSymlinksInPath().path
        let docs = documents.standardizedFileURL.resolvingSymlinksInPath().path
        if p.hasPrefix(games + "/") { return .games }
        return p.hasPrefix(docs + "/") ? .documents : .elsewhere
    }

    /// How an import treats the pack: kept where it is in NX Pocket's Documents (moved into Documents/Games when it is elsewhere there: the same volume, no second copy),
    /// linked where it is outside them (a bookmark), or copied into Documents/Games
    enum ImportMode { case inside, link, copy }

    /// A copy in progress: what has been copied of the total, and whether the player cancelled it (checked between files and between blocks of a large one)
    final class CopyProgress: @unchecked Sendable {
        private let lock = NSLock()
        private var _done: Int64 = 0, _total: Int64 = 0, _cancelled = false, _stage: String?
        var done: Int64 { lock.withLock { _done } }
        var stage: String? { lock.withLock { _stage } }   // what is being done (a single-file pack: copying, checking, unpacking), nil: the copy
        var total: Int64 { lock.withLock { _total } }
        var cancelled: Bool { lock.withLock { _cancelled } }
        var fraction: Double { let t = total; return t > 0 ? min(Double(done) / Double(t), 1) : 0 }
        func cancel() { lock.withLock { _cancelled = true } }
        fileprivate func setTotal(_ t: Int64) { lock.withLock { _total = t } }
        fileprivate func begin(_ stage: String, total: Int64) { lock.withLock { _stage = stage; _done = 0; _total = total } }
        fileprivate func set(_ d: Int64) { lock.withLock { _done = d } }
        fileprivate func add(_ n: Int64) { lock.withLock { _done += n } }
    }

    /// Copies a pack folder file by file, cloned where the volume allows (instant, no space taken) and else in blocks of 8 MiB, so that it can stop: throws
    /// CancellationError once progress is cancelled
    static func copyTree(_ src: URL, to dst: URL, progress: CopyProgress) throws {
        let fm = FileManager.default, keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
        var items: [(URL, Bool, Int64)] = []
        if PackFile.isFile(src) {   // a single-file pack: the file itself
            let size = Int64((try? src.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            progress.setTotal(size)
            try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            try copyFile(src, to: dst, size: size, progress: progress)
            return
        }
        if let e = fm.enumerator(at: src, includingPropertiesForKeys: keys) {
            for case let u as URL in e {
                let v = try? u.resourceValues(forKeys: Set(keys))
                items.append((u, v?.isDirectory ?? false, Int64(v?.fileSize ?? 0)))
            }
        }
        progress.setTotal(items.reduce(0) { $0 + $1.2 })
        try fm.createDirectory(at: dst, withIntermediateDirectories: true)
        let base = src.standardizedFileURL.path.count + 1
        for (u, dir, size) in items {
            if progress.cancelled { throw CancellationError() }
            let to = dst.appendingPathComponent(String(u.standardizedFileURL.path.dropFirst(base)))
            if dir { try fm.createDirectory(at: to, withIntermediateDirectories: true); continue }
            try copyFile(u, to: to, size: size, progress: progress)
        }
    }
    private static func copyFile(_ u: URL, to: URL, size: Int64, progress: CopyProgress) throws {
        if clonefile(u.path, to.path, 0) == 0 { progress.add(size); return }
        guard let r = try? FileHandle(forReadingFrom: u) else { throw ImportError.copy(String(format: tr("%@ could not be read."), u.lastPathComponent)) }
        defer { try? r.close() }
        FileManager.default.createFile(atPath: to.path, contents: nil)
        guard let w = try? FileHandle(forWritingTo: to) else { throw ImportError.copy(String(format: tr("%@ could not be written."), to.lastPathComponent)) }
        defer { try? w.close() }
        while true {
            if progress.cancelled { throw CancellationError() }
            let chunk = try r.read(upToCount: 8 << 20) ?? Data()
            if chunk.isEmpty { break }
            try w.write(contentsOf: chunk); progress.add(Int64(chunk.count))
        }
    }

    /// iCloud Drive: whether any of the pack's files is only a placeholder (not yet on this device); with start, asks iCloud to download them
    @discardableResult static func waitingForICloud(_ url: URL, start: Bool = false) -> Bool {
        let fm = FileManager.default
        guard (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true else { return false }
        var pending = false
        let items: [URL] = PackFile.isFile(url) || (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory != true ? [url]
            : ((fm.enumerator(at: url, includingPropertiesForKeys: [.ubiquitousItemDownloadingStatusKey])?.allObjects as? [URL]) ?? [])
        for u in items {
            let st = (try? u.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?.ubiquitousItemDownloadingStatus
            if let st, st != .current {
                pending = true
                if start { try? fm.startDownloadingUbiquitousItem(at: u) } else { break }
            }
        }
        return pending
    }

    /// Imports the pack at url (picked in Files). A pack of the same game already there is replaced once the new one is in place (a copy that fails or is cancelled
    /// leaves the old one). Runs off the main thread; returns the game's title ID
    static func importPack(_ url: URL, mode: ImportMode, progress: CopyProgress? = nil, defaults: UserDefaults = .standard) throws -> String {
        let ok = url.startAccessingSecurityScopedResource(); defer { if ok { url.stopAccessingSecurityScopedResource() } }
        let (info, checks) = PackInfo.load(url)
        guard let info, checks.passed else { throw ImportError.checks(checks) }
        if info.format >= 3 { return try importFile(url, info: info, mode: mode, progress: progress ?? CopyProgress(), defaults: defaults) }
        let fm = FileManager.default
        try? fm.createDirectory(at: packsFolder, withIntermediateDirectories: true)
        let dest = packsFolder.appendingPathComponent(info.titleID + ".nxpack", isDirectory: true)
        switch mode {
        case .inside:
            if location(url) == .games {   // already one of the games: forget any other pack of this game, keep this one
                removeOthers(titleID: info.titleID, keeping: url, defaults: defaults)
            } else {
                let part = packsFolder.appendingPathComponent(info.titleID + ".nxpack.partial", isDirectory: true)
                try? fm.removeItem(at: part)
                do { try fm.moveItem(at: url, to: part) } catch { throw ImportError.copy(error.localizedDescription) }   // one volume: a rename
                remove(titleID: info.titleID, defaults: defaults)
                try fm.moveItem(at: part, to: dest)
            }
        case .copy:
            let part = packsFolder.appendingPathComponent(info.titleID + ".nxpack.partial", isDirectory: true)
            try? fm.removeItem(at: part)
            do { try copyTree(url, to: part, progress: progress ?? CopyProgress()) }
            catch is CancellationError { try? fm.removeItem(at: part); throw ImportError.cancelled }
            catch { try? fm.removeItem(at: part); throw ImportError.copy(error.localizedDescription) }
            remove(titleID: info.titleID, defaults: defaults)
            do { try fm.moveItem(at: part, to: dest) } catch { try? fm.removeItem(at: part); throw ImportError.copy(error.localizedDescription) }
            var r = URLResourceValues(); r.isExcludedFromBackup = true; var d = dest; try? d.setResourceValues(r)   // many GB of game files stay out of device backups (as main.m does for romfs.img)
        case .link:
            let mark: Data
            do { mark = try url.bookmarkData() } catch { throw ImportError.copy(error.localizedDescription) }
            remove(titleID: info.titleID, defaults: defaults)
            defaults.set(((defaults.array(forKey: linkedKey) as? [Data]) ?? []) + [mark], forKey: linkedKey)
            waitingForICloud(url, start: true)   // an iCloud Drive pack: its files come down in the background
        }
        fputs("pocket: imported \(info.name) (\(info.titleID)) \(mode == .copy ? "as a copy" : mode == .link ? "in place (linked)" : "in place (Documents)")\n", stderr)
        return info.titleID
    }

    /// A single-file pack's import: every part checked against its table (the copy kept, for a copy), the pack moved into Documents/Games, copied or linked as a folder
    /// pack is, then its parts other than the game files unpacked (the game files stay in the file). A pack cut off or damaged is refused and nothing is kept
    private static func importFile(_ url: URL, info: PackInfo, mode: ImportMode, progress: CopyProgress, defaults: UserDefaults) throws -> String {
        let fm = FileManager.default
        try? fm.createDirectory(at: packsFolder, withIntermediateDirectories: true)
        let dest = packsFolder.appendingPathComponent(info.titleID + ".nxpack"), part = packsFolder.appendingPathComponent(info.titleID + ".nxpack.partial")
        // the full check when every chunk has its checksum, else the quick one (the import dialog says so)
        func check(_ u: URL) throws {
            let f = try PackFile(u)
            do {
                if f.fullyHashed {
                    progress.begin(String(format: tr("Checking %@…"), info.name), total: f.length)
                    try f.verify(progress: { d, _ in progress.set(d) }, cancelled: { progress.cancelled })
                } else {
                    progress.begin(String(format: tr("Quick check of %@…"), info.name), total: 1000)
                    try f.quickCheck(progress: { d, t in progress.set(t > 0 ? d * 1000 / t : 0) }, cancelled: { progress.cancelled })
                }
            } catch is CancellationError { throw ImportError.cancelled }
        }
        var kept = url
        switch mode {
        case .inside:
            try check(url)
            if location(url) == .games { removeOthers(titleID: info.titleID, keeping: url, defaults: defaults) }
            else {
                try? fm.removeItem(at: part)
                do { try fm.moveItem(at: url, to: part) } catch { throw ImportError.copy(error.localizedDescription) }   // one volume: a rename
                remove(titleID: info.titleID, defaults: defaults)
                try fm.moveItem(at: part, to: dest); kept = dest
            }
        case .copy:
            try? fm.removeItem(at: part)
            progress.begin(String(format: tr("Copying %@…"), info.name), total: 0)
            do { try copyTree(url, to: part, progress: progress); try check(part) }
            catch is CancellationError { try? fm.removeItem(at: part); throw ImportError.cancelled }
            catch { try? fm.removeItem(at: part); throw error }
            remove(titleID: info.titleID, defaults: defaults)
            do { try fm.moveItem(at: part, to: dest) } catch { try? fm.removeItem(at: part); throw ImportError.copy(error.localizedDescription) }
            var r = URLResourceValues(); r.isExcludedFromBackup = true; var d = dest; try? d.setResourceValues(r)
            kept = dest
        case .link:
            try check(url)
            let mark: Data
            do { mark = try url.bookmarkData() } catch { throw ImportError.copy(error.localizedDescription) }
            remove(titleID: info.titleID, defaults: defaults)
            defaults.set(((defaults.array(forKey: linkedKey) as? [Data]) ?? []) + [mark], forKey: linkedKey)
        }
        // its other parts, unpacked now so the game starts at once (a failure here leaves the pack in place; Play unpacks it again)
        try? fm.removeItem(at: unpackedFolder(info.titleID))
        let pack = GamePack(url: kept, info: info, bookmark: mode == .link ? Data() : nil)
        progress.begin(String(format: tr("Unpacking %@…"), info.name), total: 1000)
        do { _ = try unpack(pack, progress: { f in progress.set(Int64(f * 1000)) }, checked: true) }
        catch { fputs("[RED] pocket: \(info.name): unpacking failed: \(error.localizedDescription)\n", stderr) }
        fputs("pocket: imported \(info.name) (\(info.titleID)), one file, \(mode == .copy ? "as a copy" : mode == .link ? "in place (linked)" : "in place (Documents)")\n", stderr)
        return info.titleID
    }

    /// Forgets every other pack of a game (other folders in Documents/Games, links), keeping the one at `keeping`
    private static func removeOthers(titleID: String, keeping: URL, defaults: UserDefaults) {
        let fm = FileManager.default, keep = keeping.standardizedFileURL.resolvingSymlinksInPath().path
        for u in (try? fm.contentsOfDirectory(at: packsFolder, includingPropertiesForKeys: nil)) ?? [] where u.pathExtension == "nxpack" {
            if u.standardizedFileURL.resolvingSymlinksInPath().path != keep, PackInfo.load(u).0?.titleID == titleID { try? fm.removeItem(at: u) }
        }
        let marks = (defaults.array(forKey: linkedKey) as? [Data]) ?? []
        defaults.set(marks.filter { b in
            var stale = false
            guard let u = try? URL(resolvingBookmarkData: b, bookmarkDataIsStale: &stale) else { return false }
            let ok = u.startAccessingSecurityScopedResource(); defer { if ok { u.stopAccessingSecurityScopedResource() } }
            return PackInfo.load(u).0?.titleID != titleID
        }, forKey: linkedKey)
    }

    /// Removes a game's pack: the copied folder, or the link to it (the pack itself stays where it is). Its saves and settings stay
    static func remove(titleID: String, defaults: UserDefaults = .standard) {
        let fm = FileManager.default
        try? fm.removeItem(at: packsFolder.appendingPathComponent(titleID + ".nxpack"))
        try? fm.removeItem(at: fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("SignedPacks/\(titleID)"))   // its library signed here
        try? fm.removeItem(at: unpackedFolder(titleID))   // and its archives unpacked here
        for url in (try? fm.contentsOfDirectory(at: packsFolder, includingPropertiesForKeys: nil)) ?? [] where url.pathExtension == "nxpack" {
            if PackInfo.load(url).0?.titleID == titleID { try? fm.removeItem(at: url) }
        }
        let marks = (defaults.array(forKey: linkedKey) as? [Data]) ?? []
        defaults.set(marks.filter { b in
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: b, bookmarkDataIsStale: &stale) else { return false }
            let ok = url.startAccessingSecurityScopedResource(); defer { if ok { url.stopAccessingSecurityScopedResource() } }
            return PackInfo.load(url).0?.titleID != titleID
        }, forKey: linkedKey)
    }

#if LAUNCHER_DEMO
    // Made-up entries to see several games on the home screen. Their icons are demo/<title ID>.png in the preview app when the preview tool found one on this Mac
    // (dm/ios/tools/launcher_preview.py; game art is never committed), else a plain colour with the name's first letter
    static func demoGames() -> [GameEntry] {
        let now = Date()
        let demo: [(String, String, String, Double, UIColor)] = [
            ("01006A800016E000", "Super Smash Bros. Ultimate", "13.0.4", -3600 * 26, .systemRed),
            ("01009B90006DC000", "Super Mario Maker 2", "3.0.3", -3600 * 24 * 5, .systemOrange),
            ("0100D9F01D474000", "Rhythm Heaven Groove", "1.0.0", 0, .systemPurple),
        ]
        // DM_PREVIEW_GAMES=<n>: n games in all (the real one and n - 1 made up), to see the row with few games or many
        let extra: [(String, String, String, Double, UIColor)] = (0..<12).map { ("01000000DE00\(String(format: "%02d", $0))00", "Demo Game \($0 + 4)", "1.0", 0, [.systemBlue, .systemGreen, .systemTeal, .systemPink][$0 % 4]) }
        let count = Int(ProcessInfo.processInfo.environment["DM_PREVIEW_GAMES"] ?? "").map { max($0 - 1, 0) } ?? demo.count
        return Array((demo + extra).prefix(count)).map { id, name, version, ago, color in
            let file = Bundle.main.url(forResource: id, withExtension: "png", subdirectory: "demo")
            return GameEntry(titleID: id, name: name, version: version, icon: file.flatMap { UIImage(contentsOfFile: $0.path) } ?? placeholder(name, color),
                             lastPlayed: ago == 0 ? nil : now.addingTimeInterval(ago), playable: false)
        }
    }

    private static func placeholder(_ name: String, _ color: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 256, height: 256)).image { c in
            color.setFill(); c.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
            let text = String(name.prefix(1)) as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 120, weight: .bold), .foregroundColor: UIColor.white]
            let size = text.size(withAttributes: attrs)
            text.draw(at: CGPoint(x: (256 - size.width) / 2, y: (256 - size.height) / 2), withAttributes: attrs)
        }
    }
#endif
}
