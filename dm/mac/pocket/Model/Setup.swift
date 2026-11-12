// What making game packs needs (README, "Packing"), checked on this Mac and installed where a command can do it: Xcode 27.1 with its iOS platform and Metal
// toolchain, Homebrew with xcodegen, zstd and glslang, the .NET SDK, a Python 3.12+ (arm64) with the build's modules, this nxnative checkout, and the player's
// own prod.keys (only its path is kept). After NX Play's setup (github.com/varyform/nx-native-wrapper, MIT, the notice in BuildProgress.swift); NX Pocket runs
// the checks itself instead of a setup script. Everything but Xcode itself and the keys installs from here: the code by git clone, .NET and the Python modules
// without the password, Homebrew and Xcode's first launch in Terminal, where they ask for it.
import Foundation

struct SetupItem: Identifiable, Equatable {
    enum State: Equatable { case ok, missing, optional, checking }
    let id: String
    let title: String
    let detail: String
    let state: State
    var install: SetupAction? = nil
    var alternate: SetupAction? = nil   // a second way, beside install (download the code, or choose a copy already here)
}

/// How a missing item is fixed: a command run here, a command run in Terminal (one that asks for the Mac's password), a page opened, the code downloaded,
/// or a file or folder chosen
enum SetupAction: Equatable {
    case command(String)      // run with bash -lc, its output in the setup log
    case terminal(String)     // a .command file Terminal opens: sudo and the Homebrew installer need a terminal to ask for the password
    case open(String)         // a URL
    case downloadRepo         // git clone of the code into a folder the player picks
    case chooseRepo, chooseKeys, choosePython, chooseEnv
}

enum Setup {
    static let pythonModules = ["lz4", "capstone", "fontTools", "nsz"]   // zbic: only some games' files need it (checked, not required)
    static let pipPackages = "lz4 'capstone>=5,<6' fonttools nsz zbic \"backports.zstd; python_version < '3.14'\""
    /// The code the packs are made with (docs/nx-pocket/README.md, Get the code); codeURL in the defaults names another
    static var codeURL: String { UserDefaults.standard.string(forKey: "codeURL").flatMap { $0.isEmpty ? nil : $0 } ?? "https://github.com/zkkzkk/nx-pocket.git" }
    static let homebrewInstall = "/bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\" && eval \"$(/opt/homebrew/bin/brew shellenv)\""   // the steps after it in the same script find brew
    /// .NET 10 into ~/.dotnet with Microsoft's script: no password, where the tools look for it (ToolEnvironment, build_ipa_from_nsp.py TOOL_PATHS).
    /// Homebrew's dotnet-sdk cask runs a package installer that asks for the password, which a command run here cannot answer
    static let dotnetInstall = "curl -fsSL https://dot.net/v1/dotnet-install.sh | bash -s -- --channel 10.0 --install-dir \"$HOME/.dotnet\""

