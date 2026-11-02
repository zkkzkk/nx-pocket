// The launcher preview app's entry (project.yml): a black root view that shows the launcher as the game app does (front_ios.m viewDidAppear → dm_show_launcher), and in place of
// the game, a line saying Play was pressed and which settings went into the environment. DM_PREVIEW_POCKET=1 shows NX Pocket's home screen instead (dm/ios/pocket): the game packs
// in the app's Documents/Games, and Import game pack.
import SwiftUI
import UIKit

@main
final class PreviewAppDelegate: UIResponder, UIApplicationDelegate {}

// iOS 27 starts an app only through a scene (the game app's SceneDelegate, main.m)
@objc(PreviewSceneDelegate)
final class PreviewSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let ws = scene as? UIWindowScene else { return }
        let w = UIWindow(windowScene: ws)
        w.rootViewController = PreviewRoot()
        w.makeKeyAndVisible()
        window = w
    }
}

private var root: PreviewRoot?
private final class PreviewRoot: UIViewController {
    private var shown = false
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .all }
    override func viewDidLoad() { super.viewDidLoad(); view.backgroundColor = .black; root = self }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if shown { return }
        shown = true
        if ProcessInfo.processInfo.environment["DM_PREVIEW_IMPORT_TEST"] == "1" { importTest(); return }
        if ProcessInfo.processInfo.environment["DM_PREVIEW_IMPORT_TEST"] == "3" { importFileTest(); return }
        if ProcessInfo.processInfo.environment["DM_PREVIEW_POCKET"] == "1" {   // NX Pocket's home screen: the packs in Documents/Games (a simulator cannot run one; Play shows the settings)
            let library = GameLibrary.pocket()
            library.runningID = ProcessInfo.processInfo.environment["DM_PREVIEW_RUNNING"]   // a game shown as paused under the home screen (Resume, Close)
            var host: UIViewController?
            let h = LauncherHost(rootView: LauncherHome(library: library, play: {
                guard library.selected.playable, let h = host else { return }
                library.model.apply(); h.dismiss(animated: false) { root?.started() }
            }, close: { library.runningID = nil }))
            h.modalPresentationStyle = .fullScreen; host = h
            present(h, animated: false) { busyTest(library, h) }
            return
        }
        if !dmShowLauncher(Unmanaged.passUnretained(self).toOpaque(), { root?.started() }) { started() }
    }
    func started() {
        let label = UILabel(frame: view.bounds.insetBy(dx: 32, dy: 32))
        label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        label.numberOfLines = 0; label.textAlignment = .center; label.textColor = .white
        let set = ProcessInfo.processInfo.environment.filter { $0.key.hasPrefix("DM_") }.map { "\($0.key)=\($0.value)" }.sorted()
        label.text = "Play pressed: the game starts here.\n\n" + set.joined(separator: "\n")
        view.addSubview(label)
    }
}

// DM_PREVIEW_BUSY=1 (development): a second after NX Pocket's home screen shows, the first pack in Documents/Games with an archive still packed (format 2) is unpacked
// under NX Pocket's note (BusyNote), as Play does the first time; its result on stderr
private func busyTest(_ library: GameLibrary, _ host: UIViewController) {
    guard ProcessInfo.processInfo.environment["DM_PREVIEW_BUSY"] == "1" else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
        guard let g = library.games.first(where: { $0.pack.map(GameLibrary.needsUnpacking) ?? false }), let pack = g.pack, let w = host.view.window else { fputs("busytest: no pack to unpack\n", stderr); return }
        library.selectedID = g.id
        let note = BusyNote.show(in: w, game: g, String(format: tr("Preparing %@ (first start only)…"), g.name), measured: true)
        DispatchQueue.global(qos: .userInitiated).async {
            let r = Result { try GameLibrary.unpack(pack) { f in DispatchQueue.main.async { note.state.fraction = f } } }
            fputs("busytest: \(r)\n", stderr)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { note.view.removeFromSuperview() }
        }
    }
}

