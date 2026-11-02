// iPhones for NX Pocket for Mac: the connected ones (xcrun devicectl list devices; the parsing after NX Play's Device.swift, MIT, the notice in BuildProgress.swift),
// whether NX Pocket is on one (its bundle ID found by its name, so a build signed by anyone is found), and sending a game pack into its Documents/Games
// (devicectl device copy to, one top-level item at a time, each tried again when the connection drops).
import Foundation

struct Device: Hashable, Identifiable {
    let id: String          // the UDID devicectl takes
    let name: String
    let model: String
    let osVersion: String
    let connected: Bool     // reachable now (paired devices also show while away)

    static func parse(json: Data) -> [Device] {
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let list = (root["result"] as? [String: Any])?["devices"] as? [[String: Any]] else { return [] }
        return list.compactMap { e in
            let hw = e["hardwareProperties"] as? [String: Any] ?? [:], dp = e["deviceProperties"] as? [String: Any] ?? [:], cp = e["connectionProperties"] as? [String: Any] ?? [:]
            guard hw["platform"] as? String == "iOS", hw["reality"] as? String == "physical", cp["pairingState"] as? String == "paired", let udid = hw["udid"] as? String else { return nil }
            return Device(id: udid, name: dp["name"] as? String ?? udid, model: hw["marketingName"] as? String ?? hw["deviceType"] as? String ?? "",
                          osVersion: dp["osVersionNumber"] as? String ?? "", connected: (cp["tunnelState"] as? String).map { $0 != "unavailable" } ?? false)
        }
        .sorted { ($0.connected ? 0 : 1, $0.name) < ($1.connected ? 0 : 1, $1.name) }
    }

    /// devicectl with its JSON output, off the main thread; nil when it failed
    static func devicectl(_ args: [String], timeout: TimeInterval = 40) async -> Data? {
        await Task.detached {
            let out = FileManager.default.temporaryDirectory.appendingPathComponent("nxpocket-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: out) }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            p.arguments = ["devicectl"] + args + ["--json-output", out.path, "-q"]
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return nil }
            let deadline = Date().addingTimeInterval(timeout)
            while p.isRunning && Date() < deadline { try? await Task.sleep(nanoseconds: 100_000_000) }
            if p.isRunning { p.terminate(); return nil }
            return try? Data(contentsOf: out)
        }.value
    }

    static func load() async -> [Device] { await devicectl(["list", "devices"]).map(parse(json:)) ?? [] }

    /// The bundle ID of the app named NX Pocket on the device, nil when there is none
    static func pocketBundleID(on device: Device) async -> String? { await pocket(on: device)??.bundleID }

    /// NX Pocket on the device: its bundle ID and build number (the commit count it was built from, build_pocket.py); .some(nil) when it is not there, nil when the
    /// device could not be asked
    static func pocket(on device: Device) async -> InstalledPocket?? {
        guard let data = await devicectl(["device", "info", "apps", "--device", device.id]),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let apps = (root["result"] as? [String: Any])?["apps"] as? [[String: Any]] else { return nil }
        guard let a = apps.first(where: { ($0["name"] as? String) == "NX Pocket" }), let id = a["bundleIdentifier"] as? String else { return .some(nil) }
        return .some(InstalledPocket(bundleID: id, build: Int(a["bundleVersion"] as? String ?? "") ?? 0))
    }
}

struct InstalledPocket: Equatable {
    let bundleID: String
    let build: Int   // 1: a build from before build numbers
}

/// Sending a game pack to a device: a single-file pack (format 3) as it is, a pack folder's top-level items one by one (a few hundred files in a format 2 pack), each
/// tried up to three times; the bytes sent so far
@MainActor final class PackSender: ObservableObject {
    @Published private(set) var item = ""          // what is being sent
    @Published private(set) var index = 0
    @Published private(set) var count = 0
    @Published private(set) var sent: Int64 = 0
    @Published private(set) var total: Int64 = 0
    @Published private(set) var failure: String?
    @Published private(set) var done = false
    @Published private(set) var stopped = false   // Stop: over at once, whatever it was doing (sending again is possible)
    @Published var phase = ""                     // what it is doing before the bytes go (finding NX Pocket on the iPhone…)
    @Published private(set) var estimating = false   // `sent` is worked out from the time (devicectl says nothing as it copies), not counted
    let run: ToolRun
    private var cancelled = false
    private var current: Process?   // the copy in progress, ended by Cancel

