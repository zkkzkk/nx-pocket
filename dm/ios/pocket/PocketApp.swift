// NX Pocket's entry (project.yml): the launcher's home screen over the imported game packs (GameLibrary.pocket), and Play: the selected pack's settings into the environment, then its
// library loaded (dlopen; iOS loads it only when it is signed by NX Pocket's team) and started with dm_pack_start (main.m, DM_PACK) in a window of its own.
// As a Switch's Home button: the game's Home pill brings the home screen back over the game, which pauses (dm_pack_suspend); Resume carries on. One game per launch: a pack's
// host cannot be unloaded, so closing the game (Close, or Play on another game) starts NX Pocket over (dm_pack_close), on its home screen or straight into the next game.
import SwiftUI
import UIKit
import Darwin
import os

@main
final class PocketAppDelegate: UIResponder, UIApplicationDelegate {}

@objc(PocketSceneDelegate)
final class PocketSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?              // the home screen
    private var gameWindow: UIWindow?  // the running game's, under the home screen while it is paused
    private var homeShown = true
    private let library = GameLibrary.pocket()
    private static let playNextKey = "pocket.playOnLaunch"   // the game to start once NX Pocket has started over (Play on another game while one ran)

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let ws = scene as? UIWindowScene else { return }
        // NX Pocket's own log, Documents/pocket-log.txt (the previous run's kept as pocket-log.prev.txt), until a game sends its output to its own log.txt (main.m)
        let log = GameLibrary.documents.appendingPathComponent("pocket-log.txt"), prev = GameLibrary.documents.appendingPathComponent("pocket-log.prev.txt")
        try? FileManager.default.removeItem(at: prev); try? FileManager.default.moveItem(at: log, to: prev)
        if ProcessInfo.processInfo.environment["DM_POCKET_SYSLOG"] != "1", freopen(log.path, "w", stderr) != nil { setvbuf(stderr, nil, _IOLBF, 0) }
        PackInfo.signsHere = { PackSigner.current != nil }
        PocketCertificate.current = { PackSigner.current.map { .init(name: $0.name, team: $0.team, expires: $0.expires) } }
        PocketCertificate.importP12 = { let c = try PackSigner.importCertificate($0, password: $1); return .init(name: c.name, team: c.team, expires: c.expires) }
        PocketCertificate.remove = { PackSigner.removeCertificate() }
        PackSigner.adoptEmbeddedCertificate()
        PackSigner.adoptDroppedCertificate()
        library.reload()
        let w = UIWindow(windowScene: ws)
        w.rootViewController = LauncherHost(rootView: LauncherHome(library: library, play: { [weak self] in self?.play() }, close: { [weak self] in self?.confirmClose(next: nil) }))
        w.makeKeyAndVisible()
        window = w
        if ProcessInfo.processInfo.environment["DM_POCKET_SYSLOG"] == "1" { SysLogMirror.start() }
        if let u = options.urlContexts.first?.url { opened(u) }   // started by opening a pack
        DispatchQueue.main.async { [weak self] in self?.noticeLastStop() }
        // Development switches (a Mac run: open --env): DM_POCKET_PACK=<folder> links that pack as Use where it is would, without the file picker (the app must be able to read
        // it: a path inside the app, or one picked before); DM_POCKET_PLAY=<title ID> presses Play on that game once the home screen is up
        let env = ProcessInfo.processInfo.environment
        if let p = env["DM_POCKET_PACK"] {
            // a relative path is inside the app (a Mac run puts a pack there: the only place outside its container that the sandbox lets it read without the file picker)
            let url = p.hasPrefix("/") ? URL(fileURLWithPath: p) : Bundle.main.bundleURL.appendingPathComponent(p)
            do { library.selectedID = try GameLibrary.importPack(url, mode: GameLibrary.location(url) == .elsewhere ? .link : .inside); library.reload() }
            catch { fputs("[RED] pocket: DM_POCKET_PACK \(p): \(error.localizedDescription)\n", stderr) }
        }
        let next = UserDefaults.standard.string(forKey: Self.playNextKey)
        UserDefaults.standard.removeObject(forKey: Self.playNextKey)
        if let id = env["DM_POCKET_PLAY"] ?? next {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self else { return }
                if self.library.games.contains(where: { $0.titleID == id }) { self.library.selectedID = id; self.play() }
                else { fputs("[RED] pocket: DM_POCKET_PLAY \(id): no such game\n", stderr) }
            }
        }
    }
    // A pack opened from another app (the Files app, AirDrop: org.nxnative.nxpack, Info.plist): the import dialog takes it, as one picked there. Not while a game runs:
    // its pack cannot change under it
    func scene(_ scene: UIScene, openURLContexts contexts: Set<UIOpenURLContext>) { if let u = contexts.first?.url { opened(u) } }
    private func opened(_ url: URL) {
        fputs("pocket: opened \(url.path)\n", stderr)
        guard library.runningID == nil else { fputs("pocket: a game is running; close it to import \(url.lastPathComponent)\n", stderr); return }
        library.opening = url
    }
    // The scene's focus events go to the game while it is on screen (front_ios.m front_ios_focus_event); a paused game stays paused. With no game, a pack dropped into
    // Documents/Games shows on return
    private var playing: Bool { PackRun.focus != nil && !homeShown }
    func sceneWillResignActive(_ s: UIScene) { if playing { PackRun.focus?(0) } }
    func sceneDidEnterBackground(_ s: UIScene) { if playing { PackRun.focus?(1) } }
    func sceneWillEnterForeground(_ s: UIScene) {
        if playing { PackRun.focus?(2) } else if library.runningID == nil { PackSigner.adoptDroppedCertificate(); library.reload() }
    }
    func sceneDidBecomeActive(_ s: UIScene) { if playing { PackRun.focus?(3) } }

    // The game's Home pill: the home screen fades in over the paused game
    private func showHome() {
        guard let window, !homeShown else { return }
        PackRun.suspend(true); homeShown = true
        window.alpha = 0; window.isHidden = false; window.makeKeyAndVisible()
        UIView.animate(withDuration: 0.22) { window.alpha = 1 }
        fputs("pocket: home over the paused game\n", stderr)
        if let s = ProcessInfo.processInfo.environment["DM_POCKET_RESUME_AFTER"].flatMap(Double.init) {   // development: Resume, unasked, that many seconds later
            DispatchQueue.main.asyncAfter(deadline: .now() + s) { [weak self] in self?.resume() }
        }
    }
    // Resume: the home screen fades out and the game carries on
    private func resume() {
        guard let window, let game = gameWindow, homeShown else { return }
        homeShown = false; game.makeKey()
        UIView.animate(withDuration: 0.18, animations: { window.alpha = 0 }) { _ in window.isHidden = true; window.alpha = 1 }
        PackRun.suspend(false)
        fputs("pocket: game resumed\n", stderr)
    }
    // Closing the running game, after asking: NX Pocket starts over (dm_pack_close), on its home screen, or into `next`
    private func confirmClose(next: GameEntry?) {
        guard let running = library.games.first(where: { $0.titleID == library.runningID }), let window else { return }
        let a = UIAlertController(title: String(format: tr("Close %@?"), running.name),
                                  message: next.map { String(format: tr("Progress that has not been saved will be lost. %@ starts afterwards."), $0.name) } ?? tr("Progress that has not been saved will be lost."),
                                  preferredStyle: .alert)
        a.addAction(UIAlertAction(title: tr("Cancel"), style: .cancel))
        a.addAction(UIAlertAction(title: tr(next == nil ? "Close" : "Close and Start"), style: .destructive) { _ in
            if let next { UserDefaults.standard.set(next.titleID, forKey: Self.playNextKey) }
            PackRun.close()
        })
        window.rootViewController?.present(a, animated: true)
    }

    // A game the host stopped on its own, from the last lines of its log: under DM_GUEST_FILE_MIN_FREE free on the disk (hle_svc.c guest_file_thread) or over the memory
    // watchdog's limit (hle_nvn.c). NX Pocket ends with the game, which only went black, so the next start of NX Pocket says why, once per log
    private static let stopSeenKey = "pocket.stopNoticeSeen"
    private func noticeLastStop() {
        guard let g = library.games.filter({ $0.lastPlayed != nil }).max(by: { $0.lastPlayed! < $1.lastPlayed! }), let window else { return }
        let log = GameLibrary.dataFolder(g.titleID).appendingPathComponent("log.txt")
        guard let made = (try? log.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970,
              made > UserDefaults.standard.double(forKey: Self.stopSeenKey), let h = try? FileHandle(forReadingFrom: log) else { return }
        defer { try? h.close() }
        let end = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: end > 4096 ? end - 4096 : 0)
        let tail = String(decoding: (try? h.readToEnd()) ?? Data(), as: UTF8.self)
        UserDefaults.standard.set(made, forKey: Self.stopSeenKey)
        let why: String
        if let m = tail.firstMatch(of: /guest file: ([0-9.]+) GB free on its disk, under ([0-9.]+): stopping the game/) {
            why = String(format: tr("The iPhone's storage ran low (%@ GB free), so the game was stopped before it filled up. The game needs at least %@ GB free while it runs. Free up some space, then start it again."), String(m.1), String(m.2))
        } else if tail.contains("memory watchdog:"), tail.contains(", exiting") {
            why = tr("The game used more memory than the iPhone allows, so it was stopped.")
        } else { return }
        fputs("pocket: \(g.name) was stopped by its host the last time\n", stderr)
        let a = UIAlertController(title: String(format: tr("%@ was stopped"), g.name), message: why, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: tr("OK"), style: .default))
        window.rootViewController?.present(a, animated: true)
    }

    // The free space a game's memory files would take from (DM_GUEST_FILE_DIR is the temporary folder, main.m), as hle_svc.c counts it: none the system could purge
    private static func freeSpace() -> Int64? {
        (try? URL(fileURLWithPath: NSTemporaryDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityKey]))?.volumeAvailableCapacity.map(Int64.init)
    }
    private static let lowSpace: Int64 = 8 << 30   // the host stops a game in files under 5 GB free; a few GB above it for the files to grow
    private var lowSpaceAccepted = false

    private var starting = false
    private func play() {
        let g = library.selected
        if let running = library.runningID {   // a game is paused under the home screen: carry on with it, or close it for this one
            if running == g.titleID { resume() } else { confirmClose(next: g) }
            return
        }
        guard let pack = g.pack, g.playable, let window, let scene = window.windowScene, PackRun.focus == nil, !starting else { return }
        if pack.linked, GameLibrary.waitingForICloud(pack.url, start: true) {   // an iCloud Drive pack not all on this device yet: its files are asked for, the game waits
            let a = UIAlertController(title: g.name, message: String(format: tr("%@ is still downloading from iCloud Drive. Try again once it is on this device."), g.name), preferredStyle: .alert)
            a.addAction(UIAlertAction(title: tr("OK"), style: .default)); window.rootViewController?.present(a, animated: true)
            return
        }
        // Little free space: a game whose memory is in files is stopped when the disk falls under 5 GB free, so say so before it starts
        if !lowSpaceAccepted, let free = Self.freeSpace(), free < Self.lowSpace {
            let a = UIAlertController(title: tr("Storage Almost Full"),
                                      message: String(format: tr("Only %@ GB is free on this iPhone. A large game keeps part of its memory in storage, and it is stopped when less than 5 GB is free."), String(format: "%.1f", Double(free) / 1073741824)),
                                      preferredStyle: .alert)
            a.addAction(UIAlertAction(title: tr("Cancel"), style: .cancel))
            a.addAction(UIAlertAction(title: tr("Start Anyway"), style: .default) { [weak self] _ in self?.lowSpaceAccepted = true; self?.play() })
            window.rootViewController?.present(a, animated: true)
            return
        }
        lowSpaceAccepted = false
        starting = true
        if pack.linked { _ = pack.url.startAccessingSecurityScopedResource() }   // a pack used in place: readable from here on (unpacking, then the game)
        // A format 2 pack's archives are unpacked once (GameLibrary.unpack), and a pack not signed by NX Pocket's team is signed here (PackSigner.swift): seconds to a
        // minute or two for a large game the first time, so off the main thread, under a progress note
        let unpacking = GameLibrary.needsUnpacking(pack)
        let note = unpacking ? PackRun.busy(window, game: g, String(format: tr("Preparing %@ (first start only)…"), g.name), measured: true)
            : PackSigner.needsSigning(pack) ? PackRun.busy(window, game: g, String(format: tr("Signing %@ for this device…"), g.name)) : nil
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let lib = Result { () throws -> URL in
                let progress: (Double) -> Void = { f in DispatchQueue.main.async { note?.state.fraction = f } }
                if let msl = try GameLibrary.unpack(pack, progress: unpacking ? progress : nil) { setenv("DM_MSL_DIR", msl.path, 1) }   // a pack used in place: its shaders unpacked beside NX Pocket's data
                setenv("DM_UI_LANG", launcherChinese ? "zh" : "en", 1)   // the game's own words (the Home and Edit pills, the layout editor) in NX Pocket's language
                if pack.single {   // the game files are the start of the pack file itself (hle_fs.c img_open)
                    guard let size = try PackFile(pack.url).romfsSize else { throw PackFile.Failure.unreadable("romfs.img") }
                    setenv("DM_ROMFS", pack.url.path, 1); setenv("DM_ROMFS_SIZE", String(size), 1)
                }
                if unpacking, PackSigner.needsSigning(pack) {   // then the signing, which has no progress of its own
                    DispatchQueue.main.async { note?.state.text = String(format: tr("Signing %@ for this device…"), g.name); note?.state.fraction = nil }
                }
                return try PackSigner.library(for: pack)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                note?.view.removeFromSuperview(); self.starting = false
                let why: String?
                switch lib {
                case .failure(let e): why = e.localizedDescription
                case .success(let url):
                    self.library.markPlayed(g.titleID)
                    self.library.model(for: g).apply()
                    let gw = UIWindow(windowScene: scene)
                    why = PackRun.start(pack, library: url, data: GameLibrary.dataFolder(g.titleID), window: gw)
                    if why == nil {
                        self.gameWindow = gw; gw.makeKeyAndVisible(); window.isHidden = true; self.homeShown = false
                        self.library.runningID = g.titleID
                        PackRun.home = { [weak self] in self?.showHome() }
                    }
                }
                if let why {
                    let a = UIAlertController(title: g.name, message: why, preferredStyle: .alert)
                    a.addAction(UIAlertAction(title: tr("OK"), style: .default))
                    window.rootViewController?.present(a, animated: true)
                }
            }
        }
    }
}

