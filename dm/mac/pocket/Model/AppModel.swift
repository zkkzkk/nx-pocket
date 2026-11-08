// NX Pocket for Mac's state: its settings (the nxnative checkout, the Python, the player's prod.keys path, how packs are signed, NX Pocket's bundle ID on the
// iPhone), the games (folders the player added), the builds and sends in progress, the iPhones in reach.
import AppKit
import Combine

/// Making a game's pack: the NSP script prepares the game (extract, rewrite, shaders, the Xcode project), then build_pack.py builds and packs it. Or its Mac version
/// (kind .mac): the NSP script alone, --platform mac-app. Its stages are the scripts' own (`--progress json`)
@MainActor final class PackBuild: ObservableObject {
    enum State: Equatable { case running, done, failed, cancelled }
    enum Kind: Equatable { case pack, mac }
    let kind: Kind
    @Published private(set) var phase = 1          // 1: prepare the game, 2: make the pack
    @Published private(set) var state: State = .running
    @Published private(set) var current: ToolRun
    private(set) var runs: [ToolRun] = []
    private var bag: [AnyCancellable] = []
    private let next: () -> (String, [String], [String: String])?

    init(kind: Kind = .pack, prepare: (String, [String], [String: String]), then next: @escaping () -> (String, [String], [String: String])?) {
        self.kind = kind; self.next = next
        current = ToolRun(title: kind == .mac ? tr("Make the Mac version") : tr("Prepare the game"))
        start(current, prepare)
    }

    var log: [String] { runs.flatMap(\.log) }
    var problems: [String] { runs.flatMap(\.problems) }
    /// Both steps as one bar: preparing is most of the time (extraction, the shaders), making the pack the rest
    var fraction: Double {
        let f = current.progress?.fraction ?? 0
        return state == .done ? 1 : kind == .mac ? f : phase == 1 ? f * 0.85 : 0.85 + f * 0.15
    }

    func stop() { current.stop() }

    private func start(_ run: ToolRun, _ cmd: (String, [String], [String: String])) {
        runs.append(run)
        run.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        run.onFinish = { [weak self] r in
            guard let self else { return }
            switch r.status {
            case .succeeded:
                if self.phase == 1, let cmd = self.next() {
                    self.phase = 2
                    let pack = ToolRun(title: tr("Make the game pack"))
                    self.current = pack
                    self.start(pack, cmd)
                } else { self.state = .done }
            case .cancelled: self.state = .cancelled
            default: self.state = .failed
            }
        }
        run.start(cmd.0, cmd.1, environment: cmd.2)
    }
}

@MainActor final class AppModel: ObservableObject {
    // MARK: settings
    private let d = UserDefaults.standard
    @Published var repo: String { didSet { d.set(repo, forKey: "repo") } }
    @Published var python: String { didSet { d.set(python, forKey: "python") } }
    @Published var keys: String { didSet { d.set(keys, forKey: "keys") } }
    @Published var team: String { didSet { d.set(team, forKey: "team") } }                    // signs packs on the Mac; empty: unsigned, NX Pocket signs them on the phone
    @Published var bundleID: String { didSet { d.set(bundleID, forKey: "bundleID") } }       // NX Pocket's on the iPhone; empty: found by its name
    @Published var setupDone: Bool { didSet { d.set(setupDone, forKey: "setupDone") } }
    @Published var envScript: String { didSet { d.set(envScript, forKey: "envScript") } }   // sourced before every tool (ToolEnvironment)
    @Published var pocketTeam: String { didSet { d.set(pocketTeam, forKey: "pocketTeam") } }   // the team Install NX Pocket signs it with (build_pocket.py --team)
    @Published var fullVerify: Bool { didSet { d.set(fullVerify, forKey: "fullVerify") } }     // every chunk's checksum in the pack (build_pack.py --verify full)
    @Published var packsFolder: String { didSet { d.set(packsFolder, forKey: "packsFolder"); if oldValue != packsFolder { rescan() } } }   // where game packs are made and found

    // MARK: state
    let updater = Updater()     // NX Pocket for Mac's own updates (its GitHub releases)
    let upstream = Upstream()   // the checkout against upstream nxnative
    @Published var games: [MacGame] = []
    @Published var selection: MacGame.ID?
    @Published var builds: [MacGame.ID: PackBuild] = [:]
    @Published var sends: [MacGame.ID: PackSender] = [:]
    @Published var devices: [Device] = []
    @Published var showLog = false
    @Published var setup: [SetupItem] = []
    @Published var setupRun: ToolRun?
    private var exporting: ToolRun?
    private var bag: [AnyCancellable] = []

