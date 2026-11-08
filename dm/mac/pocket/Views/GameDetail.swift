// A game's page: a banner of its cover blurred (its own icon, as on the phone) with the cover, its name, version and files; then its game pack (making it, stage by
// stage as the scripts report them, or what it is once made), sending it to the iPhone, its files, and playing it on this Mac (its Mac version, MacVersion).
import SwiftUI

struct GameDetail: View {
    @EnvironmentObject var model: AppModel
    let game: MacGame

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Hero(game: game)
                VStack(alignment: .leading, spacing: 16) {
                    SupportCard(game: game)
                    PackCard(game: game)
                    SendCard(game: game)
                    FilesCard(game: game)
                    MacCard(game: game)
                }
                .padding(.horizontal, 24).padding(.bottom, 24)
            }
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
    }
}

// MARK: - Support

/// What nxnative's game profiles say of the game (GameSupport): tested on the iPhone, in progress, or no profile; the profile's own note and its README
private struct SupportCard: View {
    @EnvironmentObject var model: AppModel
    let game: MacGame

    var body: some View {
        let s = model.support(game)
        Card(title: tr("Support"), symbol: "checklist") {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: s.level == .tested ? "checkmark.seal.fill" : s.level == .inProgress ? "wrench.and.screwdriver.fill" : "questionmark.diamond.fill")
                    .font(.system(size: 24)).foregroundStyle(color(s.level)).frame(width: 30)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title(s.level)).font(.system(size: 14.5, weight: .semibold))
                    Text(detail(s.level)).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let n = s.note {
                        Text(n).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled).help(n)
                            .padding(.top, 2)
                    }
                    if let v = s.validated { Text(String(format: tr("Last checked: %@"), v)).font(.system(size: 11).monospacedDigit()).foregroundStyle(.tertiary) }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 8) {
                    if let r = s.readme { Button { NSWorkspace.shared.open(r) } label: { Label(tr("Notes"), systemImage: "doc.text") } }
                    Button { model.report(game) } label: {
                        if model.reporting == game.id { ProgressView().controlSize(.small) } else { Label(tr("Report a Problem…"), systemImage: "ladybug").lineLimit(1) }
                    }
                    .disabled(model.reporting != nil)
                    .help(tr("Puts the logs and settings for a bug report into a zip (no game files, no keys)."))
                }
                .buttonStyle(.glass)
            }
        }
    }
    private func color(_ l: GameSupport.Level) -> Color { l == .tested ? Palette.ok : l == .inProgress ? Palette.accent : Palette.warn }
    private func title(_ l: GameSupport.Level) -> String {
        switch l {
        case .tested: return tr("Tested: plays on the iPhone")
        case .inProgress: return tr("In progress: nxnative has a profile for it")
        case .none: return tr("No profile")
        }
    }
    private func detail(_ l: GameSupport.Level) -> String {
        switch l {
        case .tested: return tr("nxnative's notes for this game say it plays on an iPhone.")
        case .inProgress: return tr("It has a game profile, but its notes do not yet say it plays on an iPhone. It may work, or have known problems.")
        case .none: return tr("nxnative has not been set up for this game. The build makes a provisional profile; the pack will most likely not run.")
        }
    }
}

// MARK: - Banner

private struct Hero: View {
    let game: MacGame
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Backdrop(image: game.icon, key: game.id)
                .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.7), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
            HStack(alignment: .bottom, spacing: 22) {
                CoverArt(image: game.icon, name: game.name, side: 136).shadow(color: .black.opacity(0.45), radius: 22, y: 14)
                VStack(alignment: .leading, spacing: 8) {
                    Text(game.name).font(.system(size: 30, weight: .bold)).foregroundStyle(.white).lineLimit(2).shadow(color: .black.opacity(0.35), radius: 6, y: 2)
                    Text([game.version.map { "\(tr("Version")) \($0)" }, game.titleID].compactMap { $0 }.joined(separator: "  ·  "))
                        .font(.system(size: 12.5).monospacedDigit()).foregroundStyle(Palette.soft).textSelection(.enabled)
                    HStack(spacing: 8) {
                        if game.switch2 != nil { chip("sparkles", "Switch 2") }
                        if let b = game.base { chip("opticaldisc", "\(tr("Base game"))\(b.version.map { " v\($0)" } ?? "")") }
                        if let u = game.updates.last { chip("arrow.up.circle", "\(tr("Update")) v\(u.version ?? 0)") }
                        if !game.dlc.isEmpty { chip("puzzlepiece.extension", String(format: tr("DLC ×%d"), game.dlc.count)) }
                        if game.files.isEmpty { chip("exclamationmark.triangle", tr("No game files in this folder")) }
                    }
                }
                .padding(.bottom, 6)
            }
            .padding(.horizontal, 28).padding(.bottom, 18)
        }
        .frame(height: 250)
        .clipped()
    }
    private func chip(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.white)
            .padding(.horizontal, 10).frame(height: 24).glassEffect(.regular, in: .capsule)
    }
}