    init(title: String) { run = ToolRun(title: title) }
    var fraction: Double { total > 0 ? min(Double(sent) / Double(total), 1) : 0 }
    /// Over: sent, failed or stopped; a new send of the game may start
    var finished: Bool { done || failure != nil || stopped }

    func cancel() {
        guard !finished else { return }
        cancelled = true; stopped = true; current?.terminate()
        run.note(tr("Sending stopped."))
    }
    func fail(_ why: String) { guard !finished else { return }; failure = why; run.note(why) }

    /// Sends `pack` to `device`'s app `bundleID`, into Documents/Games/<pack's name>
    func send(_ pack: URL, to device: Device, bundleID: String) async {
        let fm = FileManager.default
        let file = PackFile.isFile(pack)
        phase = ""
        let items = file ? [pack] : ((try? fm.contentsOfDirectory(at: pack, includingPropertiesForKeys: nil)) ?? []).filter { !$0.lastPathComponent.hasPrefix(".") }
            .sorted { size($0) < size($1) }   // the small ones first: pack.json and the icon show the game early, romfs.img goes last
        count = items.count; total = items.reduce(0) { $0 + size($1) }
        for (i, u) in items.enumerated() {
            if cancelled { break }
            index = i + 1; item = u.lastPathComponent
            var ok = false
            let dest = file ? "Documents/Games/\(pack.lastPathComponent)" : "Documents/Games/\(pack.lastPathComponent)/\(u.lastPathComponent)"
            let before = sent, bytes = size(u), t0 = Date()
            // devicectl says nothing while it copies (not even to a terminal), and the iPhone answers nothing else until it is done: how far it is is estimated from the
            // time and the speed the last send went at (kept), never past 97% until it ends
            let rate = max(UserDefaults.standard.double(forKey: "sendRate"), 5e6), d = UserDefaults.standard.double(forKey: "sendRate") > 0 ? rate : 40e6
            estimating = bytes > 32 << 20
            let watch = estimating ? Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    guard let self, !Task.isCancelled else { return }
                    self.sent = before + min(Int64(Date().timeIntervalSince(t0) * d), bytes * 97 / 100)
                }
            } : nil
            for attempt in 1...3 where !cancelled {
                if attempt > 1 { run.note(String(format: tr("Connection lost; trying %@ again (%d of 3)…"), u.lastPathComponent, attempt)) }
                ok = await copy(u, to: dest, device: device, bundleID: bundleID)
                if ok { break }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            watch?.cancel(); estimating = false
            if !ok { if !cancelled { fail(String(format: tr("%@ could not be sent. Check the cable and that the iPhone is unlocked, then send again."), u.lastPathComponent)) }; break }
            sent = before + bytes
            let took = Date().timeIntervalSince(t0)
            if bytes > 256 << 20, took > 1 { UserDefaults.standard.set(Double(bytes) / took, forKey: "sendRate") }   // the next estimate's speed
        }
        done = !cancelled && failure == nil
        if done { run.note(tr("Sent. Open NX Pocket on the iPhone: the game is in its library.")) }
    }

    private func copy(_ src: URL, to dest: String, device: Device, bundleID: String) async -> Bool {
        run.note("→ \(src.lastPathComponent) (\(ByteCountFormatter.string(fromByteCount: size(src), countStyle: .file)))")
        return await withCheckedContinuation { c in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            p.arguments = ["devicectl", "device", "copy", "to", "--device", device.id, "--domain-type", "appDataContainer", "--domain-identifier", bundleID,
                           "--source", src.path, "--destination", dest]
            p.standardOutput = FileHandle.nullDevice
            let err = Pipe(); p.standardError = err
            self.current = p
            p.terminationHandler = { p in
                let text = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                Task { @MainActor in
                    if p.terminationStatus != 0 { self.run.note(text.split(separator: "\n").suffix(3).joined(separator: " ")) }
                    c.resume(returning: p.terminationStatus == 0)
                }
            }
            do { try p.run() } catch { c.resume(returning: false) }
        }
    }

    func size(_ u: URL) -> Int64 {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue { return Int64((try? u.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
        var n: Int64 = 0
        for case let f as URL in FileManager.default.enumerator(at: u, includingPropertiesForKeys: [.fileSizeKey]) ?? FileManager.DirectoryEnumerator() {
            n += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return n
    }
}