    /// The checks, slow ones included (Python's imports): call off the main thread
    static func check(repo: String, keys: String, python: String) -> [SetupItem] {
        var items: [SetupItem] = []
        let xcode = sh("xcodebuild -version 2>/dev/null | head -1")
        let xv = xcode.split(separator: " ").last.map(String.init) ?? ""
        let app = xcode.isEmpty ? xcodeApp() : nil   // Xcode is here, but xcode-select names the Command Line Tools
        let firstLaunch = !xcode.isEmpty && sh("xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1; echo $?") != "0"
        items.append(SetupItem(id: "xcode", title: "Xcode", detail: app.map { String(format: tr("%@ is not selected yet"), $0) } ?? (firstLaunch ? tr("Xcode's first launch: its license and components") : xcode.isEmpty ? tr("Xcode 27.1 or later, from the App Store") : xcode),
                               state: xcode.isEmpty || firstLaunch || xv.compare("27.1", options: .numeric) == .orderedAscending ? .missing : .ok,
                               install: app.map { .terminal("sudo xcode-select -s '\($0)' && sudo xcodebuild -runFirstLaunch") } ?? (firstLaunch ? .terminal("sudo xcodebuild -runFirstLaunch") : .open("macappstore://apps.apple.com/app/id497799835"))))
        let ios = sh("xcodebuild -showsdks 2>/dev/null | grep -c iphoneos")
        items.append(SetupItem(id: "ios", title: tr("iOS platform"), detail: tr("Xcode → Settings → Components"), state: (Int(ios) ?? 0) > 0 ? .ok : .missing,
                               install: .command("xcodebuild -downloadPlatform iOS")))
        let metal = sh("xcrun -f metal 2>/dev/null")
        items.append(SetupItem(id: "metal", title: tr("Metal toolchain"), detail: metal.isEmpty ? "xcodebuild -downloadComponent MetalToolchain" : tr("Installed"),
                               state: metal.isEmpty ? .missing : .ok, install: .command("xcodebuild -downloadComponent MetalToolchain")))
        let brew = sh("command -v brew")
        let tools = ["xcodegen", "zstd", "glslangValidator"].filter { sh("command -v \($0)").isEmpty }
        items.append(SetupItem(id: "brew", title: "Homebrew", detail: brew.isEmpty ? (tools.isEmpty ? tr("Not needed: the tools are already installed") : "brew.sh") : brew,
                               state: !brew.isEmpty ? .ok : tools.isEmpty ? .optional : .missing, install: brew.isEmpty && !tools.isEmpty ? .terminal(homebrewInstall) : nil))
        items.append(SetupItem(id: "tools", title: "xcodegen · zstd · glslang", detail: tools.isEmpty ? tr("Installed") : String(format: tr("Missing: %@"), tools.joined(separator: ", ")),
                               state: tools.isEmpty ? .ok : .missing, install: .command("brew install xcodegen zstd glslang")))
        let dotnet = sh("dotnet --list-runtimes 2>/dev/null | grep -c 'Microsoft.NETCore.App 10'")
        items.append(SetupItem(id: "dotnet", title: ".NET SDK", detail: (Int(dotnet) ?? 0) > 0 ? tr("Installed") : tr("The shader translator needs .NET 10"),
                               state: (Int(dotnet) ?? 0) > 0 ? .ok : .missing, install: .command(dotnetInstall)))
        let ver = pythonVersion(python), pyOK = !ver.isEmpty
        let missingMods = pyOK ? pythonModules.filter { sh("'\(python)' -c 'import \($0)' 2>/dev/null && echo y") != "y" } : pythonModules
        let zbic = pyOK && sh("'\(python)' -c 'import zbic' 2>/dev/null && echo y") == "y"
        items.append(SetupItem(id: "python", title: "Python 3.12+", detail: python.isEmpty ? tr("Not chosen") : !pyOK ? String(format: tr("%@ is not an arm64 Python 3.12 or later"), python)
                                                                : missingMods.isEmpty ? "\(python) (\(ver))" : String(format: tr("Missing modules: %@"), missingMods.joined(separator: ", ")),
                               state: pyOK && missingMods.isEmpty ? (zbic ? .ok : .optional) : .missing,
                               install: .command(pythonInstall(repo: repo, python: pyOK ? python : "")), alternate: .choosePython))
        let repoOK = !repo.isEmpty && FileManager.default.fileExists(atPath: (repo as NSString).appendingPathComponent("scripts/build_ipa_from_nsp.py"))
        if pyOK && missingMods.isEmpty && !zbic { items[items.count - 1] = SetupItem(id: "python", title: "Python 3.12+", detail: "\(python) · " + tr("zbic is missing (only some games need it)"), state: .optional, install: .command("'\(python)' -m pip install zbic")) }
        let script = UserDefaults.standard.string(forKey: "envScript") ?? ""
        items.append(SetupItem(id: "env", title: tr("Environment script"), detail: script.isEmpty ? tr("Optional: a shell script that sets up tools kept elsewhere") : script,
                               state: script.isEmpty || FileManager.default.isReadableFile(atPath: script) ? (script.isEmpty ? .optional : .ok) : .missing, install: .chooseEnv))
        items.append(SetupItem(id: "repo", title: tr("nxnative checkout"), detail: repo.isEmpty ? tr("Download gets it from GitHub (about 600 MB), or choose a copy you have") : repo, state: repoOK ? .ok : .missing,
                               install: repoOK ? .chooseRepo : .downloadRepo, alternate: repoOK ? nil : .chooseRepo))
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

    /// Where the Python probably is: the build's own (venv), else Homebrew's
    static func guessPython(repo: String) -> String {
        let v = venvPython(repo: repo)
        if FileManager.default.isExecutableFile(atPath: v) { return v }
        for p in ["/opt/homebrew/bin/python3", "/usr/local/bin/python3"] where FileManager.default.isExecutableFile(atPath: p) { return p }
        return ""
    }

    /// The Python environment Install makes: the checkout's .venv (README), or one in Application Support while no checkout is chosen
    static func venv(repo: String) -> String {
        if !repo.isEmpty { return (repo as NSString).appendingPathComponent(".venv") }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("NX Pocket/python").path
    }
    static func venvPython(repo: String) -> String { (venv(repo: repo) as NSString).appendingPathComponent("bin/python3") }

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

    /// The modules into a venv of their own: Homebrew's Python refuses a pip install into itself (PEP 668, externally-managed-environment). Made from `python`
    /// (an arm64 3.12+, or empty), else Homebrew's newest Python, installed first when there is none. A venv already chosen gets the modules directly
    static func pythonInstall(repo: String, python: String) -> String {
        let v = venv(repo: repo)
        if !python.isEmpty, python.hasPrefix(v + "/") || FileManager.default.fileExists(atPath: ((python as NSString).deletingLastPathComponent as NSString).appendingPathComponent("activate")) {
            return "'\(python)' -m pip install \(pipPackages)"
        }
        let base = !python.isEmpty ? "'\(python)'" : ["3.14", "3.13", "3.12"].map { "/opt/homebrew/bin/python\($0)" }.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/opt/homebrew/bin/python3.13"
        let brew = python.isEmpty && !FileManager.default.isExecutableFile(atPath: base) ? "brew install python@3.13 && " : ""
        return "\(brew)\(base) -m venv '\(v)' && '\(v)/bin/pip' install \(pipPackages)"
    }

    /// The clone of the code into `folder`: blobs on demand, so it is quicker than a full clone and keeps every commit (NX Pocket's build number counts them)
    static func cloneCommand(into folder: String) -> String { "git clone --filter=blob:none '\(codeURL)' '\(folder)'" }

    /// An Xcode in Applications that xcode-select does not name (the Command Line Tools are selected), the newest by name
    static func xcodeApp() -> String? {
        let apps = (try? FileManager.default.contentsOfDirectory(atPath: "/Applications")) ?? []
        return apps.filter { $0.hasPrefix("Xcode") && $0.hasSuffix(".app") && !$0.contains("beta") }.sorted().last.map { "/Applications/\($0)" }
    }

    /// One script for every missing item a command can fix, in the order they depend on each other: Xcode, Homebrew, its tools, .NET, the code, then the
    /// Python environment (in the code's folder). `repo` is where the code goes when it is downloaded too. Returns the script and whether it needs Terminal.
    /// Slow (it asks Python its version): call off the main thread
    static func installAll(_ items: [SetupItem], repo: String, cloneRepo: Bool, python: String) -> (script: String, terminal: Bool) {
        var steps: [String] = [], terminal = false
        let order = ["xcode", "ios", "metal", "brew", "tools", "dotnet", "repo", "python"]
        for id in order {
            guard let item = items.first(where: { $0.id == id }), item.state == .missing || (id == "python" && item.state != .ok) else { continue }
            switch (id, item.install) {
            case ("repo", _): if cloneRepo { steps.append(cloneCommand(into: repo)) }
            case ("python", _): steps.append(pythonInstall(repo: repo, python: pythonVersion(python).isEmpty ? "" : python))
            case (_, .command(let c)?): steps.append(c)
            case (_, .terminal(let c)?): steps.append(c); terminal = true
            default: break
            }
        }
        return (script(steps), terminal)
    }

    /// Steps run one after another, each echoed first; the first that fails stops the rest
    static func script(_ steps: [String]) -> String {
        "fail() { echo; echo '\(tr("The install failed. See its output."))'; exit 1; }\n" + steps.map { "echo; echo '> \($0.replacingOccurrences(of: "'", with: "'\\''"))'\n\($0) || fail" }.joined(separator: "\n")
    }
}