// MARK: - Cards

/// A section of the page: a title with its symbol, its content on a rounded panel
struct Card<Content: View>: View {
    let title: String
    let symbol: String
    var trailing: AnyView? = nil
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(title, systemImage: symbol).font(.system(size: 14, weight: .semibold))
                Spacer()
                if let trailing { trailing }
            }
            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.primary.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }
}

private struct PackCard: View {
    @EnvironmentObject var model: AppModel
    let game: MacGame

    var body: some View {
        Card(title: tr("Game Pack"), symbol: "shippingbox") {
            if let i = model.queue.firstIndex(of: game.id), !model.queuedMac.contains(game.id) {
                queued(i)
            } else if let b = model.builds[game.id], b.kind == .pack, b.state != .done {
                BuildView(build: b, game: game)
            } else if let pack = game.pack {
                ready(pack)
            } else {
                notMade
            }
        }
    }

    @State private var unsupported = false   // Make on a game with no profile: asked first
    @State private var recompile = false     // Make Again after a shader chain change: said first, with how long

    /// Waiting in the queue: its place, what is being made now, and taking it out or pausing the queue
    private func queued(_ i: Int) -> some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: "hourglass").font(.system(size: 26)).foregroundStyle(Palette.accent).frame(width: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(String(format: tr("Queued: %d ahead"), i + (model.building == nil ? 0 : 1))).font(.system(size: 15, weight: .semibold))
                Text(model.queuePaused ? tr("The queue is paused. Resume it to continue.")
                     : model.building.flatMap { id in model.games.first { $0.id == id }?.name }.map { String(format: tr("Making %@ now. This game starts automatically next."), $0) } ?? tr("It starts automatically."))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            Button { model.setQueuePaused(!model.queuePaused) } label: { Label(model.queuePaused ? tr("Resume Queue") : tr("Pause Queue"), systemImage: model.queuePaused ? "play.fill" : "pause.fill") }
            Button { model.dequeue(game.id) } label: { Label(tr("Remove from Queue"), systemImage: "xmark") }
        }
        .buttonStyle(.glass)
    }

    private var notMade: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text(tr("No game pack yet")).font(.system(size: 15, weight: .semibold))
                Text(model.canBuild(game) ? tr("Making one takes 20 to 60 minutes, depending on the game. You can stop and carry on later: finished stages are kept.")
                                    : tr("Finish setting up first: the nxnative checkout, a Python and your prod.keys."))
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if model.support(game).level == .none {
                    Label(tr("nxnative has no profile for this game: a pack can be made, but it will most likely not run."), systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12)).foregroundStyle(Palette.warn).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            Button { make() } label: { Label(tr("Make Game Pack"), systemImage: "shippingbox.fill").padding(.horizontal, 8) }
                .buttonStyle(.glassProminent).controlSize(.large).disabled(!model.canBuild(game) || game.files.isEmpty)
        }
        .confirmationDialog(tr("Make a pack of a game nxnative has no profile for?"), isPresented: $unsupported) {
            Button(tr("Make Anyway")) { model.enqueue(game) }
        } message: {
            Text(tr("The build surveys the game and guesses a provisional profile. The pack may not start, or may crash on the way. Games with a profile are the ones known to run."))
        }
    }
    private func make() {
        if model.support(game).level == .none { unsupported = true }
        else if game.pack != nil, model.ages[game.id]?.chainChanged == true { recompile = true }
        else { model.enqueue(game) }
    }

    /// The pack made: what it is, and its actions beside it, or under it when the window is too narrow for one row (English takes more room than Chinese)
    private func ready(_ pack: URL) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 16) { readyInfo(pack).fixedSize(horizontal: false, vertical: true).frame(minWidth: 260, alignment: .leading); Spacer(); readyActions(pack) }
            VStack(alignment: .leading, spacing: 12) { readyInfo(pack); HStack(spacing: 8) { readyActions(pack) } }
        }
        .buttonStyle(.glass)
    }
    private func readyInfo(_ pack: URL) -> some View {
        let age = model.ages[game.id], stale = age?.state == .stale
        return HStack(alignment: .center, spacing: 16) {
            Image(systemName: "checkmark.seal.fill").font(.system(size: 30)).foregroundStyle(Palette.ok)
            VStack(alignment: .leading, spacing: 4) {
                Text(tr("Game pack ready")).font(.system(size: 15, weight: .semibold))
                PackFacts(pack: pack, made: game.packMade)
                if let age, stale {   // a newer version to have, said quietly: the pack plays as it was made
                    Label(tr("Newer version available, still playable"), systemImage: "arrow.trianglehead.2.clockwise").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    Text(PackAge.newer(age)).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else if let why = age?.why {
                    Text(why).font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
            }
        }
    }
    @ViewBuilder private func readyActions(_ pack: URL) -> some View {
            Button { NSWorkspace.shared.activateFileViewerSelecting([pack]) } label: { Label(tr("Show in Finder"), systemImage: "folder") }
            Button { model.export(game) } label: { Label(tr("Export…"), systemImage: "square.and.arrow.up") }
            if PackFile.isFile(pack), let airdrop = NSSharingService(named: .sendViaAirDrop) {   // one file: AirDrop takes it to an iPhone, which opens it in NX Pocket
                Button { airdrop.perform(withItems: [pack]) } label: { Label(tr("AirDrop…"), systemImage: "dot.radiowaves.left.and.right") }
            }
            Button { make() } label: { Label(tr("Make Again"), systemImage: "arrow.clockwise") }.disabled(!model.canBuild(game))
                .confirmationDialog(tr("The shaders have a new version and are compiled again first. This takes a while."), isPresented: $recompile) {
                    Button(tr("Make Again")) { model.enqueue(game) }
                } message: {
                    Text(String(format: tr("About %d minutes for this game, estimated from its shaders. Progress, Stop and Continue work as for any build; the pack you have keeps working until the new one is made."), ShaderRebuild.minutes(game)))
                }
    }
}

// MARK: - Play on this Mac

/// Playing the game on this Mac: its Mac version (MacVersion) made from the build files the first time, then opened at once; its settings window comes first
private struct MacCard: View {
    @EnvironmentObject var model: AppModel
    let game: MacGame
    @State private var age: PackAge?

    var body: some View {
        Card(title: tr("Play on this Mac"), symbol: "macbook") {
            if model.queuedMac.contains(game.id), let i = model.queue.firstIndex(of: game.id) {
                Label(String(format: tr("Queued: %d ahead"), i + (model.building == nil ? 0 : 1)), systemImage: "hourglass").font(.system(size: 13, weight: .semibold))
            } else if let b = model.builds[game.id], b.kind == .mac, b.state != .done {
                BuildView(build: b, game: game)
            } else if let app = game.macApp {
                ready(app)
            } else {
                notMade
            }
        }
        .task(id: game.macApp) {
            guard let app = game.macApp else { age = nil; return }
            let (t, r) = (game.titleID, model.repo)
            age = await Task.detached { MacVersion.age(app, titleID: t, repo: r) }.value
        }
    }

    private var savesNote: some View {
        Text(tr("Keyboard or controller. Its settings window comes first: frame rate, resolution, language. Saves stay on this Mac; choose the same iCloud Drive folder under Cloud saves there and in NX Pocket to play on from the same save."))
            .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private var notMade: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text(game.buildDir != nil ? String(format: tr("The first time, a Mac version is made from the game's build files (about %d minutes); then it starts at once."), ShaderRebuild.minutes(game))
                                          : tr("The first time, a Mac version is made from the game files (20 to 60 minutes); then it starts at once."))
                    .font(.system(size: 13, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                savesNote
            }
            Spacer()
            Button { model.playOnMac(game) } label: { Label(tr("Play on Mac"), systemImage: "play.fill").padding(.horizontal, 8) }
                .buttonStyle(.glassProminent).controlSize(.large).disabled(!model.canBuild(game) || game.files.isEmpty)
        }
    }

    private func ready(_ app: URL) -> some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: "checkmark.seal.fill").font(.system(size: 30)).foregroundStyle(Palette.ok)
            VStack(alignment: .leading, spacing: 4) {
                Text(tr("Mac version ready")).font(.system(size: 15, weight: .semibold))
                savesNote
                if let age, age.state == .stale {   // as for a pack: said quietly, it plays as it was made
                    Label(tr("Newer version available, still playable"), systemImage: "arrow.trianglehead.2.clockwise").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    Text(PackAge.newer(age)).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            Button { NSWorkspace.shared.activateFileViewerSelecting([app]) } label: { Label(tr("Show in Finder"), systemImage: "folder") }.buttonStyle(.glass)
            Button { model.enqueue(game, kind: .mac) } label: { Label(tr("Make Again"), systemImage: "arrow.clockwise") }.buttonStyle(.glass).disabled(!model.canBuild(game))
            Button { model.playOnMac(game) } label: { Label(tr("Play on Mac"), systemImage: "play.fill").padding(.horizontal, 6) }.buttonStyle(.glassProminent).controlSize(.large)
        }
    }
}

