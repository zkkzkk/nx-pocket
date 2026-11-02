// NX Pocket for Mac's updates, from the GitHub releases of the repository set in Settings (owner/name): its latest release's nx-pocket-mac.json (release.py make) says
// the newest build; a newer one's zip is downloaded, checked (its size, its SHA-256, and its Ed25519 signature against the key built into this app, NXPocketUpdateKey),
// unpacked and checked again (the same bundle ID, the build the manifest says), then put in this app's place and opened once this app has quit. It reads from GitHub
// and writes nothing there. Checked at launch and once a day while open (when a repository is set), and on request. The app is signed ad hoc and not notarized:
// macOS's checks are left as they are, and the sheet says how to open it when macOS asks.
import AppKit
import CryptoKit

struct UpdateManifest: Decodable, Equatable {
    let version: String
    let build: Int
    let commit: String?
    let zip: String
    let size: Int64
    let sha256: String
    let signature: String
    let notes: String?
}

@MainActor final class Updater: ObservableObject {
    enum State: Equatable { case idle, checking, upToDate, available(UpdateManifest), downloading, ready(UpdateManifest), failed(String) }
    @Published private(set) var state: State = .idle
    @Published var showSheet = false
    private var timer: Timer?
    private var newApp: URL?

    static var currentBuild: Int { Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0 }
    static var publicKey: String { (Bundle.main.infoDictionary?["NXPocketUpdateKey"] as? String ?? "").trimmingCharacters(in: .whitespaces) }
    var repo: String { UserDefaults.standard.string(forKey: "updateRepo").flatMap { $0.isEmpty ? nil : $0 } ?? "zkkzkk/nx-pocket" }
    /// The manifest's address: the repository's latest release, or (testing) updateFeed in the defaults, any URL file:// included
    var feed: URL? {
        if let f = UserDefaults.standard.string(forKey: "updateFeed"), let u = URL(string: f) { return u }
        let r = repo.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")).replacingOccurrences(of: "https://github.com/", with: "")
        guard r.split(separator: "/").count == 2 else { return nil }
        return URL(string: "https://github.com/\(r)/releases/latest/download/nx-pocket-mac.json")
    }

    /// At launch: a check when the last one is a day old, and one a day while the app is open
    func start() {
        let last = UserDefaults.standard.double(forKey: "updateChecked")
        if feed != nil, Date().timeIntervalSince1970 - last > 86_400 { Task { await check(manual: false) } }
        timer = Timer.scheduledTimer(withTimeInterval: 86_400, repeats: true) { [weak self] _ in Task { @MainActor in await self?.check(manual: false) } }
    }

    func check(manual: Bool) async {
        if manual { showSheet = true }
        guard let feed else { state = .failed(tr("Set the repository the releases come from first (Settings › Updates).")); return }
        state = .checking
        do {
            let (data, resp) = try await URLSession.shared.data(from: feed)
            if let h = resp as? HTTPURLResponse, h.statusCode != 200 { throw Failure.http(h.statusCode) }
            let m = try JSONDecoder().decode(UpdateManifest.self, from: data)
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "updateChecked")
            if m.build > Self.currentBuild { state = .available(m); showSheet = true } else { state = .upToDate }
        } catch {
            state = .failed(String(format: tr("Could not check for updates: %@"), error.localizedDescription))
        }
    }

    enum Failure: LocalizedError {
        case http(Int), noKey, size, digest, signature, contents(String)
        var errorDescription: String? {
            switch self {
            case .http(let c): return String(format: tr("the server answered %d (no release yet?)"), c)
            case .noKey: return tr("this build has no update key (NXPocketUpdateKey), so it cannot check a release's signature")
            case .size: return tr("the download's size is not the release's")
            case .digest: return tr("the download's checksum is not the release's")
            case .signature: return tr("the release's signature does not match this app's update key: it was not made by this app's maker, or was changed on the way")
            case .contents(let s): return s
            }
        }
    }

    /// Downloads the release, checks it, and unpacks it beside the download, ready to go in this app's place
    func download(_ m: UpdateManifest) async {
        guard let feed else { return }
        state = .downloading
        do {
            guard let key = Data(base64Encoded: Self.publicKey), let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: key) else { throw Failure.noKey }
            let zipURL = feed.deletingLastPathComponent().appendingPathComponent(m.zip)
            let (tmp, resp) = try await URLSession.shared.download(from: zipURL)
            if let h = resp as? HTTPURLResponse, h.statusCode != 200 { throw Failure.http(h.statusCode) }
            let data = try Data(contentsOf: tmp)
            guard Int64(data.count) == m.size else { throw Failure.size }
            guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == m.sha256 else { throw Failure.digest }
            guard let sig = Data(base64Encoded: m.signature), pub.isValidSignature(sig, for: data) else { throw Failure.signature }
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nxpocket-update-\(m.build)", isDirectory: true)
            try? FileManager.default.removeItem(at: dir)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let zip = dir.appendingPathComponent(m.zip); try data.write(to: zip)
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto"); p.arguments = ["-x", "-k", zip.path, dir.path]
            try p.run(); p.waitUntilExit()
            let app = dir.appendingPathComponent("NX Pocket.app")
            let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any] ?? [:]
            guard info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier else { throw Failure.contents(tr("the release is not this app (another bundle ID)")) }
            guard Int(info["CFBundleVersion"] as? String ?? "") == m.build else { throw Failure.contents(tr("the release's app is not the build its manifest names")) }
            newApp = app; state = .ready(m)
        } catch {
            state = .failed(String(format: tr("The update was not installed: %@"), error.localizedDescription))
        }
    }

    /// Where this app is, when it can be replaced there
    var replaceable: Bool { FileManager.default.isWritableFile(atPath: Bundle.main.bundleURL.deletingLastPathComponent().path) && !Bundle.main.bundlePath.contains("/AppTranslocation/") }

    /// Quits, and once quit puts the new app in this one's place, then opens it (a shell of its own, which outlives this app). The new copy is made beside this one
    /// first and the two swap by renaming, so a failure on the way leaves this app as it was; the old copy is deleted last, in the background
    func install() {
        guard let newApp, replaceable else { return }
        let q = { (s: String) in "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let me = Bundle.main.bundlePath, pid = ProcessInfo.processInfo.processIdentifier
        let new = me + ".new", old = me + ".old-\(pid)"
        let script = "rm -rf \(q(new)); ditto \(q(newApp.path)) \(q(new)) || exit 1; while kill -0 \(pid) 2>/dev/null; do sleep 0.3; done; "
                   + "mv \(q(me)) \(q(old)) && mv \(q(new)) \(q(me)) && open \(q(me)); rm -rf \(q(old))"
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/bash"); p.arguments = ["-c", "nohup bash -c \(q(script)) >/dev/null 2>&1 &"]
        try? p.run(); p.waitUntilExit()
        showSheet = false   // a quit asked for from inside a sheet is not taken: the sheet goes first
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { NSApp.terminate(nil) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { exit(0) }   // still here: nothing is left unsaved by now
    }
    func showNewApp() { if let newApp { NSWorkspace.shared.activateFileViewerSelecting([newApp]) } }
}
