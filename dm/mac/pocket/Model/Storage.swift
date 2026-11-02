// What NX Pocket for Mac's games take on disk: each game's build folder (<title ID>_build: the extracted game, the rewritten code, the shaders, the Xcode
// project and its build) and its game pack, and the game pack folder's other packs (of games not in the list); deleting any after the player confirms. Sizes are what
// the files allocate (du; a link's file, not the link), off the main thread.
import Foundation

struct StorageRow: Identifiable, Equatable {
    let id: MacGame.ID
    let name: String
    let build: URL?, pack: URL?
    var buildBytes: Int64?, packBytes: Int64?   // nil: still being measured
    var total: Int64? { buildBytes.flatMap { b in packBytes.map { b + $0 } } }
}

enum Storage {
    /// Allocated bytes under `url` (du -sk), 0 when it is gone
    static func size(_ url: URL?) -> Int64 {
        guard let url = url?.resolvingSymlinksInPath(), FileManager.default.fileExists(atPath: url.path) else { return 0 }
        let kb = Setup.sh("du -sk '\(url.path.replacingOccurrences(of: "'", with: "'\\''"))' 2>/dev/null | cut -f1")
        return (Int64(kb) ?? 0) * 1024
    }
    /// The rows, unmeasured: the window lists the games at once and fills the sizes in as they come; then the packs in the game pack folder no game in the list has
    static func rows(_ games: [MacGame], packs: [PackEntry]) -> [StorageRow] {
        let mine = Set(games.compactMap { $0.pack?.resolvingSymlinksInPath().standardizedFileURL })
        return games.map { g in StorageRow(id: g.id, name: g.name, build: g.buildDir, pack: g.pack) }
             + packs.filter { !mine.contains($0.url.resolvingSymlinksInPath().standardizedFileURL) }
                    .map { StorageRow(id: $0.url.path, name: $0.name ?? $0.url.deletingPathExtension().lastPathComponent, build: nil, pack: $0.url, buildBytes: 0) }
    }
}