/// A pack's size, format and when it was made (its size counted off the main thread)
private struct PackFacts: View {
    let pack: URL
    let made: Date?
    @State private var size: Int64?
    var body: some View {
        Text([size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "…", format, made.map { $0.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(Locale(identifier: launcherChinese ? "zh-Hans" : "en_US"))) }]
                .compactMap { $0 }.joined(separator: "  ·  "))
            .font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
            .task(id: pack) { let p = pack; size = await Task.detached { Storage.size(p) }.value }
    }
    private var format: String? {
        let d = PackFile.isFile(pack) ? (try? PackFile(pack))?.data("pack.json") : try? Data(contentsOf: pack.appendingPathComponent("pack.json"))
        guard let d, let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        let f = j["format"] as? Int ?? 1, signed = (j["team"] as? String).map { String(format: tr("signed by %@"), $0) } ?? tr("signed on the iPhone")
        return String(format: tr("format %d"), f) + " · " + signed
    }
}

/// A build in progress or ended: its two steps (one for a Mac version), the stages each has finished, the current one with its bar and time left; why it failed; Stop
private struct BuildView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var build: PackBuild
    let game: MacGame

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                if build.kind == .mac { stepBadge(1, tr("Make the Mac version")) }
                else {
                    stepBadge(1, tr("Prepare the game"))
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(.tertiary)
                    stepBadge(2, tr("Make the game pack"))
                }
                Spacer()
                switch build.state {
                case .running:
                    Text("\(Int(build.fraction * 100))%").font(.system(size: 22, weight: .semibold).monospacedDigit())
                    Button(role: .destructive) { build.stop() } label: { Label(tr("Stop"), systemImage: "stop.fill") }.buttonStyle(.glass)
                case .failed, .cancelled:
                    Button { model.showLog = true } label: { Label(tr("Show Log"), systemImage: "text.alignleft") }.buttonStyle(.glass)
                    Button { model.enqueue(game, kind: build.kind) } label: { Label(build.state == .failed ? tr("Try Again") : tr("Continue"), systemImage: "arrow.clockwise") }.buttonStyle(.glassProminent)
                case .done: EmptyView()
                }
            }
            ProgressView(value: build.fraction).tint(build.state == .failed ? Palette.danger : Palette.accent)
            if build.state == .failed {
                VStack(alignment: .leading, spacing: 6) {
                    Label(build.kind == .mac ? tr("Making the Mac version failed") : tr("Making the game pack failed"), systemImage: "xmark.octagon.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.danger)
                    ForEach(Array(build.problems.suffix(4).enumerated()), id: \.offset) { _, p in
                        Text(p).font(.system(size: 11.5)).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else if build.state == .cancelled {
                Label(tr("Stopped. Continue to resume from the last finished stage."), systemImage: "pause.circle").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            StageList(run: build.current, running: build.state == .running)
        }
    }

    private func stepBadge(_ n: Int, _ title: String) -> some View {
        let done = n < build.phase || build.state == .done, now = n == build.phase && build.state == .running
        return HStack(spacing: 6) {
            ZStack {
                Circle().fill(done ? Palette.ok : now ? Palette.accent : Color.primary.opacity(0.15)).frame(width: 20, height: 20)
                if done { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white) }
                else { Text("\(n)").font(.system(size: 11, weight: .bold)).foregroundStyle(now ? .white : .secondary) }
            }
            Text(title).font(.system(size: 12.5, weight: now ? .semibold : .regular)).foregroundStyle(now || done ? .primary : .secondary)
        }
    }
}

/// The stages of the step in progress: finished ones with a tick and their time, the current one with its count and time left
private struct StageList: View {
    @ObservedObject var run: ToolRun
    let running: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(run.finished.suffix(6)) { s in
                HStack(spacing: 9) {
                    Image(systemName: s.ok ? "checkmark.circle.fill" : "xmark.circle.fill").foregroundStyle(s.ok ? Palette.ok : Palette.danger)
                    Text(StageNames.zh(s.name)).font(.system(size: 12.5))
                    Spacer()
                    if let e = s.elapsed { Text(BuildProgress.duration(e)).font(.system(size: 11.5).monospacedDigit()).foregroundStyle(.secondary) }
                }
            }
            if running, let p = run.progress, !p.finished {
                HStack(spacing: 9) {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(StageNames.zh(p.name))\(p.step.isEmpty ? "" : " · \(StageNames.zh(p.step))")").font(.system(size: 12.5, weight: .semibold))
                        if let f = p.stageFraction { ProgressView(value: f).frame(maxWidth: 360) }
                    }
                    Spacer()
                    Text([p.count, p.percent.map { "\($0)%" }, p.eta.map { String(format: tr("%@ left"), BuildProgress.duration($0)) }].compactMap { $0 }.joined(separator: "  ·  "))
                        .font(.system(size: 11.5).monospacedDigit()).foregroundStyle(.secondary)
                    Text("\(p.stage)/\(p.stages)").font(.system(size: 11, weight: .medium).monospacedDigit()).padding(.horizontal, 7).frame(height: 18)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                }
            } else if running {
                HStack(spacing: 9) { ProgressView().controlSize(.small); Text(tr("Starting…")).font(.system(size: 12.5)).foregroundStyle(.secondary) }
            }
        }
    }
}