/// The running pack: its library's entry points
enum PackRun {
    private typealias Start = @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>, UnsafeMutableRawPointer) -> Int32
    private typealias Focus = @convention(c) (Int32) -> Void
    private typealias OnHome = @convention(c) (@convention(c) () -> Void) -> Void
    private typealias Close = @convention(c) () -> Void
    static private(set) var focus: ((Int32) -> Void)?
    static var home: (() -> Void)?           // the game's Home pill (dm_pack_on_home)
    private static var suspendFn: Focus?, closeFn: Close?
    static func suspend(_ on: Bool) { suspendFn?(on ? 1 : 0) }
    static func close() { if let closeFn { closeFn() } else { exit(0) } }

    /// The note over the home screen while a pack is being prepared (its archives unpacked) or signed (BusyNote, LauncherHome.swift)
    static func busy(_ window: UIWindow, game: GameEntry, _ text: String, measured: Bool = false) -> (view: UIView, state: BusyState) {
        BusyNote.show(in: window, game: game, text, measured: measured)
    }

    /// Loads and starts the pack; nil once the game has the window, else why it could not start
    static func start(_ pack: GamePack, library: URL, data: URL, window: UIWindow) -> String? {
        if pack.linked { _ = pack.url.startAccessingSecurityScopedResource() }   // a pack used in place: readable for as long as the game runs
        try? FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let lib = library.path   // the pack's own, or the copy signed here (PackSigner.swift)
        fputs("pocket: loading \(lib)\n", stderr)
        guard let h = dlopen(lib, RTLD_NOW | RTLD_LOCAL) else {
            let e = dlerror().map { String(cString: $0) } ?? "?"
            fputs("[RED] pocket: dlopen failed: \(e)\n", stderr)
            return String(format: tr("The game's library could not be loaded. It must be signed by NX Pocket's team.\n\n%@"), e)
        }
        guard let s = dlsym(h, "dm_pack_start"), let f = dlsym(h, "dm_pack_focus_event") else { return tr("This library is not a game pack (no dm_pack_start).") }
        let startFn = unsafeBitCast(s, to: Start.self), focusFn = unsafeBitCast(f, to: Focus.self)
        focus = { focusFn($0) }
        suspendFn = dlsym(h, "dm_pack_suspend").map { unsafeBitCast($0, to: Focus.self) }
        closeFn = dlsym(h, "dm_pack_close").map { unsafeBitCast($0, to: Close.self) }
        if let on = dlsym(h, "dm_pack_on_home") { unsafeBitCast(on, to: OnHome.self)({ DispatchQueue.main.async { PackRun.home?() } }) }   // a pack without it closes on Home
        let ok = startFn(pack.folder.path, data.path, Unmanaged.passUnretained(window).toOpaque())
        SysLogMirror.follow(data.appendingPathComponent("log.txt"))
        fputs("pocket: \(pack.info.name) started (game files \(ok != 0 ? "found" : "missing"))\n", stderr)
        return nil   // the game's own screen says what is missing (front_ios.m), as in an app
    }
}