    init() {
        repo = d.string(forKey: "repo") ?? ""
        python = d.string(forKey: "python") ?? ""
        keys = d.string(forKey: "keys") ?? ""
        team = d.string(forKey: "team") ?? ""
        bundleID = d.string(forKey: "bundleID") ?? ""
        setupDone = d.bool(forKey: "setupDone")
        envScript = d.string(forKey: "envScript") ?? ""
        pocketTeam = d.string(forKey: "pocketTeam") ?? ""
        fullVerify = d.bool(forKey: "fullVerify")
        packsFolder = d.string(forKey: "packsFolder") ?? ""
        targetID = d.string(forKey: "targetDevice")
        if repo.isEmpty, let found = Self.findRepo() { repo = found }
        if python.isEmpty { python = Setup.guessPython(repo: repo) }
        games = (d.stringArray(forKey: "games") ?? []).map { MacGame(folder: URL(fileURLWithPath: $0), name: URL(fileURLWithPath: $0).lastPathComponent) }   // their names until scanned
        selection = games.first?.id
        settlePacksFolder()
        rescan(then: { [weak self] g in self?.readControl(g) })
    }

    /// The game pack folder until the player chooses one: "NX Pocket Game Packs" beside the folder the first game's folder is in (games/<game> → NX Pocket Game Packs
    /// beside games/), one already there in either language first; kept once set, so the language does not move it
    static let packsFolderNames = ["NX Pocket 游戏包", "NX Pocket Game Packs"]
    func settlePacksFolder() {
        guard packsFolder.isEmpty, let g = games.first else { return }
        let base = g.folder.deletingLastPathComponent().deletingLastPathComponent()
        let names = Self.packsFolderNames
        let existing = names.first { FileManager.default.fileExists(atPath: base.appendingPathComponent($0).path) }
        packsFolder = base.appendingPathComponent(existing ?? (launcherChinese ? names[0] : names[1])).path
    }
    var packsURL: URL? { packsFolder.isEmpty ? nil : URL(fileURLWithPath: packsFolder, isDirectory: true) }

    var selected: MacGame? { games.first { $0.id == selection } }

    /// What nxnative's profiles say of a game (GameSupport), read once per title ID
    private var supportCache: [String: GameSupport] = [:]
    func support(_ g: MacGame) -> GameSupport {
        let key = (g.titleID ?? "") + "|" + repo
        if let s = supportCache[key] { return s }
        let s = GameSupport.of(g.titleID, repo: repo); supportCache[key] = s; return s
    }

    /// A game's name, version and icon read from its packages before anything is built (build_ipa_from_nsp.py --control-only: the control data only, into
    /// <title ID>_build/control), for a game that shows neither yet
    private var reading: [MacGame.ID: ToolRun] = [:]   // kept until they end (a run holds itself only weakly)
    func readControl(_ g: MacGame) {
        if case .nup(let u) = g.switch2, g.titleID == nil { readNUPTitle(g, u); return }
        guard g.switch2 == nil, canBuild(g), g.icon == nil, !g.files.isEmpty, reading[g.id] == nil else { return }   // a Switch 2 game's control data, when it has any, comes with its build
        let r = ToolRun(title: tr("Read game name and icon"))
        let id = g.id
        reading[id] = r
        r.onFinish = { [weak self] _ in self?.reading[id] = nil; self?.rescan(id) }
        r.start(python, [(repo as NSString).appendingPathComponent("scripts/build_ipa_from_nsp.py"), g.folder.path, "--control-only", "-k", keys])
    }
    /// A NUP's title ID (pack_nup.py's scan: the program ID of its code), kept per file (Switch2Source.nupTitles), so its profile shows before anything is built
    func readNUPTitle(_ g: MacGame, _ nup: URL) {
        guard !repo.isEmpty, !python.isEmpty, reading[g.id] == nil else { return }
        let r = ToolRun(title: tr("Read game name and icon"))
        let (id, key) = (g.id, Switch2Source.key(nup))
        reading[id] = r
        r.onFinish = { [weak self] r in
            self?.reading[id] = nil
            if let t = r.log.compactMap({ $0.firstMatch(of: /^title ([0-9A-F]{16})$/).map { String($0.1) } }).last { Switch2Source.nupTitles[key] = t; self?.rescan(id) }
        }
        let code = "import sys; sys.path.insert(0, sys.argv[1]); import pack_nup; print('title %016X' % pack_nup.scan(pack_nup.Nup(sys.argv[2]))[0])"
        r.start(python, ["-c", code, (repo as NSString).appendingPathComponent("scripts"), nup.path])
    }
    /// The iPhone packs go to: the one chosen in the sidebar while it is connected, else the first connected
    var connected: Device? { devices.first { $0.connected && $0.id == targetID } ?? devices.first { $0.connected } }
    @Published var targetID: String? { didSet { d.set(targetID, forKey: "targetDevice") } }