private struct SendCard: View {
    @EnvironmentObject var model: AppModel
    let game: MacGame

    var body: some View {
        Card(title: tr("Send to iPhone"), symbol: "iphone.and.arrow.forward") {
            if let s = model.sends[game.id], !s.done, !s.stopped {
                SendView(sender: s, game: game)
            } else if game.pack == nil {
                Text(tr("Make the game pack first.")).font(.system(size: 12)).foregroundStyle(.secondary)
            } else if let d = model.connected {
                HStack(spacing: 14) {
                    Image(systemName: "iphone").font(.system(size: 26)).foregroundStyle(Palette.accent).frame(width: 34)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(d.name).font(.system(size: 14, weight: .semibold))
                        Text(model.sends[game.id]?.done == true ? tr("Sent. Open NX Pocket on the iPhone: the game is in its library.")
                                                                : String(format: tr("To NX Pocket on this iPhone (%@)"), model.bundleID.isEmpty ? tr("found automatically") : model.bundleID))
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { model.send(game, to: d) } label: { Label(model.sends[game.id]?.done == true ? tr("Send Again") : tr("Send"), systemImage: "arrow.up.circle.fill").padding(.horizontal, 6) }
                        .buttonStyle(.glassProminent).controlSize(.large)
                }
            } else {
                Label(tr("No iPhone connected: connect it with a cable, unlock it and trust this Mac."), systemImage: "cable.connector")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }
}

private struct SendView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var sender: PackSender
    let game: MacGame
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if let f = sender.failure {
                    Label(f, systemImage: "exclamationmark.triangle.fill").font(.system(size: 12.5)).foregroundStyle(Palette.danger).fixedSize(horizontal: false, vertical: true)
                } else if sender.count == 0 {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text(sender.phase.isEmpty ? tr("Getting ready…") : sender.phase).font(.system(size: 13, weight: .semibold)) }
                } else {
                    Text(String(format: tr("Sending %@ (%d of %d)"), sender.item, sender.index, sender.count)).font(.system(size: 13, weight: .semibold))
                }
                Spacer()
                Text("\(sender.estimating ? tr("about") + " " : "")\(ByteCountFormatter.string(fromByteCount: sender.sent, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: sender.total, countStyle: .file))")
                    .font(.system(size: 11.5).monospacedDigit()).foregroundStyle(.secondary)
                if sender.failure == nil { Button(role: .destructive) { sender.cancel() } label: { Label(tr("Stop"), systemImage: "stop.fill") }.buttonStyle(.glass) }
                else if let d = model.connected { Button { model.send(game, to: d) } label: { Label(tr("Send Again"), systemImage: "arrow.clockwise") }.buttonStyle(.glass) }
            }
            ProgressView(value: sender.fraction).tint(sender.failure == nil ? Palette.accent : Palette.danger)
        }
    }
}

