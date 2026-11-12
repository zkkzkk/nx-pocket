// The main window: the games in the sidebar (their cover, name and what state their pack is in), the iPhone in reach and Storage at its foot; the selected
// game's page beside it; the build log below, which a failed build opens. Games are added by dropping folders or files anywhere on the window, or with +.
import SwiftUI

struct MainView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var dropping = false
    @AppStorage(AppLanguage.key) private var language = ""   // Settings › Language: the window is drawn again in it

    var body: some View {
        NavigationSplitView {
            Sidebar().navigationSplitViewColumnWidth(min: 240, ideal: 270, max: 340).id(language)
        } detail: {
            VStack(spacing: 0) {
                if let g = model.selected, !g.scanned {
                    VStack(spacing: 12) { ProgressView(); Text(tr("Reading the game's folder…")).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let g = model.selected { GameDetail(game: g).id(g.id + language) } else { EmptyLibrary().id(language) }
                if model.showLog, let lines = currentLog { LogPanel(lines: lines) }
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .toolbar { toolbar }
        .navigationTitle(model.selected?.name ?? "NX Pocket")
        .navigationSubtitle(model.selected.map { $0.titleID ?? "" } ?? "")
        .tint(Palette.accent)
        .dropDestination(for: URL.self) { urls, _ in model.add(urls); return !urls.isEmpty } isTargeted: { dropping = $0 }
        .overlay { if dropping { DropOverlay() } }
        .sheet(isPresented: $model.showInstall) { InstallSheet().environmentObject(model) }
        .modifier(UpdatesHost(updater: model.updater, upstream: model.upstream))
        .task {
            model.updater.start(); model.upstream.start(repo: model.repo)
            model.refreshDevices(); model.checkSetup()
            if !model.setupDone { openWindow(id: "setup") }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.rescan(); model.refreshDevices() }
    }

    private var currentLog: [String]? {
        guard let g = model.selected else { return nil }
        let build = model.builds[g.id]?.log ?? [], send = model.sends[g.id]?.run.log ?? []
        return build + send
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button { model.addWithPanel() } label: { Label(tr("Add Game"), systemImage: "plus") }.help(tr("Add a game's folder or files"))
        }
        if let g = model.selected {
            ToolbarItemGroup(placement: .primaryAction) {
                if model.builds[g.id]?.state == .running {
                    Button(role: .destructive) { model.builds[g.id]?.stop() } label: { Label(tr("Stop"), systemImage: "stop.fill") }
                } else {
                    Button { model.enqueue(g) } label: { Label(g.pack == nil ? tr("Make Game Pack") : tr("Make Again"), systemImage: "shippingbox") }
                        .disabled(!model.canBuild(g) || g.files.isEmpty)
                }
                Button { if let d = model.connected { model.send(g, to: d) } } label: { Label(tr("Send to iPhone"), systemImage: "iphone.and.arrow.forward") }
                    .disabled(g.pack == nil || model.connected == nil)
                Button { model.showLog.toggle() } label: { Label(tr("Log"), systemImage: "text.alignleft") }.help(tr("Show or hide the log (⇧⌘Y)"))
            }
        }
    }
}

// MARK: - Sidebar

private struct Sidebar: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        List(selection: $model.selection) {
            Section(tr("Games")) {
                ForEach(model.games) { g in
                    GameRow(game: g).tag(g.id)
                        .contextMenu {
                            Button(tr("Play on Mac")) { model.playOnMac(g) }.disabled(g.macApp == nil && (!model.canBuild(g) || g.files.isEmpty))
                            Button(tr("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([g.pack ?? g.folder]) }
                            Divider()
                            Button(tr("Remove from List"), role: .destructive) { model.remove(g) }
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack { Wordmark(light: false, size: 17); Spacer() }.padding(.horizontal, 18).padding(.top, 6).padding(.bottom, 10)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 8) {
                NoticeRows(updater: model.updater, upstream: model.upstream)
                DeviceRow()
                HStack(spacing: 8) {
                    Button { openWindow(id: "storage") } label: { Label(tr("Storage"), systemImage: "internaldrive").frame(maxWidth: .infinity) }
                    Button { model.checkSetup(); openWindow(id: "setup") } label: {
                        Label(tr("Setup"), systemImage: model.setupMissing ? "exclamationmark.triangle.fill" : "checkmark.seal").frame(maxWidth: .infinity)
                    }
                    .tint(model.setupMissing ? Palette.warn : nil)
                }
                .buttonStyle(.glass).controlSize(.regular)
            }
            .padding(12)
        }
    }
}

/// A game in the sidebar: its cover, its name, its pack's state in colour
private struct GameRow: View {
    @EnvironmentObject var model: AppModel
    let game: MacGame

    var body: some View {
        HStack(spacing: 11) {
            CoverArt(image: game.icon, name: game.name, side: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(game.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                status
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder private var status: some View {
        let (text, color, symbol) = state
        Label { Text(text).lineLimit(1) } icon: { Image(systemName: symbol) }
            .font(.system(size: 11)).foregroundStyle(color).labelStyle(.titleAndIcon)
            .help(game.pack != nil ? model.ages[game.id].map(PackAge.newer) ?? "" : "")
    }

    private var state: (String, Color, String) {
        if !game.scanned { return (tr("Reading…"), .secondary, "hourglass") }
        if let b = model.builds[game.id], b.state == .running { return (String(format: tr("Making… %d%%"), Int(b.fraction * 100)), Palette.accent, "gearshape.2.fill") }
        if let i = model.queue.firstIndex(of: game.id) { return (String(format: tr("Queued (%d)"), i + 1), Palette.accent, "hourglass") }
        if let s = model.sends[game.id], !s.finished, s.count > 0 { return (String(format: tr("Sending %d/%d"), s.index, s.count), Palette.accent, "arrow.up.circle.fill") }
        if model.builds[game.id]?.state == .failed { return (tr("Failed"), Palette.danger, "exclamationmark.circle.fill") }
        if model.sends[game.id]?.done == true { return (tr("On iPhone"), Palette.ok, "checkmark.circle.fill") }
        if game.pack != nil, model.ages[game.id]?.state == .stale { return (tr("Newer version available, still playable"), .secondary, "arrow.trianglehead.2.clockwise") }   // not a fault: it plays as made
        if game.pack != nil { return (tr("Pack ready"), Palette.ok, "shippingbox.fill") }
        if game.files.isEmpty { return (tr("No game files"), .secondary, "questionmark.folder") }
        return (tr("Not made yet"), .secondary, "circle.dashed")
    }
}

/// The iPhone in reach (a menu to choose one when several are connected) and NX Pocket on it: its build, and Install or Update when it has none or an older one
private struct DeviceRow: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: model.connected == nil ? "iphone.slash" : "iphone").font(.system(size: 18)).frame(width: 26)
                    .foregroundStyle(model.connected == nil ? Color.secondary : Palette.accent)
                VStack(alignment: .leading, spacing: 1) {
                    let others = model.devices.filter(\.connected)
                    if others.count > 1 {
                        Menu {
                            ForEach(others) { d in Button { model.targetID = d.id } label: { Text("\(d.name) · \(d.model)") } }
                        } label: { Text(model.connected?.name ?? "").font(.system(size: 12, weight: .semibold)) }
                            .menuStyle(.borderlessButton).fixedSize()
                    } else {
                        Text(model.connected?.name ?? tr("No iPhone")).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    }
                    Text(model.connected.map { "\($0.model) · iOS \($0.osVersion)" } ?? tr("Connect it with a cable and unlock it")).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Button { model.refreshDevices() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless).help(tr("Refresh")).accessibilityLabel(tr("Refresh"))
            }
            if let d = model.connected { pocket(d) }
        }
        .padding(10)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder private func pocket(_ d: Device) -> some View {
        let state = model.pocketState(d)
        HStack(spacing: 6) {
            switch state {
            case .unknown: ProgressView().controlSize(.mini); Text(tr("Looking for NX Pocket…")).foregroundStyle(.secondary)
            case .missing: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Palette.warn); Text(tr("NX Pocket is not installed"))
            case .old(let b): Image(systemName: "arrow.up.circle.fill").foregroundStyle(Palette.warn); Text(tr("NX Pocket update available")).help(String(format: tr("NX Pocket build %d is installed; this checkout makes a newer one."), b))
            case .current: Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.ok); Text(tr("NX Pocket is up to date"))
            case .tooOld: Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary); Text(String(format: tr("NX Pocket needs iOS %d or later"), AppModel.pocketMinimumOS)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if model.installing?.status == .running {
                Button(tr("Installing…")) { model.showInstall = true }.controlSize(.small)
            } else if state == .missing || { if case .old = state { return true } else { return false } }() {
                Button(state == .missing ? tr("Install") : tr("Update")) { model.installPocket(on: d) }.controlSize(.small).buttonStyle(.glassProminent)
            }
        }
        .font(.system(size: 10.5)).lineLimit(2).fixedSize(horizontal: false, vertical: true)   // English may take two lines
    }
}

/// Install NX Pocket's sheet: what it needs (a team), then the build and install as it goes, its output as in the log
struct InstallSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                if let logo = PlatformImage(named: "PocketLogo") { Image(platformImage: logo).resizable().frame(width: 40, height: 40).clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous)) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr("Install NX Pocket")).font(.system(size: 17, weight: .bold))
                    Text(tr("Built from NX Pocket's code on this Mac and installed over the cable. Games and saves on the iPhone stay.")).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            if model.pocketTeam.isEmpty {
                Label(tr("Set the team NX Pocket is signed with first (Settings › iPhone): game packs signed by a team play only in an NX Pocket of the same team."), systemImage: "person.badge.key")
                    .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                TextField(tr("Team for installing NX Pocket"), text: $model.pocketTeam, prompt: Text("ABCDE12345")).textFieldStyle(.roundedBorder).frame(width: 220)
            }
            if let r = model.installing { InstallLog(run: r) }
            HStack {
                Spacer()
                if model.installing?.status == .running { Button(tr("Stop")) { model.installing?.stop() } }
                else if model.installing == nil, let d = model.connected { Button(tr("Install")) { model.installPocket(on: d) }.buttonStyle(.glassProminent).disabled(model.pocketTeam.isEmpty) }
                Button(tr("Done")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20).frame(width: 620)
        .tint(Palette.accent)
    }
}

private struct InstallLog: View {
    @ObservedObject var run: ToolRun
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if run.status == .running { ProgressView().controlSize(.small) }
                Text(run.status == .running ? tr("Building and installing… (the first time takes several minutes)") : run.status == .succeeded ? tr("Installed.") : run.status == .cancelled ? tr("Stopped.") : tr("The install failed. See its output."))
                    .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(run.status == .succeeded ? Palette.ok : run.status == .running ? .primary : Palette.danger)
            }
            ScrollViewReader { r in
                ScrollView {
                    Text(run.log.suffix(300).joined(separator: "\n")).font(.system(size: 10.5, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled).id("end")
                }
                .frame(height: 240)
                .onChange(of: run.log.count) { _, _ in r.scrollTo("end", anchor: .bottom) }
            }
            .padding(8).background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        }
    }
}

