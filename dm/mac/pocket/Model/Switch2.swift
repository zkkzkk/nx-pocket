// A Switch 2 game as NX Pocket for Mac adds it. nxnative builds one from a folder of its files (a dump: scripts/pack_dump.py) or from one NUP container (a .nup file:
// scripts/pack_nup.py), never from NSPs, and neither needs prod.keys. A dump carries no control data, so the game's name is its profile's and it has no icon; a NUP may carry
// both, which the build extracts (<title ID>_build/extract/v<version>/control.nacp, icon.jpg) and the scan then reads as for any game.
import Foundation

enum Switch2Source: Equatable {
    case dump        // base/ (exefs/, romfs/), updates/<version>/, dlc/<DLC title ID>/<n>/romfs/; or exefs/ and romfs/ in the folder itself
    case nup(URL)    // the folder's one .nup file

    struct Found { let source: Switch2Source; let files: [GameFile]; let titleID: String? }

    /// The folder as a Switch 2 game (the same checks as pack_dump.is_dump and build_ipa_from_nsp.py's nup_file), else nil. A folder's parts are listed as its files with no
    /// size (a RomFS folder holds tens of thousands of files)
    static func scan(_ folder: URL, items: [URL]) -> Found? {
        let fm = FileManager.default
        let nups = items.filter { $0.pathExtension.lowercased() == "nup" && !$0.lastPathComponent.hasPrefix("._") && isNUP($0) }
        if nups.count == 1 {
            let u = nups[0], size = Int64((try? u.resolvingSymlinksInPath().resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            return Found(source: .nup(u), files: [GameFile(url: u, kind: .base, titleID: nil, version: nil, size: size)], titleID: nupTitles[key(u)])
        }
        func hasCode(_ d: URL) -> Bool { fm.fileExists(atPath: d.appendingPathComponent("exefs/main.npdm").path) }
        func hasRomFS(_ d: URL) -> Bool { var dir: ObjCBool = false; return fm.fileExists(atPath: d.appendingPathComponent("romfs").path, isDirectory: &dir) && dir.boolValue }
        let ups = ((try? fm.contentsOfDirectory(at: folder.appendingPathComponent("updates"), includingPropertiesForKeys: nil)) ?? [])
            .compactMap { u in Int(u.lastPathComponent).map { ($0, u) } }.sorted { $0.0 < $1.0 }
        let base = hasCode(folder.appendingPathComponent("base")) ? folder.appendingPathComponent("base") : hasCode(folder) && hasRomFS(folder) ? folder : nil
        guard base.map({ hasRomFS($0) || ups.contains { hasRomFS($0.1) } }) ?? ups.contains(where: { hasCode($0.1) && hasRomFS($0.1) }) else { return nil }
        let code = base ?? ups.last { hasCode($0.1) && hasRomFS($0.1) }!.1
        var files: [GameFile] = []
        if let base { files.append(GameFile(url: base, kind: .base, titleID: nil, version: nil, size: 0)) }
        files += ups.map { GameFile(url: $0.1, kind: .update, titleID: nil, version: $0.0, size: 0) }
        files += ((try? fm.contentsOfDirectory(at: folder.appendingPathComponent("dlc"), includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.count == 16 && UInt64($0.lastPathComponent, radix: 16) != nil }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { GameFile(url: $0, kind: .dlc, titleID: $0.lastPathComponent.uppercased(), version: nil, size: 0) }
        return Found(source: .dump, files: files, titleID: programID(code.appendingPathComponent("exefs/main.npdm")).map { String(format: "%016llX", $0) })
    }

    /// A folder or file dropped from inside a dump (its base/, updates/ or dlc/, or one version's exefs/ or romfs/): the dump folder it belongs to
    static func dumpFolder(containing u: URL) -> URL? {
        var d = u
        for _ in 0..<4 {
            let parent = d.deletingLastPathComponent()
            if ["base", "updates", "dlc"].contains(d.lastPathComponent), scan(parent, items: []) != nil { return parent }
            d = parent
        }
        return nil
    }

    static func isNUP(_ u: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: u) else { return false }
        defer { try? h.close() }
        return (try? h.read(upToCount: 3)) == Data("NUP".utf8)
    }

    /// The ACI0 program ID of main.npdm (pack_dump.program_id): the game's title ID
    static func programID(_ npdm: URL) -> UInt64? {
        guard let d = try? Data(contentsOf: npdm), d.count >= 0x78, d.prefix(4) == Data("META".utf8) else { return nil }
        func u32(_ o: Int) -> Int { d.subdata(in: o..<o + 4).withUnsafeBytes { Int($0.loadUnaligned(as: UInt32.self).littleEndian) } }
        let off = u32(0x70), size = u32(0x74)
        guard size >= 0x18, off + 0x18 <= d.count, d.subdata(in: off..<off + 4) == Data("ACI0".utf8) else { return nil }
        return d.subdata(in: off + 0x10..<off + 0x18).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self).littleEndian }
    }

    /// A NUP's title ID, read by pack_nup.py (AppModel.readNUPTitle) and kept per file, its size and its time
    static func key(_ u: URL) -> String {
        let v = try? u.resolvingSymlinksInPath().resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return "\(u.path)|\(v?.fileSize ?? 0)|\(Int(v?.contentModificationDate?.timeIntervalSince1970 ?? 0))"
    }
    static var nupTitles: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: "nupTitles") as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "nupTitles") }
    }

    /// The game's name in its profile (dm/games/<title ID>/game.tsv: name)
    static func profileName(_ titleID: String?, repo: String) -> String? {
        guard let titleID, !repo.isEmpty,
              let tsv = try? String(contentsOf: URL(fileURLWithPath: repo).appendingPathComponent("dm/games/\(titleID.uppercased())/game.tsv"), encoding: .utf8) else { return nil }
        for line in tsv.split(separator: "\n") {
            let f = line.split(separator: "\t", maxSplits: 1)
            if f.count == 2, f[0] == "name" { return String(f[1]).trimmingCharacters(in: .whitespaces) }
        }
        return nil
    }
}