private struct FilesCard: View {
    let game: MacGame
    var body: some View {
        Card(title: tr("Game Files"), symbol: "folder", trailing: AnyView(
            Button { NSWorkspace.shared.activateFileViewerSelecting([game.folder]) } label: { Label(tr("Show in Finder"), systemImage: "arrow.up.forward.app") }.buttonStyle(.borderless))) {
            VStack(spacing: 0) {
                ForEach(game.files) { f in
                    HStack(spacing: 10) {
                        Text(kind(f.kind)).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.white).padding(.horizontal, 7).frame(height: 18)
                            .background(Capsule().fill(f.kind == .base ? Palette.accent.opacity(0.8) : f.kind == .update ? Color.blue.opacity(0.7) : Color.purple.opacity(0.7)))
                        Text(f.url.lastPathComponent).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(f.size > 0 ? ByteCountFormatter.string(fromByteCount: f.size, countStyle: .file) : tr("Folder")).font(.system(size: 11.5).monospacedDigit()).foregroundStyle(.secondary)   // a Switch 2 dump's parts
                    }
                    .padding(.vertical, 6)
                    if f.id != game.files.last?.id { Divider() }
                }
                Text(game.folder.path).font(.system(size: 10.5)).foregroundStyle(.tertiary).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8).textSelection(.enabled)
            }
        }
    }
    private func kind(_ k: GameFile.Kind) -> String { k == .base ? tr("Base game") : k == .update ? tr("Update") : "DLC" }
}

