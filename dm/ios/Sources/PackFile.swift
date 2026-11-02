// A single-file game pack (pack.json format 3, build_pack.py single_file): the game's RomFS image as it is at the start of the file, then pack.json, icon.png and
// extract.aar (everything else, unpacked once into GameLibrary.unpackedFolder), a table of contents and a trailer at the end. The game reads its files from the pack
// file itself (DM_ROMFS, DM_ROMFS_SIZE: hle_fs.c), so a phone keeps one copy of them. The trailer and the table say whether the file came complete; the small parts'
// SHA-256 whether they came undamaged (the quick check, always); the table's SHA-256 of every 64 MiB whether all of it did (the full check, when the maker put every
// chunk's in: a chunk of the game files may have none, build_pack.py --verify quick). Newer packs carry the shaders as an archive of their own (msl.aar, into msl/).
import Foundation
import CryptoKit
import UniformTypeIdentifiers

extension UTType {
    /// A game pack: a single file (format 3), or a folder named <game>.nxpack (formats 1 and 2). NX Pocket's Info.plist exports it
    static let nxpack = UTType(exportedAs: "org.nxnative.nxpack", conformingTo: .data)
}

struct PackFile {
    struct Member: Decodable { let name: String; let offset: Int64; let size: Int64; let kind: String; let sha256: String?; let folder: String? }   // folder: an archive's, "" or none the pack's own
    struct Contents: Decodable { let format: Int; let members: [Member]; let chunk: Int64; let sha256: [String?] }

