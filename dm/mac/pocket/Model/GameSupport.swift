// How far nxnative supports a game, from this checkout's game profiles (dm/games/README.md): a profile folder dm/games/<title ID> or none, its README's status line
// (or its first paragraph) and validated.tsv (the chain the game was last green on). Shown when a game is added, before anything is built: a game with no profile can be
// packed (the NSP script surveys it and makes a provisional profile), but it most likely does not run.
import Foundation

struct GameSupport: Equatable {
    enum Level { case tested, inProgress, none }
    let level: Level
    let note: String?      // the README's status, in its own words (English)
    let readme: URL?
    let validated: String? // validated.tsv's newest row: the chain and the date

    static func of(_ titleID: String?, repo: String) -> GameSupport {
        guard let titleID, !repo.isEmpty else { return GameSupport(level: .none, note: nil, readme: nil, validated: nil) }
        let dir = URL(fileURLWithPath: repo).appendingPathComponent("dm/games/\(titleID.uppercased())", isDirectory: true)
        guard FileManager.default.fileExists(atPath: dir.appendingPathComponent("game.tsv").path) else { return GameSupport(level: .none, note: nil, readme: nil, validated: nil) }
        let readme = dir.appendingPathComponent("README.md")
        let text = (try? String(contentsOf: readme, encoding: .utf8)) ?? ""
        let note = statusLine(text)
        let validated = (try? String(contentsOf: dir.appendingPathComponent("validated.tsv"), encoding: .utf8))?
            .split(separator: "\n").last { !$0.hasPrefix("#") && !$0.isEmpty }
            .map { $0.split(separator: "\t").dropFirst().joined(separator: " ") }
        return GameSupport(level: playsOnPhone(note ?? "") ? .tested : .inProgress, note: note, readme: FileManager.default.fileExists(atPath: readme.path) ? readme : nil, validated: validated)
    }

    /// The README's "Status:" line, else its first paragraph under the title; Markdown links and emphasis taken out
    static func statusLine(_ md: String) -> String? {
        let lines = md.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let line = lines.first { $0.hasPrefix("Status:") || $0.hasPrefix("**Status") } ?? lines.dropFirst().first { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix("|") }
        guard var s = line else { return nil }
        s = s.replacing(/\[([^\]]+)\]\([^)]*\)/) { String($0.1) }.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
        if s.hasPrefix("Status:") { s = String(s.dropFirst(7)) }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// Whether the note says the game plays on an iPhone (a sentence naming the iPhone as playable, not as untested)
    static func playsOnPhone(_ note: String) -> Bool {
        note.split(whereSeparator: { ".;".contains($0) }).contains { s in
            let t = s.lowercased()
            return t.contains("iphone") && (t.contains("plays") || t.contains("playable") || t.contains("gameplay")) && !t.contains("not ") && !t.contains("untested")
        }
    }
}