/// DM_POCKET_SYSLOG=1 (development): NX Pocket's own messages and, once a game runs, its log.txt go to the system log as well (subsystem nxpocket; log stream --predicate
/// 'subsystem == "nxpocket"'), for a run where the app's container cannot be read (an iOS app on a Mac, driven from a terminal)
enum SysLogMirror {
    private static let log = Logger(subsystem: "nxpocket", category: "log")
    private static var started = false

    static func start() {
        guard !started else { return }
        started = true
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { return }
        dup2(fds[1], STDERR_FILENO); setvbuf(stderr, nil, _IOLBF, 0)
        let read = FileHandle(fileDescriptor: fds[0], closeOnDealloc: false)
        Thread.detachNewThread { lines(read) }
    }

    /// After the game's main.m sent stderr to <data>/log.txt: follow that file
    static func follow(_ file: URL) {
        guard started else { return }
        Thread.detachNewThread {
            var h: FileHandle?
            for _ in 0..<100 where h == nil { h = try? FileHandle(forReadingFrom: file); if h == nil { Thread.sleep(forTimeInterval: 0.1) } }
            guard let h else { log.error("no \(file.path, privacy: .public)"); return }
            lines(h)
        }
    }

    private static func lines(_ h: FileHandle) {
        var pending = Data()
        while true {
            let d = h.availableData
            if d.isEmpty { Thread.sleep(forTimeInterval: 0.2); continue }   // a file at its end (a pipe's end never comes)
            pending.append(d)
            while let nl = pending.firstIndex(of: 10) {
                let line = String(decoding: pending[pending.startIndex..<nl], as: UTF8.self)
                pending.removeSubrange(pending.startIndex...nl)
                log.notice("\(line, privacy: .public)")
            }
        }
    }
}

