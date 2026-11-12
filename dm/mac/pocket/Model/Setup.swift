// What making game packs needs (README, "Packing"), checked on this Mac and installed from here: Xcode 27.2 with its iOS platform and Metal toolchain, the tools
// (NX Pocket's tool kit: a Python with the build's modules, zstd, glslang and xcodegen, ToolKit) with NX Pocket's code, and the player's own prod.keys (only
// its path is kept). After NX Play's setup (github.com/varyform/nx-native-wrapper, MIT, the notice in BuildProgress.swift) and NX2Apple's bundled tools: the
// player installs Xcode and chooses the keys; Install All does the rest, in Terminal only for what asks for the Mac's password (Xcode's first launch).
// A developer's own Python and tools (Settings, Advanced) count as the tools when they have what the kit has.
import Foundation

struct SetupItem: Identifiable, Equatable {
    enum State: Equatable { case ok, missing, optional, checking }
    let id: String
    let title: String
    let detail: String
    let state: State
    var install: SetupAction? = nil
    var alternate: SetupAction? = nil   // a second way, beside install
}

/// How a missing item is fixed: a command run here, a command run in Terminal (one that asks for the Mac's password), a page opened, the tools installed
/// (the tool kit and the code, into Application Support), or a file or folder chosen
enum SetupAction: Equatable {
    case command(String)      // run with bash -lc, its output in the setup log
    case terminal(String)     // a .command file Terminal opens: sudo needs a terminal to ask for the password
    case open(String)         // a URL
    case installTools(kit: Bool, code: Bool)
    case chooseRepo, chooseKeys, choosePython, chooseEnv
}

enum Setup {
    static let pythonModules = ["lz4", "capstone", "fontTools", "nsz"]
    static let toolNames = ["xcodegen", "zstd", "glslangValidator"]
    /// The code the packs are made with (docs/nx-pocket/README.md); codeURL in the defaults names another
    static var codeURL: String { UserDefaults.standard.string(forKey: "codeURL").flatMap { $0.isEmpty ? nil : $0 } ?? "https://github.com/zkkzkk/nx-pocket.git" }
    /// Where Install puts the code: beside the tool kit, so the player never chooses a folder (Settings, Advanced, names another)
    static var codeFolder: String { ToolKit.home.appendingPathComponent("nx-pocket").path }
    /// A player's keys where NX Play and the other front ends look first
    static let commonKeys = (NSHomeDirectory() as NSString).appendingPathComponent(".switch/prod.keys")

    /// The checks, slow ones included (Python's imports): call off the main thread
    static func check(repo: String, keys: String, python: String) -> [SetupItem] {
        var items: [SetupItem] = []
        let xcode = sh("xcodebuild -version 2>/dev/null | head -1")
        let xv = xcode.split(separator: " ").last.map(String.init) ?? ""
        let app = xcode.isEmpty ? xcodeApp() : nil   // Xcode is here, but xcode-select names the Command Line Tools
        let firstLaunch = !xcode.isEmpty && sh("xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1; echo $?") != "0"
        items.append(SetupItem(id: "xcode", title: "Xcode", detail: app.map { String(format: tr("%@ is not selected yet"), $0) } ?? (firstLaunch ? tr("Xcode's first launch: its license and components") : xcode.isEmpty ? tr("Xcode 27.2 or later, from the App Store") : xcode),
                               state: xcode.isEmpty || firstLaunch || xv.compare("27.2", options: .numeric) == .orderedAscending ? .missing : .ok,
                               install: app.map { .terminal("sudo xcode-select -s '\($0)' && sudo xcodebuild -runFirstLaunch") } ?? (firstLaunch ? .terminal("sudo xcodebuild -runFirstLaunch") : .open("macappstore://apps.apple.com/app/id497799835"))))
        let ios = sh("xcodebuild -showsdks 2>/dev/null | grep -c iphoneos")
        items.append(SetupItem(id: "ios", title: tr("iOS platform"), detail: tr("Xcode → Settings → Components"), state: (Int(ios) ?? 0) > 0 ? .ok : .missing,
                               install: .command("xcodebuild -downloadPlatform iOS")))
        let metal = sh("xcrun -f metal 2>/dev/null")
        items.append(SetupItem(id: "metal", title: tr("Metal toolchain"), detail: metal.isEmpty ? "xcodebuild -downloadComponent MetalToolchain" : tr("Installed"),
                               state: metal.isEmpty ? .missing : .ok, install: .command("xcodebuild -downloadComponent MetalToolchain")))
        let kit = ToolKit.installed
        let ownTools = !kit && toolNames.allSatisfy { !sh("command -v \($0)").isEmpty } && pythonReady(python)   // a developer's own Python and tools
        let codeOK = isCode(repo), toolsOK = kit || ownTools
        var need: [String] = []
        if !toolsOK { need.append(String(format: tr("the tools (%@)"), ToolKit.sizeText)) }
        if !codeOK { need.append(tr("NX Pocket's code (about 750 MB)")) }
        items.append(SetupItem(id: "tools", title: tr("Pack-making tools"), detail: need.isEmpty ? (kit ? tr("Installed") : String(format: tr("Your own Python and tools: %@"), python))
                                                                                   : String(format: tr("To download: %@"), need.joined(separator: tr(", "))),
                               state: need.isEmpty ? .ok : .missing, install: .installTools(kit: !toolsOK, code: !codeOK)))
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

    /// Where the Python probably is: the tool kit's, else the checkout's .venv, else Homebrew's
    static func guessPython(repo: String) -> String {
        let v = (repo as NSString).appendingPathComponent(".venv/bin/python3")
        for p in [ToolKit.python, repo.isEmpty ? "" : v, "/opt/homebrew/bin/python3"] where !p.isEmpty && FileManager.default.isExecutableFile(atPath: p) { return p }
        return ""
    }

    /// Whether `path` holds NX Pocket's code: the NSP script and the pack script. nxnative itself (the README's clone of seedds/nxnative before NX Pocket's own) has
    /// only the first, and makes no game pack
    static func isCode(_ path: String) -> Bool {
        !path.isEmpty && ["scripts/build_ipa_from_nsp.py", "dm/ios/tools/build_pack.py"].allSatisfy { FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent($0)) }
    }