// MARK: - Empty library

private struct EmptyLibrary: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        ZStack {
            Backdrop(image: PlatformImage(named: "PocketLogo"), key: "empty")
            VStack(spacing: 28) {
                Wordmark(light: false, size: 34)
                VStack(spacing: 6) {
                    Text(tr("Make your own Switch games into packs for NX Pocket")).font(.system(size: 22, weight: .semibold)).foregroundStyle(.white)
                    Text(About.short).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.55))
                }
                HStack(alignment: .top, spacing: 18) {
                    step(1, "folder.badge.plus", tr("Add a game"), tr("Its folder, or its NSP / XCI / NSZ / XCZ files"))
                    Image(systemName: "chevron.right").foregroundStyle(.white.opacity(0.4)).frame(height: 54)   // level with the circles
                    step(2, "shippingbox", tr("Make the game pack"), tr("With your own prod.keys"))
                    Image(systemName: "chevron.right").foregroundStyle(.white.opacity(0.4)).frame(height: 54)   // level with the circles
                    step(3, "iphone.and.arrow.forward", tr("Send to iPhone"), tr("To NX Pocket, over the cable"))
                }
                DashedTile(side: 220, symbol: "square.and.arrow.down", title: tr("Drop game folders here, or click to choose")) { model.addWithPanel() }
            }
            .padding(40)
        }
    }
    private func step(_ n: Int, _ symbol: String, _ title: String, _ note: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 24, weight: .medium)).frame(width: 54, height: 54).glassEffect(.regular, in: .circle)
            Text("\(n). \(title)").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
            Text(note).font(.system(size: 11)).foregroundStyle(Palette.soft).multilineTextAlignment(.center).frame(width: 170)
        }
    }
}

