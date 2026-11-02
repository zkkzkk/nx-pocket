// What making game packs needs (README, "Packing"), checked on this Mac and installed where a command can do it: Xcode 27.1 with its iOS platform and Metal
// toolchain, Homebrew with xcodegen, zstd and glslang, the .NET SDK, a Python 3.12+ (arm64) with the build's modules, this nxnative checkout, and the player's
// own prod.keys (only its path is kept). After NX Play's setup (github.com/varyform/nx-native-wrapper, MIT, the notice in BuildProgress.swift); NX Pocket runs
// the checks itself instead of a setup script.
import Foundation

struct SetupItem: Identifiable, Equatable {
    enum State: Equatable { case ok, missing, optional, checking }
    let id: String
    let title: String
    let detail: String
    let state: State
    var install: SetupAction? = nil
}

/// How a missing item is fixed: a command run here, a page opened, or a file or folder chosen
enum SetupAction: Equatable {
    case command(String)      // run with bash -lc, its output in the setup log
    case open(String)         // a URL
    case chooseRepo, chooseKeys, choosePython, chooseEnv
}

enum Setup {
    static let pythonModules = ["lz4", "capstone", "fontTools", "nsz"]   // zbic: only some games' files need it (checked, not required)

    /// The checks, slow ones included (Python's imports): call off the main thread
    static func check(repo: String, keys: String, python: String) -> [SetupItem] {
        var items: [SetupItem] = []
        let xcode = sh("xcodebuild -version 2>/dev/null | head -1")
        let xv = xcode.split(separator: " ").last.map(String.init) ?? ""
        items.append(SetupItem(id: "xcode", title: "Xcode", detail: xcode.isEmpty ? tr("Xcode 27.1 or later, from the App Store") : xcode,
                               state: xcode.isEmpty || xv.compare("27.1", options: .numeric) == .orderedAscending ? .missing : .ok,
                               install: .open("macappstore://apps.apple.com/app/id497799835")))
        let ios = sh("xcodebuild -showsdks 2>/dev/null | grep -c iphoneos")
        items.append(SetupItem(id: "ios", title: tr("iOS platform"), detail: tr("Xcode → Settings → Components"), state: (Int(ios) ?? 0) > 0 ? .ok : .missing,
                               install: .command("xcodebuild -downloadPlatform iOS")))
        let metal = sh("xcrun -f metal 2>/dev/null")
        items.append(SetupItem(id: "metal", title: tr("Metal toolchain"), detail: metal.isEmpty ? "xcodebuild -downloadComponent MetalToolchain" : tr("Installed"),
                               state: metal.isEmpty ? .missing : .ok, install: .command("xcodebuild -downloadComponent MetalToolchain")))
        let brew = sh("command -v brew")
        let tools = ["xcodegen", "zstd", "glslangValidator"].filter { sh("command -v \($0)").isEmpty }
        items.append(SetupItem(id: "brew", title: "Homebrew", detail: brew.isEmpty ? (tools.isEmpty ? tr("Not needed: the tools are already installed") : "brew.sh") : brew,
                               state: !brew.isEmpty ? .ok : tools.isEmpty ? .optional : .missing, install: brew.isEmpty && !tools.isEmpty ? .open("https://brew.sh") : nil))
        items.append(SetupItem(id: "tools", title: "xcodegen · zstd · glslang", detail: tools.isEmpty ? tr("Installed") : String(format: tr("Missing: %@"), tools.joined(separator: ", ")),
                               state: tools.isEmpty ? .ok : .missing, install: .command("brew install xcodegen zstd glslang")))
        let dotnet = sh("dotnet --list-runtimes 2>/dev/null | grep -c 'Microsoft.NETCore.App 10'")
        items.append(SetupItem(id: "dotnet", title: ".NET SDK", detail: (Int(dotnet) ?? 0) > 0 ? tr("Installed") : tr("The shader translator needs .NET 10"),
                               state: (Int(dotnet) ?? 0) > 0 ? .ok : .missing, install: .command("brew install --cask dotnet-sdk")))
        let pv = python.isEmpty ? "" : sh("'\(python)' -c 'import sys,platform; print(\"%d.%d %s\" % (sys.version_info[0], sys.version_info[1], platform.machine()))' 2>/dev/null")
        let parts = pv.split(separator: " "), ver = parts.first.map(String.init) ?? "", arch = parts.count > 1 ? String(parts[1]) : ""
        let pyOK = !ver.isEmpty && ver.compare("3.12", options: .numeric) != .orderedAscending && arch == "arm64"
        let missingMods = pyOK ? pythonModules.filter { sh("'\(python)' -c 'import \($0)' 2>/dev/null && echo y") != "y" } : pythonModules
        let venv = repo.isEmpty ? "" : (repo as NSString).appendingPathComponent(".venv")
        let zbic = pyOK && sh("'\(python)' -c 'import zbic' 2>/dev/null && echo y") == "y"
        items.append(SetupItem(id: "python", title: "Python 3.12+", detail: python.isEmpty ? tr("Not chosen") : !pyOK ? String(format: tr("%@ is not an arm64 Python 3.12 or later"), python)
                                                                : missingMods.isEmpty ? "\(python) (\(ver))" : String(format: tr("Missing modules: %@"), missingMods.joined(separator: ", ")),
                               state: pyOK && missingMods.isEmpty ? (zbic ? .ok : .optional) : .missing,
                               install: venv.isEmpty ? .choosePython : .command("python3 -m venv '\(venv)' && '\(venv)/bin/pip' install lz4 'capstone>=5,<6' fonttools nsz zbic \"backports.zstd; python_version < '3.14'\"")))
        let repoOK = !repo.isEmpty && FileManager.default.fileExists(atPath: (repo as NSString).appendingPathComponent("scripts/build_ipa_from_nsp.py"))
        if pyOK && missingMods.isEmpty && !zbic { items[items.count - 1] = SetupItem(id: "python", title: "Python 3.12+", detail: "\(python) · " + tr("zbic is missing (only some games need it)"), state: .optional, install: .command("'\(python)' -m pip install zbic")) }
        let script = UserDefaults.standard.string(forKey: "envScript") ?? ""
        items.append(SetupItem(id: "env", title: tr("Environment script"), detail: script.isEmpty ? tr("Optional: a shell script that sets up tools kept elsewhere") : script,
                               state: script.isEmpty || FileManager.default.isReadableFile(atPath: script) ? (script.isEmpty ? .optional : .ok) : .missing, install: .chooseEnv))
        items.append(SetupItem(id: "repo", title: tr("nxnative checkout"), detail: repo.isEmpty ? tr("Not chosen") : repo, state: repoOK ? .ok : .missing, install: .chooseRepo))
        let keysOK = !keys.isEmpty && FileManager.default.isReadableFile(atPath: keys)
        items.append(SetupItem(id: "keys", title: "prod.keys", detail: keys.isEmpty ? tr("Your own console's keys; only the path is kept") : keys, state: keysOK ? .ok : .missing, install: .chooseKeys))
        return items
    }

    /// A shell command's trimmed output (bash -lc, with Homebrew's PATH)
    static func sh(_ command: String) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", command]
        p.environment = ToolEnvironment.make()
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Where the Python probably is: the checkout's .venv, else Homebrew's
    static func guessPython(repo: String) -> String {
        let venv = (repo as NSString).appendingPathComponent(".venv/bin/python3")
        if !repo.isEmpty, FileManager.default.isExecutableFile(atPath: venv) { return venv }
        for p in ["/opt/homebrew/bin/python3", "/usr/local/bin/python3"] where FileManager.default.isExecutableFile(atPath: p) { return p }
        return ""
    }
}
