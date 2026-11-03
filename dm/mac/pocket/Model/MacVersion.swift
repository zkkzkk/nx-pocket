// A game's Mac version, for Play on Mac: nxnative's own Mac app of the game (build_ipa_from_nsp.py --platform mac-app: dm/mac/launcher.c with its settings window, the
// Mac host, the Mac shader libraries, the game files cloned from the build), made from the same build files as its pack and kept with them, <title ID>_build/mac/<name>.app,
// so the game's folder holds only its files. Its saves are nxnative's on this Mac (~/Library/Application Support/nxnative/<title ID>), synced with the iPhone through
// the Cloud saves folder chosen in its settings window. made.json beside it says which commit and shader chain it was made from, so it can say when a newer one is there
// (PackAge, as for a pack).
import Foundation

enum MacVersion {
    /// Where the Mac version of `g` goes: its build folder (made by the build when it is not there yet), mac/<its name>.app
    static func output(_ g: MacGame) -> URL {
        let build = g.buildDir ?? g.titleID.map { g.folder.appendingPathComponent("\($0)_build", isDirectory: true) } ?? g.folder
        return build.appendingPathComponent("mac", isDirectory: true).appendingPathComponent(String(g.packName.dropLast(".nxpack".count)) + ".app")
    }
    /// The Mac version in a build folder, when there is one
    static func app(in build: URL) -> URL? {
        let dir = build.appendingPathComponent("mac", isDirectory: true)
        return ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []).first { $0.pathExtension == "app" && !$0.lastPathComponent.hasPrefix(".") }
    }
    /// Notes beside a Mac version just made: the checkout's commit and shader chain
    static func record(_ g: MacGame?, repo: String) {
        guard let app = g?.macApp else { return }
        let commit = Setup.sh("git -C '\(repo.replacingOccurrences(of: "'", with: "'\\''"))' rev-parse --short=12 HEAD 2>/dev/null")
        let info: [String: Any] = ["commit": commit, "shaders": PackAge.chain(repo: repo) ?? ""]
        try? JSONSerialization.data(withJSONObject: info).write(to: app.deletingLastPathComponent().appendingPathComponent("made.json"))
    }
    /// Whether a newer Mac version can be made (as PackAge says of a pack); runs git: off the main thread
    static func age(_ app: URL, titleID: String?, repo: String) -> PackAge {
        let d = try? Data(contentsOf: app.deletingLastPathComponent().appendingPathComponent("made.json"))
        return PackAge.of(info: d.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:], titleID: titleID, repo: repo)
    }
}
