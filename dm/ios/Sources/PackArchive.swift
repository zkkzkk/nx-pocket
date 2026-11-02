// A game pack's folders of many small files (msl/: the shader libraries, tens of thousands of files) travel as one Apple Archive (<folder>.aar, made by build_pack.py with
// `aa archive`): copying a pack to a phone then moves a few large files, not a hundred thousand small ones (devicectl and the Files app slow down and drop the
// connection on those). NX Pocket unpacks such an archive once, on the phone, before the game first starts (pack.json format 2, GameLibrary.swift PackInfo).
// AppleArchive is public on iOS and macOS alike, so the Mac tools can use this too.
import Foundation
import AppleArchive
import System

enum PackArchive {
    enum Failure: LocalizedError {
        case open(String), extract(String)
        var errorDescription: String? {
            switch self {
            case .open(let p): return String(format: tr("The archive %@ could not be opened."), p)
            case .extract(let p): return String(format: tr("The archive %@ could not be unpacked."), p)
            }
        }
    }

    /// Unpacks the archive at `archive` into `folder` (made when missing): into `<folder>.partial` first, moved into place once complete, so an interrupted unpack
    /// leaves no half folder that looks done. `range`: the archive is that part of the file (a single-file pack's extract.aar, PackFile.swift). `progress` (any thread)
    /// gets the share of the archive read so far, 0…1. Returns the number of entries written
    @discardableResult static func unpack(_ archive: URL, range: Range<Int64>? = nil, into folder: URL, progress: ((Double) -> Void)? = nil) throws -> Int {
        let fm = FileManager.default
        let part = folder.deletingLastPathComponent().appendingPathComponent(folder.lastPathComponent + ".partial", isDirectory: true)
        try? fm.removeItem(at: part)
        try fm.createDirectory(at: part, withIntermediateDirectories: true)
        let opened: ArchiveByteStream?
        if progress != nil || range != nil, let fd = try? FileDescriptor.open(FilePath(archive.path), .readOnly) {
            let size = (try? fm.attributesOfItem(atPath: archive.path)[.size] as? Int64) ?? 0
            opened = ArchiveByteStream.customStream(instance: CountingReader(fd, range: range ?? 0..<size, progress: progress ?? { _ in }))
        } else {
            opened = ArchiveByteStream.fileStream(path: FilePath(archive.path), mode: .readOnly, options: [], permissions: FilePermissions(rawValue: 0o644))
        }
        guard let file = opened else { throw Failure.open(archive.lastPathComponent) }
        defer { try? file.close() }
        guard let decompress = ArchiveByteStream.decompressionStream(readingFrom: file) else { throw Failure.open(archive.lastPathComponent) }
        defer { try? decompress.close() }
        guard let decode = ArchiveStream.decodeStream(readingFrom: decompress) else { throw Failure.open(archive.lastPathComponent) }
        defer { try? decode.close() }
        guard let extract = ArchiveStream.extractStream(extractingTo: FilePath(part.path), flags: [.ignoreOperationNotPermitted]) else { throw Failure.extract(archive.lastPathComponent) }
        defer { try? extract.close() }
        let n: Int
        do { n = try ArchiveStream.process(readingFrom: decode, writingTo: extract) } catch { try? fm.removeItem(at: part); throw Failure.extract(archive.lastPathComponent) }
        try? extract.close()
        try? fm.removeItem(at: folder)
        try fm.moveItem(at: part, to: folder)
        return n
    }
}

/// The archive read through a counter, as a part of its file (`range`; the whole file for an archive of its own): how much of it the unpacking has read is its progress
/// (the archive is read once, front to back)
private final class CountingReader: ArchiveByteStreamProtocol {
    private let fd: FileDescriptor, range: Range<Int64>, progress: (Double) -> Void
    private var pos: Int64 = 0, got: Int64 = 0, told = -1.0
    init(_ fd: FileDescriptor, range: Range<Int64>, progress: @escaping (Double) -> Void) { self.fd = fd; self.range = range; self.progress = progress }
    private var size: Int64 { range.upperBound - range.lowerBound }
    private func count(_ n: Int) {
        got += Int64(n)
        let f = size > 0 ? min(Double(got) / Double(size), 1) : 0
        if f - told >= 0.005 || f == 1 { told = f; progress(f) }   // every half percent
    }
    private func readAt(_ buffer: UnsafeMutableRawBufferPointer, _ at: Int64) throws -> Int {   // never past the part's end
        let want = Int(max(0, min(Int64(buffer.count), size - at)))
        guard want > 0 else { return 0 }
        let n = try fd.read(fromAbsoluteOffset: range.lowerBound + at, into: UnsafeMutableRawBufferPointer(rebasing: buffer[0..<want]))
        count(n); return n
    }
    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int { let n = try readAt(buffer, pos); pos += Int64(n); return n }
    func read(into buffer: UnsafeMutableRawBufferPointer, atOffset offset: Int64) throws -> Int { try readAt(buffer, offset) }
    func write(from buffer: UnsafeRawBufferPointer) throws -> Int { throw Errno.badFileDescriptor }
    func write(from buffer: UnsafeRawBufferPointer, atOffset offset: Int64) throws -> Int { throw Errno.badFileDescriptor }
    func seek(toOffset offset: Int64, relativeTo origin: FileDescriptor.SeekOrigin) throws -> Int64 {
        switch origin {
        case .start: pos = offset
        case .current: pos += offset
        case .end: pos = size + offset
        default: throw Errno.invalidArgument
        }
        return pos
    }
    func cancel() {}
    func close() throws { try fd.close() }
}