private struct DropOverlay: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Palette.accent, style: StrokeStyle(lineWidth: 3, dash: [10, 8]))
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Palette.accent.opacity(0.08)))
            .overlay(Label(tr("Drop to add the game"), systemImage: "plus.circle.fill").font(.system(size: 20, weight: .semibold)).padding(18).glassEffect(.regular, in: .capsule))
            .padding(10).allowsHitTesting(false)
    }
}

// MARK: - Log

struct LogPanel: View {
    @EnvironmentObject var model: AppModel
    let lines: [String]
    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                Label(tr("Log"), systemImage: "text.alignleft").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string) } label: { Label(tr("Copy"), systemImage: "doc.on.doc") }
                Button { model.showLog = false } label: { Image(systemName: "xmark") }
            }
            .buttonStyle(.borderless).padding(.horizontal, 14).padding(.vertical, 7)
            ScrollViewReader { r in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(lines.suffix(2000).enumerated()), id: \.offset) { i, l in
                            Text(l).font(.system(size: 11, design: .monospaced)).foregroundStyle(color(l)).textSelection(.enabled).id(i)
                        }
                    }
                    .padding(.horizontal, 14).padding(.bottom, 8)
                }
                .onChange(of: lines.count) { _, _ in r.scrollTo(min(lines.count, 2000) - 1, anchor: .bottom) }
                .onAppear { r.scrollTo(min(lines.count, 2000) - 1, anchor: .bottom) }
            }
        }
        .frame(height: 220)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.6))
    }
    private func color(_ l: String) -> Color {
        l.contains("[RED]") || l.hasPrefix("✗") || l.contains("Traceback") ? Palette.danger : l.hasPrefix("✓") ? Palette.ok : l.hasPrefix("$ ") ? Palette.accent : .primary
    }
}

