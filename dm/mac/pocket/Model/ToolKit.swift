// NX Pocket's tool kit (dm/mac/pocket/tools/make_tools.py): a Python with the build's modules, zstd, glslangValidator and xcodegen in one archive, which Setup downloads
// into Application Support (no Homebrew, no Python install, no password). Its URL, size and SHA-256 come from tools.lock, built into Info.plist (NXPocketTools*);
// a new kit version replaces the old one. curl downloads it: a file curl writes carries no quarantine, so the tools start without Gatekeeper's prompt.
import Foundation

enum ToolKit {
    private static func info(_ key: String) -> String { (Bundle.main.infoDictionary?["NXPocketTools\(key)"] as? String ?? "").trimmingCharacters(in: .whitespaces) }
    static var version: String { info("Version") }
    static var url: String { info("URL") }
    static var sha256: String { info("SHA256") }
    static var size: Int { Int(info("Size")) ?? 0 }
    static var sizeText: String { size > 0 ? ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file) : "" }

    /// ~/Library/Application Support/NX Pocket: the kit (tools/), and the code (Setup.codeFolder)
    static var home: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("NX Pocket") }
    static var dir: URL { home.appendingPathComponent("tools") }
    static var root: String { dir.appendingPathComponent("nx-pocket-tools").path }
    static var python: String { (root as NSString).appendingPathComponent("python/bin/python3") }
    static var bin: String { (root as NSString).appendingPathComponent("bin") }

    /// The kit this app was built with is the one in place (its VERSION file, written last by the install)
    static var installed: Bool {
        guard !version.isEmpty, let v = try? String(contentsOf: dir.appendingPathComponent("VERSION"), encoding: .utf8) else { return false }
        return v.trimmingCharacters(in: .whitespacesAndNewlines) == version && FileManager.default.isExecutableFile(atPath: python)
    }

    /// Download, check, unpack beside the old kit, then swap: a failed or stopped install leaves the old kit (or none) as it was. nil: this build has no kit
    static func installCommand() -> String? {
        guard !url.isEmpty, !sha256.isEmpty else { return nil }
        let d = dir.path.replacingOccurrences(of: "'", with: "'\\''")
        return "rm -rf '\(d).new' && mkdir -p '\(d).new' && cd '\(d).new' && curl -fL --retry 3 --progress-bar -o kit.tar.gz '\(url)' && echo '\(sha256)  kit.tar.gz' | shasum -a 256 -c - "
            + "&& tar -xzf kit.tar.gz && rm kit.tar.gz && echo '\(version)' > VERSION && cd .. && rm -rf '\(d)' && mv '\(d).new' '\(d)'"
    }
}
