// Whether a game pack is older than the code it would be made from now: the commit in its pack.json (build_pack.py) against the checkout's, and what changed between
// them in what goes into a pack (the host, the graphics, the iOS front end, the rewriter, the game's profile), and whether its shaders are another chain's than the
// checkout's (dm/gfx/nvn/dmsh_chain.h). A pack made before a change there plays as it did, so it is shown as a newer version to have, not a fault; making it again
// brings the change in, and a new chain means its shaders are compiled again first (the prepare step does it: ShaderRebuild says so and how long). Runs git: call it off
// the main thread.
import Foundation

struct PackAge: Equatable {
    enum State: Equatable { case current, stale, unknown }
    let state: State
    let commit: String?       // the pack's
    let behind: Int           // commits since it
    let changed: [String]     // what changed, in words (tr), when stale
    let why: String?          // why it cannot be told (unknown)
    var chainChanged = false  // its shaders are another chain's: making it again compiles them again

    /// What a newer pack would bring, in a sentence (a stale pack's detail and tooltip)
    static func newer(_ a: PackAge) -> String {
        guard a.state == .stale else { return "" }
        let what = a.changed.joined(separator: tr(", "))
        return a.behind > 0 ? String(format: tr("Made %d commits ago. Since then, %@ changed. Making it again brings that in; this pack keeps working as it is."), a.behind, what)
                            : String(format: tr("Since it was made, %@ changed. Making it again brings that in; this pack keeps working as it is."), what)
    }

    /// The shader chain the checkout's host is compiled with ("b-" and dmsh_chain.h's version, as a pack's "shaders" names it), nil when it cannot be read
    static func chain(repo: String) -> String? {
        guard let h = try? String(contentsOfFile: (repo as NSString).appendingPathComponent("dm/gfx/nvn/dmsh_chain.h"), encoding: .utf8),
              let m = h.firstMatch(of: /#define DMSH_CHAIN "([^"]+)"/) else { return nil }
        return "b-" + m.1
    }

    /// The parts of the checkout a pack is made of, with what to call each and which changed files are in it. The iPhone front end is what the pack's library builds
    /// of dm/ios/Sources (pack.yml): not the Swift launcher, LauncherFold.m or PackSign.c, which are NX Pocket's own
    static func parts(_ titleID: String?) -> [(String, (String) -> Bool)] {
        let under = { (dirs: [String]) in { (f: String) in dirs.contains { f == $0 || f.hasPrefix($0 + "/") } } }
        let notInPack: Set<String> = ["Info.plist", "DmIOS-Bridging-Header.h", "LauncherFold.m", "PackSign.c"]
        return [(tr("the host (emulation)"), { f in under(["dm/host"])(f) && !f.hasPrefix("dm/host/tests/") }),
                (tr("the graphics and shaders"), under(["dm/gfx"])),
                (tr("the iPhone front end"), { f in f == "dm/ios/pack.yml" || (f.hasPrefix("dm/ios/Sources/") && !f.hasSuffix(".swift") && !notInPack.contains((f as NSString).lastPathComponent)) }),
                (tr("the code rewriter"), under(["dm/tools/patch_nso.py", "dm/tools/sdk_patches.py", "dm/tools/nso.py", "dm/tools/nso_code.py", "dm/tools/nso_match.py", "dm/tools/nso_fnmap.py"])),
                (tr("this game's profile"), titleID.map { under(["dm/games/\($0)"]) } ?? { _ in false })]
    }

    static func of(pack: URL, titleID: String?, repo: String) -> PackAge {
        let json = PackFile.isFile(pack) ? (try? PackFile(pack))?.data("pack.json") : try? Data(contentsOf: pack.appendingPathComponent("pack.json"))
        let info = json.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let commit = info["commit"] as? String
        // another shader chain: a newer version whatever the commits say (and the graphics are named as the chain, not twice)
        if let have = info["shaders"] as? String, let want = chain(repo: repo), have != want {
            let a = of(commit: commit, titleID: titleID, repo: repo)
            return PackAge(state: .stale, commit: a.commit, behind: a.behind, changed: [tr("the shader chain")] + a.changed.filter { $0 != tr("the graphics and shaders") }, why: nil, chainChanged: true)
        }
        return of(commit: commit, titleID: titleID, repo: repo)
    }

    private static func of(commit: String?, titleID: String?, repo: String) -> PackAge {
        guard let commit, !commit.isEmpty else { return PackAge(state: .unknown, commit: nil, behind: 0, changed: [], why: tr("The pack does not say which commit it was made from.")) }
        guard !repo.isEmpty else { return PackAge(state: .unknown, commit: commit, behind: 0, changed: [], why: tr("No nxnative checkout is set.")) }
        let q = "'" + repo.replacingOccurrences(of: "'", with: "'\\''") + "'"
        guard Setup.sh("git -C \(q) cat-file -e \(commit)^{commit} 2>/dev/null && echo y") == "y" else {
            return PackAge(state: .unknown, commit: commit, behind: 0, changed: [], why: String(format: tr("Commit %@ is not in this checkout (made from another one?)."), commit))
        }
        let behind = Int(Setup.sh("git -C \(q) rev-list --count \(commit)..HEAD 2>/dev/null")) ?? 0
        guard behind > 0 else { return PackAge(state: .current, commit: commit, behind: 0, changed: [], why: nil) }
        let files = Set(Setup.sh("git -C \(q) diff --name-only \(commit) HEAD 2>/dev/null").split(separator: "\n").map(String.init))
        let changed = parts(titleID).filter { _, inPart in files.contains(where: inPart) }.map(\.0)
        return PackAge(state: changed.isEmpty ? .current : .stale, commit: commit, behind: behind, changed: changed, why: nil)
    }
}

/// Making a pack again after a shader chain change: the prepare step compiles the game's shaders again (dmsh_build), and how long that takes, roughly. From the shaders the
/// game's last build compiled (<build>/logs/dmsh_build.log: "…; N shaders"; Smash's 34929 took about 21 minutes on an M-series Mac), else from the game files' size
enum ShaderRebuild {
    static func minutes(_ g: MacGame) -> Int {
        let log = g.buildDir.flatMap { try? String(contentsOf: $0.appendingPathComponent("logs/dmsh_build.log"), encoding: .utf8) }
        let shaders = log?.split(separator: "\n").reversed().lazy.compactMap { l in l.firstMatch(of: /; (\d+) shaders$/).flatMap { Int($0.1) } }.first
        let base = 8.0   // the host, the library and the pack, which are made again with the shaders
        let m = shaders.map { base + Double($0) / 1700 } ?? base + Double(g.files.reduce(0) { $0 + $1.size }) / 1e9 * 1.5
        return max(10, Int((m / 5).rounded(.up)) * 5)   // in fives: it is an estimate
    }
}