/// The update sheet, and the upstream window opened from the menu or the sidebar
private struct UpdatesHost: ViewModifier {
    @ObservedObject var updater: Updater
    @ObservedObject var upstream: Upstream
    @Environment(\.openWindow) private var openWindow
    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $updater.showSheet) { UpdateSheet(updater: updater) }
            .onChange(of: upstream.showWindow) { _, show in if show { openWindow(id: "upstream"); upstream.showWindow = false } }
    }
}

/// The sidebar's notices above the iPhone: a newer NX Pocket for Mac, upstream commits this checkout has not
private struct NoticeRows: View {
    @ObservedObject var updater: Updater
    @ObservedObject var upstream: Upstream
    var body: some View {
        VStack(spacing: 6) {
            if case .available(let m) = updater.state {
                notice("arrow.down.circle.fill", String(format: tr("NX Pocket %@ is out"), m.version)) { updater.showSheet = true }
            }
            if let r = upstream.report, r.behind > 0 {
                notice("arrow.triangle.branch", String(format: tr("Upstream has %d new commits"), r.behind)) { upstream.showWindow = true }
            }
        }
    }
    private func notice(_ symbol: String, _ text: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(text, systemImage: symbol).font(.system(size: 11.5, weight: .medium)).frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.glass).controlSize(.small)
    }
}