    /// `python`'s version when it is an arm64 Python 3.12 or later, else empty
    static func pythonVersion(_ python: String) -> String {
        let pv = python.isEmpty ? "" : sh("'\(python)' -c 'import sys,platform; print(\"%d.%d %s\" % (sys.version_info[0], sys.version_info[1], platform.machine()))' 2>/dev/null")
        let parts = pv.split(separator: " "), ver = parts.first.map(String.init) ?? "", arch = parts.count > 1 ? String(parts[1]) : ""
        return !ver.isEmpty && ver.compare("3.12", options: .numeric) != .orderedAscending && arch == "arm64" ? ver : ""
    }

    /// Whether `python` imports the build's modules
    static func pythonReady(_ python: String) -> Bool {
        !python.isEmpty && FileManager.default.isExecutableFile(atPath: python) && sh("'\(python)' -c 'import \(pythonModules.joined(separator: ", "))' 2>/dev/null && echo y") == "y"
    }

    /// The clone of the code into `folder`: blobs on demand, so it is quicker than a full clone and keeps every commit (NX Pocket's build number counts them)
    static func cloneCommand(into folder: String) -> String { "git clone --filter=blob:none '\(codeURL)' '\(folder)'" }

    /// An Xcode in Applications that xcode-select does not name (the Command Line Tools are selected), the newest by name
    static func xcodeApp() -> String? {
        let apps = (try? FileManager.default.contentsOfDirectory(atPath: "/Applications")) ?? []
        return apps.filter { $0.hasPrefix("Xcode") && $0.hasSuffix(".app") && !$0.contains("beta") }.sorted().last.map { "/Applications/\($0)" }
    }

    /// One script for every missing item a command can fix, in the order they depend on each other: Xcode, its iOS platform and Metal toolchain, then the
    /// tools (the kit and the code, into `codeFolder`). Returns the script and whether it needs Terminal
    static func installAll(_ items: [SetupItem], codeFolder: String) -> (script: String, terminal: Bool) {
        var steps: [String] = [], terminal = false
        for id in ["xcode", "ios", "metal", "tools"] {
            guard let item = items.first(where: { $0.id == id }), item.state == .missing else { continue }
            switch item.install {
            case .command(let c)?: steps.append(c)
            case .terminal(let c)?: steps.append(c); terminal = true
            case .installTools(let kit, let code)?: steps += toolSteps(kit: kit, code: code, codeFolder: codeFolder)
            default: break
            }
        }
        return (script(steps), terminal)
    }

    /// The tool kit's download and the code's clone (a folder there that is not NX Pocket's code, such as an old try, is set aside first)
    static func toolSteps(kit: Bool, code: Bool, codeFolder: String) -> [String] {
        var steps: [String] = []
        if kit, let c = ToolKit.installCommand() { steps.append(c) }
        if code {
            if FileManager.default.fileExists(atPath: codeFolder) { steps.append("mv '\(codeFolder)' '\(codeFolder).old-$(date +%s)'") }
            steps.append(cloneCommand(into: codeFolder))
        }
        return steps
    }

    /// Steps run one after another, each echoed first; the first that fails stops the rest
    static func script(_ steps: [String]) -> String {
        "fail() { echo; echo '\(tr("The install failed. See its output."))'; exit 1; }\n" + steps.map { "echo; echo '> \($0.replacingOccurrences(of: "'", with: "'\\''"))'\n\($0) || fail" }.joined(separator: "\n")
    }
}