// DM_PREVIEW_IMPORT_TEST=3 (development): single-file packs (format 3) put in Documents imported as the Files app or AirDrop would hand them over (in place, moved into
// Documents/Games): each one's check and import, then what NX Pocket has of the last one imported; the results on stderr
private func importFileTest() {
    let fm = FileManager.default, docs = GameLibrary.documents
    func say(_ s: String) { fputs("importtest: \(s)\n", stderr) }
    let files = ((try? fm.contentsOfDirectory(at: docs, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "nxpack" && PackFile.isFile($0) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    DispatchQueue.global().async {
        for f in files {
            let (info, c) = PackInfo.load(f)
            say("\(f.lastPathComponent): load \(info.map { "\($0.name) format \($0.format)" } ?? "nil"); \(c.passed ? "checks passed" : c.files ?? c.signature ?? "failed"); \((try? PackFile(f))?.fullyHashed == true ? "full check" : "quick check")")
            guard info != nil else { continue }
            let job = GameLibrary.CopyProgress()
            do {
                let id = try GameLibrary.importPack(f, mode: .inside, progress: job)
                let lib = GameLibrary.pocket(), g = lib.games.first { $0.titleID == id }
                let unpacked = (try? fm.contentsOfDirectory(atPath: GameLibrary.unpackedFolder(id).path))?.sorted() ?? []
                say("  imported \(id): in Games \(((try? fm.contentsOfDirectory(atPath: GameLibrary.packsFolder.path)) ?? []).sorted()), source left \(fm.fileExists(atPath: f.path))")
                say("  unpacked [\(unpacked.joined(separator: ", "))]; playable \(g?.playable ?? false), icon \(g?.icon != nil), needs unpacking \(g?.pack.map(GameLibrary.needsUnpacking) ?? true), romfs \(g?.pack.flatMap { try? PackFile($0.url).romfsSize } ?? -1)")
            } catch { say("  refused: \(error.localizedDescription); in Games \(((try? fm.contentsOfDirectory(atPath: GameLibrary.packsFolder.path)) ?? []).sorted())") }
        }
        say("done")
    }
}

// DM_PREVIEW_IMPORT_TEST=1 (development): GameLibrary's import modes on the pack in Documents/Games, its result on stderr (simctl launch --console-pty)
private func importTest() {
    let fm = FileManager.default, games = GameLibrary.packsFolder, docs = GameLibrary.documents
    func say(_ s: String) { fputs("importtest: \(s)\n", stderr) }
    guard let pack = (try? fm.contentsOfDirectory(at: games, includingPropertiesForKeys: nil))?.first(where: { $0.pathExtension == "nxpack" }) else { say("no pack in Documents/Games"); return }
    func names() -> String { ((try? fm.contentsOfDirectory(atPath: games.path)) ?? []).sorted().joined(separator: ", ") }
    DispatchQueue.global().async {
        do {
            let id = try GameLibrary.importPack(pack, mode: .inside)
            say("1 in Games: \(id), Games = [\(names())]")
            let loose = docs.appendingPathComponent("Loose.nxpack"); try? fm.removeItem(at: loose)
            try fm.copyItem(at: pack, to: loose)
            say("2 location of Documents/Loose.nxpack: \(GameLibrary.location(loose))")
            _ = try GameLibrary.importPack(loose, mode: .inside)
            say("2 moved: Loose exists \(fm.fileExists(atPath: loose.path)), Games = [\(names())]")
            // a source outside Documents with a large file, so the copy takes long enough to cancel
            let src = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Big.nxpack"); try? fm.removeItem(at: src)
            try fm.copyItem(at: games.appendingPathComponent(id + ".nxpack"), to: src)
            fm.createFile(atPath: src.appendingPathComponent("romfs.img").path, contents: Data(count: 400 << 20))
            say("3 location of tmp/Big.nxpack: \(GameLibrary.location(src))")
            let job = GameLibrary.CopyProgress()
            DispatchQueue.global().async { while job.done == 0 { usleep(1000) }; job.cancel() }
            do { _ = try GameLibrary.importPack(src, mode: .copy, progress: job); say("3 FAILED: the copy was not cancelled") }
            catch { say("3 cancelled at \(job.done >> 20) of \(job.total >> 20) MiB: \(error.localizedDescription); Games = [\(names())]") }
            let full = GameLibrary.CopyProgress()
            _ = try GameLibrary.importPack(src, mode: .copy, progress: full)
            let size = (try? fm.attributesOfItem(atPath: games.appendingPathComponent(id + ".nxpack/romfs.img").path)[.size] as? Int) ?? -1
            say("4 copied \(full.done >> 20) of \(full.total >> 20) MiB; romfs.img in Games \(size >> 20) MiB; Games = [\(names())]")
            try? fm.removeItem(at: src)
        } catch { say("FAILED: \(error.localizedDescription)") }
    }
}