/// The scripts' stage names (build_ipa_from_nsp.py's and build_pack.py's, lowercase, as their JSON events give them) as the window shows them, in English or Chinese;
/// what follows a known name (a version, a count in brackets) is kept. A name not in the table shows with a capital
enum StageNames {
    static let table: [(String, String, String)] = [
        ("unpack DLC", "Unpack DLC", "解包 DLC"), ("pack DLC", "Pack DLC", "打包 DLC"),   // a Switch 2 game's NUP or dump folder (pack_nup.py, pack_dump.py)
        ("unpack v", "Unpack game files v", "解包游戏文件 v"), ("pack v", "Pack game files v", "打包游戏文件 v"), ("check v", "Check game files v", "检查游戏文件 v"),
        ("decompress NSZ", "Decompress NSZ", "解压 NSZ"), ("build ID lookup", "Look up the build", "查找版本"), ("survey", "Survey the game", "分析游戏"),
        ("build nx_extract", "Build the extractor", "编译提取工具"), ("extract DLC", "Extract DLC", "提取 DLC"), ("extract", "Extract game files", "提取游戏文件"),
        ("rewrite", "Rewrite game code", "改写游戏代码"), ("GLSLC capture", "Capture shaders", "捕获着色器"), ("UE shader decode", "Decode shaders", "解码着色器"),
        ("shader capture", "Capture shaders", "捕获着色器"), ("heap check", "Check memory", "检查内存"), ("address regions", "Check the address space", "检查地址空间"),
        ("shader split", "Split shaders", "拆分着色器"), ("iOS shaders", "Convert iOS shaders", "转换 iOS 着色器"), ("Mac shaders", "Convert Mac shaders", "转换 Mac 着色器"),
        ("Vulkan shaders", "Convert Vulkan shaders", "转换 Vulkan 着色器"), ("GL shaders", "Convert GL shaders", "转换 GL 着色器"),
        ("prepare Xcode", "Prepare the Xcode project", "准备 Xcode 工程"), ("library project", "Create the library project", "生成游戏库工程"),
        ("library build", "Build the game library", "编译游戏库"), ("sign", "Sign", "签名"), ("shader archive", "Archive shaders", "打包着色器"),
        ("single file", "Write the single file", "合成单文件"), ("checksum", "Compute checksums", "计算校验值"), ("pack", "Assemble the game pack", "组装游戏包"),
        ("checking the inputs", "Check the inputs", "检查输入"), ("finding the NROs", "Find NRO modules", "查找 NRO 模块"),
    ]
    static func zh(_ name: String) -> String {
        for (key, en, zh) in table where name.hasPrefix(key) || name.contains(key) {
            let rest = name.hasPrefix(key) ? String(name.dropFirst(key.count)) : ""
            return launcherChinese ? zh + rest.replacingOccurrences(of: " (", with: "（").replacingOccurrences(of: ")", with: "）") : en + rest
        }
        return launcherChinese ? name : name.prefix(1).uppercased() + name.dropFirst()
    }
}
