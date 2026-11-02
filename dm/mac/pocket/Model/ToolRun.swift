// Running a script or tool for NX Pocket for Mac, with its output as it comes. Adapted from NX Play (github.com/varyform/nx-native-wrapper,
// Packages/NXPlayKit/Sources/NXPlayKit/Model/Job.swift, LineSplitter.swift, LogBuffer.swift; MIT License, Copyright (c) 2026 Oleh Khomei, the notice in full in
// BuildProgress.swift): the process in a group of its own and stopped as a whole (SIGINT, which the build script stops cleanly on, then SIGTERM, then SIGKILL),
// output and errors through one pipe so the lines keep their order, split into lines with "\r" honoured.
import Foundation

/// The environment a tool starts with: a Finder-started app has a bare PATH, so Homebrew's and .NET's folders go first; Xcode's library injections are dropped;
/// Python writes as it goes. A player whose tools live elsewhere (another drive, a portable Python) names a shell script that sets them up (Settings,
/// "Environment script"): it is sourced once and what it exports applies to every check and build
enum ToolEnvironment {
    private static var sourced: (String, [String: String])?
    static func scripted() -> [String: String] {
        let script = UserDefaults.standard.string(forKey: "envScript") ?? ""
        guard !script.isEmpty, FileManager.default.isReadableFile(atPath: script) else { return [:] }
        if let s = sourced, s.0 == script { return s.1 }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", "source \"$0\" >/dev/null 2>&1; env -0", script]
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [:] }
        let data = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        var env: [String: String] = [:]
        for entry in data.split(separator: 0) { let s = String(decoding: entry, as: UTF8.self); if let i = s.firstIndex(of: "=") { env[String(s[..<i])] = String(s[s.index(after: i)...]) } }
        sourced = (script, env)
        return env
    }
    static func make(_ extra: [String: String] = [:]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment.merging(scripted()) { $1 }
        for k in env.keys where k.hasPrefix("DYLD_") || k.hasPrefix("__XCODE") { env[k] = nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "\(home)/.dotnet", "/usr/local/share/dotnet", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        env["PATH"] = (path + (env["PATH"] ?? "").split(separator: ":").map(String.init)).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.joined(separator: ":")
        env["PYTHONUNBUFFERED"] = "1"
        if env["TMPDIR"] == nil { env["TMPDIR"] = NSTemporaryDirectory() }   // .NET's NuGet needs one
        return env.merging(extra) { $1 }
    }
}

/// Splits bytes into lines as they come; "\r" (a progress bar redrawing) ends a line too
final class LineSplitter {
    private var pending = Data()
    func feed(_ data: Data) -> [String] {
        pending.append(data)
        var lines: [String] = []
        while let i = pending.firstIndex(where: { $0 == 10 || $0 == 13 }) {
            let line = String(decoding: pending[pending.startIndex..<i], as: UTF8.self)
            pending.removeSubrange(pending.startIndex...i)
            if !line.isEmpty { lines.append(line) }
        }
        return lines
    }
    func finish() -> [String] {
        defer { pending.removeAll() }
        let rest = String(decoding: pending, as: UTF8.self)
        return rest.isEmpty ? [] : [rest]
    }
}

/// One run of a tool: its live output (parsed for the scripts' progress events) and how it ended
@MainActor final class ToolRun: ObservableObject, Identifiable {
    enum Status: Equatable { case running, succeeded, failed(Int32), cancelled }

    let id = UUID()
    let title: String
    @Published private(set) var status: Status = .running
    @Published private(set) var progress: BuildProgress?
    @Published private(set) var finished: [FinishedStage] = []
    @Published private(set) var problems: [String] = []
    @Published private(set) var log: [String] = []
    var onFinish: ((ToolRun) -> Void)?

    private var process: Process?
    private var reader = BuildOutputReader()
    private var exitCode: Int32?, outputClosed = false, stopping = false
    static let logLimit = 20_000

    init(title: String) { self.title = title }

    /// Starts `executable` with `arguments` in `directory`
    func start(_ executable: String, _ arguments: [String], directory: URL? = nil, environment: [String: String] = [:]) {
        append(["$ " + ([executable] + arguments).map { $0.contains(" ") ? "'\($0)'" : $0 }.joined(separator: " ")])
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        p.environment = ToolEnvironment.make(environment)
        if let directory { p.currentDirectoryURL = directory }
        p.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        let splitter = LineSplitter()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData, closed = data.isEmpty
            if closed { h.readabilityHandler = nil }
            let lines = closed ? splitter.finish() : splitter.feed(data)
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.received(lines, closed: closed) } }
        }
        p.terminationHandler = { [weak self] p in
            let code = p.terminationStatus
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.exited(code) } }
        }
        do { try p.run(); process = p }
        catch { pipe.fileHandleForReading.readabilityHandler = nil; append(["cannot start \(executable): \(error.localizedDescription)"]); finish(.failed(-1)) }
    }

    /// Stops the whole process tree: SIGINT first (the build script stops cleanly on it), then SIGTERM and SIGKILL for what ignores it
    func stop() {
        guard status == .running, let process, process.isRunning, !stopping else { return }
        stopping = true
        append([tr("Stopping…")])
        let group = process.processIdentifier
        if kill(-group, SIGINT) != 0 { process.interrupt() }
        for (i, sig) in [SIGTERM, SIGKILL].enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5 * Double(i + 1)) { _ = kill(-group, sig); _ = kill(group, sig) }
        }
    }

    func note(_ line: String) { append([line]) }

    private func append(_ lines: [String]) {
        log.append(contentsOf: lines)
        if log.count > Self.logLimit { log.removeFirst(log.count - Self.logLimit) }
    }

    private func received(_ lines: [String], closed: Bool) {
        if !lines.isEmpty {
            append(lines.flatMap { reader.read($0) })
            if reader.progress != progress { progress = reader.progress }
            if reader.finished != finished { finished = reader.finished }
            if reader.problems != problems { problems = reader.problems }
        }
        if closed { outputClosed = true; finishIfDone() }
    }
    private func exited(_ code: Int32) {
        exitCode = code
        finishIfDone()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.outputClosed = true; self?.finishIfDone() }   // a child left holding the pipe
    }
    private func finishIfDone() {
        guard status == .running, outputClosed, let exitCode else { return }
        process = nil
        finish(stopping ? .cancelled : exitCode == 0 ? .succeeded : .failed(exitCode))
    }
    private func finish(_ s: Status) {
        status = s
        onFinish?(self)
    }
}