    /// The checkout this app was built from, when it was built inside one (dm/mac/pocket in a repository)
    static func findRepo() -> String? {
        var u = Bundle.main.bundleURL
        for _ in 0..<8 {
            u = u.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: u.appendingPathComponent("scripts/build_ipa_from_nsp.py").path) { return u.path }
        }
        return nil
    }

    // MARK: games

    /// Adds dropped or chosen items: a folder is a game; files of a game (NSP and the like) add the folder they are in
    func add(_ urls: [URL]) {
        var folders: [URL] = []
        for u in urls {
            var dir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: u.path, isDirectory: &dir) else { continue }
            // a folder or file inside a Switch 2 dump (its base/, updates/ or dlc/) adds the dump
            let f = Switch2Source.dumpFolder(containing: u) ?? (dir.boolValue && u.pathExtension != "nxpack" ? u : u.deletingLastPathComponent())
            if !folders.contains(f) { folders.append(f) }
        }
        for f in folders where !games.contains(where: { $0.folder == f }) {
            games.append(MacGame(folder: f, name: f.lastPathComponent))
            rescan(f.path, then: { [weak self] g in self?.readControl(g) })
        }
        if let f = folders.last { selection = f.path }
        settlePacksFolder()
        save()
    }
    func remove(_ g: MacGame) {
        games.removeAll { $0.id == g.id }
        if selection == g.id { selection = games.first?.id }
        save()
    }
    /// Reads the games' folders again off the main thread (a drive busy with a build can take seconds to list a folder), then `then` for each
    func rescan(_ id: MacGame.ID? = nil, then: ((MacGame) -> Void)? = nil) {
        let folders = games.filter { id == nil || $0.id == id }.map(\.folder), packs = packsURL, repo = repo
        Task {
            let scanned = await Task.detached { let index = PackEntry.index(packs); return folders.map { MacGame.scan($0, packs: index, repo: repo) } }.value
            for g in scanned {
                guard let i = games.firstIndex(where: { $0.folder == g.folder }) else { continue }
                games[i] = g; checkAge(g); then?(g)
            }
        }
    }
    /// The same at once, on the caller's thread: for a build that goes on with what its first step left
    func rescanNow(_ id: MacGame.ID) {
        let index = PackEntry.index(packsURL)
        for i in games.indices where games[i].id == id { games[i] = MacGame.scan(games[i].folder, packs: index, repo: repo); checkAge(games[i]) }
    }

    /// Each pack's age against the checkout (PackAge), worked out off the main thread
    @Published var ages: [MacGame.ID: PackAge] = [:]
    func checkAge(_ g: MacGame) {
        guard let pack = g.pack else { ages[g.id] = nil; return }
        let (tid, r) = (g.titleID, repo)
        Task { let a = await Task.detached { PackAge.of(pack: pack, titleID: tid, repo: r) }.value; self.ages[g.id] = a }
    }
    private func save() { d.set(games.map(\.folder.path), forKey: "games") }

    // MARK: builds

    var canBuild: Bool { !repo.isEmpty && !python.isEmpty && !keys.isEmpty }
    /// Whether `g` can be made now: a Switch 2 game needs no prod.keys
    func canBuild(_ g: MacGame) -> Bool { !repo.isEmpty && !python.isEmpty && (g.switch2 != nil || !keys.isEmpty) }
    /// The NSP script's -k, for a game whose files are encrypted
    private func keyArgs(_ g: MacGame) -> [String] { g.switch2 == nil ? ["-k", keys] : [] }

    // MARK: queue

    @Published var queue: [MacGame.ID] = []   // games waiting to be made, in order: one build at a time (they share the CPU, the disk and Xcode)
    @Published var queuedMac: Set<MacGame.ID> = []   // those of them waiting for their Mac version, not their pack
    @Published var queuePaused = false         // the next one waits until the queue goes on
    var building: MacGame.ID? { builds.first { $0.value.state == .running }?.key }

    /// Make `g`'s pack (or its Mac version) now, or after the builds before it
    func enqueue(_ g: MacGame, kind: PackBuild.Kind = .pack) {
        guard canBuild(g), builds[g.id]?.state != .running, !queue.contains(g.id) else { return }
        queue.append(g.id)
        if kind == .mac { queuedMac.insert(g.id) } else { queuedMac.remove(g.id) }
        startNext()
    }
    func dequeue(_ id: MacGame.ID) { queue.removeAll { $0 == id }; queuedMac.remove(id) }
    func setQueuePaused(_ p: Bool) { queuePaused = p; startNext() }
    private func startNext() {
        guard building == nil, !queuePaused, let id = queue.first else { return }
        queue.removeFirst()
        let mac = queuedMac.remove(id) != nil
        if let g = games.first(where: { $0.id == id }) { if mac { buildMac(g) } else { build(g) } } else { startNext() }
    }

    func build(_ g: MacGame) {
        guard builds[g.id]?.state != .running, canBuild(g) else { return }
        guard building == nil else { if !queue.contains(g.id) { queue.append(g.id); queuedMac.remove(g.id) }; return }   // another is being made: this one waits its turn
        let script = (repo as NSString).appendingPathComponent("scripts/build_ipa_from_nsp.py")
        var args = [script, g.folder.path, "--prepare-xcode", "--progress", "json"] + keyArgs(g)
        if !team.isEmpty { args += ["--team-id", team] }
        if let lang = Self.gameLanguage { args += ["--prefer-language", lang] }
        // NX_EXTRACT_CHUNK_SUMS: the extraction keeps the game files' checksums as it writes them (nx_extract), so the pack needs not read them again
        let env = ["DM_TEAM_ID": team.isEmpty ? "0000000000" : team, "NX_EXTRACT_CHUNK_SUMS": "1"]
        let id = g.id
        let b = PackBuild(prepare: (python, args, env)) { [weak self] in
            guard let self else { return nil }
            self.rescanNow(id)
            guard let game = self.games.first(where: { $0.id == id }), let build = game.buildDir else { return nil }
            // the pack goes in the game pack folder, apart from the build files (a link left in the game's folder is followed: build_pack.py resolves --output)
            let out = self.packsURL.map { f in try? FileManager.default.createDirectory(at: f, withIntermediateDirectories: true); return game.packOutput(in: f, packs: PackEntry.index(f)) }
                ?? game.folder.appendingPathComponent(game.packName)
            var pa = [(self.repo as NSString).appendingPathComponent("dm/ios/tools/build_pack.py"), "--xcode", build.appendingPathComponent("xcode").path,
                      "--output", out.path, "--progress", "json", "--format", "3",   // one file (PackFile.swift)
                      "--verify", self.fullVerify ? "full" : "quick"]
            pa += self.team.isEmpty ? ["--unsigned"] : ["--team", self.team]
            return (self.python, pa, [:])
        }
        watch(b, g)
    }

    /// A build's ends: the game read again, the log opened on a failure, a notification, the next in the queue; a Mac version made on Play on Mac starts at once
    private func watch(_ b: PackBuild, _ g: MacGame) {
        let (id, name) = (g.id, g.name)
        b.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send(); DispatchQueue.main.async { self?.showActivity() } }.store(in: &bag)
        b.$state.dropFirst().sink { [weak self] s in
            guard let self else { return }
            DispatchQueue.main.async {
                if b.kind == .mac, s == .done { self.rescanNow(id); MacVersion.record(self.games.first { $0.id == id }, repo: self.repo) }
                self.rescan(id)
                if s == .failed { self.showLog = true }   // a failure opens the log
                NSApp.requestUserAttention(.informationalRequest)
                switch (s, b.kind) {
                case (.done, .pack): Activity.notify(tr("Game pack ready"), String(format: tr("%@ is ready to send to the iPhone."), name))
                case (.done, .mac): if let g = self.games.first(where: { $0.id == id }) { self.playOnMac(g) }
                case (.failed, .pack): Activity.notify(tr("The game pack could not be made"), String(format: tr("%@: see the log in NX Pocket for Mac."), name))
                case (.failed, .mac): Activity.notify(tr("The Mac version could not be made"), String(format: tr("%@: see the log in NX Pocket for Mac."), name))
                default: break
                }
                self.showActivity()
                if s != .running { self.startNext() }   // the next game in the queue
            }
        }.store(in: &bag)
        builds[id] = b
    }

    // MARK: play on this Mac

    /// Play on Mac: its Mac version when it has one (nxnative's Mac app of the game: its settings window, then the game, with the keyboard and controllers), else make
    /// it first (then it starts)
    func playOnMac(_ g: MacGame) {
        if let app = g.macApp {
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if let error { Task { @MainActor in Activity.notify(tr("The game could not be opened"), error.localizedDescription) } }
            }
        } else { enqueue(g, kind: .mac) }
    }
    /// The Mac version made (again) from the game's build files: build_ipa_from_nsp.py --platform mac-app (the steps the pack's prepare made are reused; the Mac host and
    /// the Mac shaders are its own), into <title ID>_build/mac/<name>.app, apart from the game's files
    func buildMac(_ g: MacGame) {
        guard builds[g.id]?.state != .running, canBuild(g) else { return }
        guard building == nil else { if !queue.contains(g.id) { queue.append(g.id); queuedMac.insert(g.id) }; return }
        let script = (repo as NSString).appendingPathComponent("scripts/build_ipa_from_nsp.py")
        var args = [script, g.folder.path, "--platform", "mac-app", "-o", MacVersion.output(g).path, "--progress", "json"] + keyArgs(g)
        if let lang = Self.gameLanguage { args += ["--prefer-language", lang] }
        watch(PackBuild(kind: .mac, prepare: (python, args, ["NX_EXTRACT_CHUNK_SUMS": "1"])) { nil }, g)
    }

    /// The game language to pack: the app's (Settings › Language, else the Mac's), when it is not English (the script falls back to English when the game lacks it)
    static var gameLanguage: String? {
        let id = AppLanguage.effective, l = Locale(identifier: id).language   // the app's language (Settings › Language)
        guard let code = l.languageCode?.identifier, code != "en" else { return nil }
        if code == "zh" { return l.script?.identifier == "Hant" || ["TW", "HK", "MO"].contains(l.region?.identifier ?? "") ? "zh-Hant" : "zh-Hans" }
        return ["ja", "fr", "de", "es", "it", "nl", "pt", "ru", "ko"].contains(code) ? code : nil
    }

    // MARK: iPhone

    func refreshDevices() {
        Task {
            self.devices = await Device.load()
            for d in self.devices where d.connected { if let p = await Device.pocket(on: d) { self.pockets[d.id] = p } }
            self.currentBuild = await Self.commitCount(self.repo)
        }
    }

    // MARK: problem report

    @Published var reporting: MacGame.ID?   // a report being put together
    private var reportRun: ToolRun?

    /// A problem report for `g` (scripts/bug_report.py: the build's logs, the settings, crash reports; never game files or keys), with the game's log from the iPhone
    /// when NX Pocket there has one, as a zip in the game's folder, shown in the Finder with a reminder to look through it before sending it
    func report(_ g: MacGame) {
        guard reporting == nil, !repo.isEmpty, !python.isEmpty else { return }
        reporting = g.id
        Task {
            var args = [(repo as NSString).appendingPathComponent("scripts/bug_report.py"), g.folder.path]
            if let d = connected, let tid = g.titleID, let p = pockets[d.id] ?? nil {   // the game's log.txt on the iPhone (Documents/Data/<title ID>), when there is one
                let log = FileManager.default.temporaryDirectory.appendingPathComponent("nxpocket-\(tid)-log.txt")
                try? FileManager.default.removeItem(at: log)
                _ = await Device.devicectl(["device", "copy", "from", "--device", d.id, "--domain-type", "appDataContainer", "--domain-identifier", p.bundleID,
                                            "--source", "Documents/Data/\(tid)/log.txt", "--destination", log.path], timeout: 30)
                if FileManager.default.fileExists(atPath: log.path) { args += ["--ios-log", log.path] }
            }
            let day = Date().formatted(.iso8601.year().month().day())
            let out = g.folder.appendingPathComponent("nxnative-report-\(g.titleID ?? "game")-\(day).zip")
            args += ["--out", out.path]
            let r = ToolRun(title: tr("Problem report"))
            reportRun = r
            r.onFinish = { [weak self] r in
                self?.reporting = nil; self?.reportRun = nil
                guard r.status == .succeeded else { self?.showLog = true; return }
                NSWorkspace.shared.activateFileViewerSelecting([out])
                let a = NSAlert()
                a.messageText = tr("Problem report ready")
                a.informativeText = tr("It holds the build's logs, your settings and crash reports, with your home folder hidden and nothing that looks like a key; no game files. Open it and look through it before you send it.")
                a.runModal()
            }
            r.start(python, args)
        }
    }

    // MARK: NX Pocket on the iPhone

    @Published var pockets: [Device.ID: InstalledPocket?] = [:]   // what each connected iPhone has: NX Pocket's build, or nil when it has none
    @Published var currentBuild: Int?                          // the checkout's commit count: the build an install makes now
    @Published var installing: ToolRun?                        // Install NX Pocket in progress (its log in the install sheet)
    @Published var showInstall = false

    enum PocketState: Equatable { case unknown, missing, old(Int), current, tooOld }
    static let pocketMinimumOS = 26   // NX Pocket's deployment target (dm/ios/pocket/project.yml)
    func pocketState(_ d: Device) -> PocketState {
        if let major = Int(d.osVersion.split(separator: ".").first ?? ""), major < Self.pocketMinimumOS { return .tooOld }
        guard let p = pockets[d.id] else { return .unknown }
        guard let p else { return .missing }
        guard let c = currentBuild else { return .unknown }
        return p.build < c ? .old(p.build) : .current
    }

    static func commitCount(_ repo: String) async -> Int? {
        await Task.detached { Int(Setup.sh("git -C '\(repo)' rev-list --count HEAD 2>/dev/null")) }.value
    }

    /// Installs NX Pocket on `d`, built from the checkout's last commit (not from changes not committed yet): a detached checkout of it beside this one
    /// (.nx-pocket-install/src, made once and moved to each new commit, so builds after the first are quick), then build_pocket.py --device. Its bundle ID is the one
    /// on the iPhone, else Settings', else org.nxnative.pocket
    func installPocket(on d: Device) {
        guard installing?.status != .running, !pocketTeam.isEmpty, !repo.isEmpty else { showInstall = true; return }
        let base = (URL(fileURLWithPath: repo).deletingLastPathComponent().appendingPathComponent(".nx-pocket-install")).path
        let bid = (pockets[d.id] ?? nil)?.bundleID ?? (bundleID.isEmpty ? "org.nxnative.pocket" : bundleID)
        let q = { (s: String) in "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let script = """
        set -e
        SRC=\(q(base + "/src")); HEAD=$(git -C \(q(repo)) rev-parse HEAD)
        if [ -e "$SRC/.git" ]; then git -C "$SRC" checkout --quiet --detach --force "$HEAD"; else git -C \(q(repo)) worktree add --quiet --detach "$SRC" "$HEAD"; fi
        echo "NX Pocket from commit $(git -C "$SRC" rev-parse --short HEAD) ($(git -C "$SRC" rev-list --count HEAD))"
        exec \(q(python)) "$SRC/dm/ios/tools/build_pocket.py" --team \(q(pocketTeam)) --bundle-id \(q(bid)) --output \(q(base + "/build")) --device \(q(d.id))
        """
        let r = ToolRun(title: tr("Install NX Pocket"))
        r.onFinish = { [weak self] r in
            guard let self else { return }
            if r.status == .succeeded { Activity.notify(tr("NX Pocket installed"), String(format: tr("NX Pocket is up to date on %@."), d.name)) }
            else if r.status != .cancelled { Activity.notify(tr("NX Pocket could not be installed"), tr("See the install log in NX Pocket for Mac.")) }
            self.refreshDevices()
        }
        installing = r; showInstall = true
        r.start("/bin/bash", ["-c", script])
    }

    /// Sends `g`'s pack to `device`; a send of it still going (or stuck) is stopped and replaced. Each step before the bytes go says what it is doing, and gives up
    /// when the iPhone does not answer (devicectl's own time limit)
    func send(_ g: MacGame, to device: Device) {
        guard let pack = g.pack else { return }
        sends[g.id]?.cancel()
        let s = PackSender(title: tr("Send to iPhone"))
        s.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send(); DispatchQueue.main.async { self?.showActivity() } }.store(in: &bag)
        sends[g.id] = s
        Task {
            var bid = bundleID
            if bid.isEmpty, let p = pockets[device.id] ?? nil { bid = p.bundleID }   // what the sidebar found already
            if bid.isEmpty {
                s.phase = tr("Looking for NX Pocket on the iPhone…")
                switch await Device.pocket(on: device) {
                case .some(.some(let p)): bid = p.bundleID; pockets[device.id] = p
                case .some(.none): s.fail(tr("NX Pocket is not on this iPhone. Install it first.")); return
                case .none: s.fail(tr("The iPhone did not answer. Unlock it, check the cable, then send again.")); return
                }
            }
            guard !s.stopped else { return }
            await s.send(pack, to: device, bundleID: bid)
            if s.done { Activity.notify(tr("Sent to iPhone"), String(format: tr("%@ is in NX Pocket on %@."), g.name, device.name)) }
            else if let f = s.failure { Activity.notify(tr("Sending failed"), "\(g.name): \(f)") }
            showActivity()
        }
    }

    /// The Dock icon's bar: the work in progress (builds and sends), as one share
    func showActivity() {
        let shares = builds.values.filter { $0.state == .running }.map(\.fraction) + sends.values.filter { !$0.finished && $0.count > 0 }.map(\.fraction)
        Activity.dock(shares.isEmpty ? nil : shares.reduce(0, +) / Double(shares.count))
    }

    /// Copies the pack into a folder the player picks (cloned on the same volume: instant, no space taken)
    func export(_ g: MacGame) {
        guard let pack = g.pack else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = tr("Export Here")
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        let r = ToolRun(title: tr("Export"))
        exporting = r
        r.onFinish = { [weak self] r in
            if r.status == .succeeded { NSWorkspace.shared.activateFileViewerSelecting([dir.appendingPathComponent(pack.lastPathComponent)]) }
            self?.exporting = nil
        }
        r.start("/bin/cp", ["-cR", pack.path, dir.appendingPathComponent(pack.lastPathComponent).path])
    }

    // MARK: setup

    func checkSetup() {
        let (r, k, p) = (repo, keys, python)
        Task.detached { let items = Setup.check(repo: r, keys: k, python: p); await MainActor.run { self.setup = items } }
    }
    var setupMissing: Bool { setup.contains { $0.state == .missing } }

    func perform(_ a: SetupAction) {
        switch a {
        case .open(let u): if let url = URL(string: u) { NSWorkspace.shared.open(url) }
        case .command(let c):
            let r = ToolRun(title: tr("Install"))
            setupRun = r
            r.onFinish = { [weak self] _ in
                guard let self else { return }
                if self.python.isEmpty || !FileManager.default.isExecutableFile(atPath: self.python) { self.python = Setup.guessPython(repo: self.repo) }
                self.checkSetup()
            }
            r.start("/bin/bash", ["-lc", c])
        case .chooseRepo:
            if let u = choose(folder: true, prompt: tr("Choose")) { repo = u.path; if python.isEmpty { python = Setup.guessPython(repo: repo) }; checkSetup() }
        case .chooseKeys:
            if let u = choose(folder: false, prompt: tr("Choose")) { keys = u.path; checkSetup() }
        case .choosePython:
            if let u = choose(folder: false, prompt: tr("Choose")) { python = u.path; checkSetup() }
        case .chooseEnv:
            if let u = choose(folder: false, prompt: tr("Choose")) { envScript = u.path; checkSetup() }
        }
    }

    func choose(folder: Bool, prompt: String) -> URL? {
        let p = NSOpenPanel()
        p.canChooseDirectories = folder; p.canChooseFiles = !folder; p.canCreateDirectories = folder; p.allowsMultipleSelection = false; p.prompt = prompt
        if !folder { p.showsHiddenFiles = true }
        return p.runModal() == .OK ? p.url : nil
    }
}