    enum Failure: LocalizedError {
        case incomplete(Int64, Int64?), damaged(Int, Int), damagedPart(String), unreadable(String)
        var errorDescription: String? {
            switch self {
            case .incomplete(let got, let want):
                let g = ByteCountFormatter.string(fromByteCount: got, countStyle: .file)
                return want.map { String(format: tr("The game pack did not arrive complete (%@ of %@). Send it again."), g, ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)) }
                    ?? String(format: tr("The game pack did not arrive complete (%@ received). Send it again."), g)
            case .damaged(let part, let of): return String(format: tr("The game pack is damaged (part %d of %d does not match). Send it again."), part, of)
            case .damagedPart(let name): return String(format: tr("The game pack is damaged (%@ does not match). Send it again."), name)
            case .unreadable(let why): return String(format: tr("The game pack could not be read: %@"), why)
            }
        }
    }

    static let magic = Data("NXPACK3\0".utf8)
    static let trailer = 4096

    let url: URL
    let contents: Contents
    let length: Int64
    private let tocOffset: Int64

    /// A regular file named .nxpack (not a pack folder)
    static func isFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
    }

    /// Reads the trailer and the table of contents: throws `incomplete` for a file cut off on the way (its trailer missing or its length short), `unreadable` else
    init(_ url: URL) throws {
        self.url = url
        guard let h = try? FileHandle(forReadingFrom: url) else { throw Failure.unreadable(url.lastPathComponent) }
        defer { try? h.close() }
        let size = Int64((try? h.seekToEnd()) ?? 0)
        guard size >= Int64(Self.trailer) else { throw Failure.incomplete(size, nil) }
        try? h.seek(toOffset: UInt64(size) - UInt64(Self.trailer))
        guard let t = try? h.read(upToCount: Self.trailer), t.count == Self.trailer,
              t.prefix(8) == Self.magic, t.suffix(8) == Self.magic else { throw Failure.incomplete(size, nil) }
        func u64(_ at: Int) -> Int64 { t.subdata(in: at..<at + 8).withUnsafeBytes { Int64(littleEndian: $0.loadUnaligned(as: Int64.self)) } }
        let total = u64(16), toc = u64(24), tocSize = u64(32)
        guard total == size else { throw Failure.incomplete(size, total) }
        guard toc > 0, tocSize > 0, tocSize < 64 << 20, toc + tocSize <= size - Int64(Self.trailer) else { throw Failure.unreadable(tr("its table of contents is out of place")) }
        try? h.seek(toOffset: UInt64(toc))
        guard let data = try? h.read(upToCount: Int(tocSize)), data.count == Int(tocSize) else { throw Failure.unreadable(tr("its table of contents is cut off")) }
        guard Data(SHA256.hash(data: data)) == t.subdata(in: 40..<72) else { throw Failure.unreadable(tr("its table of contents does not match its checksum")) }
        guard let c = try? JSONDecoder().decode(Contents.self, from: data), c.chunk > 0, c.sha256.count == Int((toc + c.chunk - 1) / c.chunk),
              c.members.allSatisfy({ $0.offset >= 0 && $0.size >= 0 && $0.offset + $0.size <= toc }) else { throw Failure.unreadable(tr("its table of contents is not valid")) }
        contents = c; length = size; tocOffset = toc
    }

    func member(_ name: String) -> Member? { contents.members.first { $0.name == name } }
    /// The archives to unpack, in order: the pack's own (extract.aar) first, then those into a folder of it (msl.aar)
    var archives: [Member] { contents.members.filter { $0.kind == "archive" }.sorted { ($0.folder ?? "").isEmpty && !($1.folder ?? "").isEmpty } }
    /// Every chunk has its checksum: the full check can be made
    var fullyHashed: Bool { !contents.sha256.contains(nil) }

    /// The quick check: the small parts' checksums (pack.json, icon.png, the archives; not the game files). `progress` gets the bytes read of the total
    func quickCheck(progress: (Int64, Int64) -> Void = { _, _ in }, cancelled: () -> Bool = { false }) throws {
        let parts = contents.members.filter { $0.kind != "romfs" && $0.sha256 != nil }
        let total = parts.reduce(0) { $0 + $1.size }
        guard let h = try? FileHandle(forReadingFrom: url) else { throw Failure.unreadable(url.lastPathComponent) }
        defer { try? h.close() }
        var done: Int64 = 0
        for m in parts {
            var sha = SHA256(), left = m.size
            try h.seek(toOffset: UInt64(m.offset))
            while left > 0 {
                if cancelled() { throw CancellationError() }
                guard let d = try h.read(upToCount: Int(min(left, 8 << 20))), !d.isEmpty else { throw Failure.incomplete(length, nil) }
                sha.update(data: d); left -= Int64(d.count); done += Int64(d.count); progress(done, total)
            }
            if sha.finalize().map({ String(format: "%02x", $0) }).joined() != m.sha256 { throw Failure.damagedPart(m.name) }
        }
    }
    /// The game files' length: where the RomFS image ends in the file
    var romfsSize: Int64? { contents.members.first { $0.kind == "romfs" }?.size }

    /// A small member's bytes (pack.json, icon.png)
    func data(_ name: String) -> Data? {
        guard let m = member(name), m.size <= 16 << 20, let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        try? h.seek(toOffset: UInt64(m.offset))
        return try? h.read(upToCount: Int(m.size))
    }

    /// The full check: every chunk against the table (those with a checksum), several at a time, each read in 4 MiB pieces. `progress` gets the bytes checked so far of
    /// the total (any thread); throws `damaged` for the first chunk that differs, CancellationError once `cancelled` says so
    func verify(progress: (Int64, Int64) -> Void, cancelled: () -> Bool) throws {
        let n = contents.sha256.count, chunk = contents.chunk, end = tocOffset
        let lock = NSLock()
        var bad: Int?, stop = false, done: Int64 = 0
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw Failure.unreadable(url.lastPathComponent) }
        defer { close(fd) }
        var next = 0
        let workers = max(2, min(ProcessInfo.processInfo.activeProcessorCount, 6))
        DispatchQueue.concurrentPerform(iterations: workers) { _ in
            let buf = UnsafeMutableRawPointer.allocate(byteCount: 4 << 20, alignment: 16)
            defer { buf.deallocate() }
            while true {
                let i: Int? = lock.withLock { while next < n && contents.sha256[next] == nil { next += 1 }; if stop || next >= n { return nil }; defer { next += 1 }; return next }
                guard let i else { return }
                var h = SHA256(), off = Int64(i) * chunk
                var left = min(chunk, end - off)
                while left > 0 {
                    let r = pread(fd, buf, Int(min(left, 4 << 20)), off)
                    if r <= 0 { lock.withLock { bad = bad ?? i; stop = true }; return }
                    h.update(bufferPointer: UnsafeRawBufferPointer(start: buf, count: r))
                    off += Int64(r); left -= Int64(r)
                    let d = lock.withLock { done += Int64(r); return done }
                    progress(d, end)
                    if cancelled() { lock.withLock { stop = true }; return }
                }
                let hex = h.finalize().map { String(format: "%02x", $0) }.joined()
                if hex != contents.sha256[i] { lock.withLock { bad = min(bad ?? i, i); stop = true }; return }
            }
        }
        if let bad { throw Failure.damaged(bad + 1, n) }
        if cancelled() { throw CancellationError() }
    }
}
