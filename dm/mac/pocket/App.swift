// NX Pocket for Mac (project.yml): the main window (games in a sidebar, the selected one's page: its pack, sending it to an iPhone, its files; the build log below),
// the setup window (first launch, or anything missing), the storage window and Settings.
import SwiftUI

@main
struct NXPocketMacApp: App {
    @StateObject private var model = AppModel()
    @AppStorage(AppLanguage.key) private var language = ""   // the menus' own items (Add Game, Check for Updates…) in it

    var body: some Scene {
        WindowGroup("NX Pocket", id: "main") {
            MainView().environmentObject(model).frame(minWidth: 980, minHeight: 640)
        }
        .defaultSize(width: 1220, height: 800)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button(tr("About NX Pocket")) { showAbout() }
                Button(tr("Check for Updates…")) { Task { await model.updater.check(manual: true) } }
                if Upstream.enabled { Button(tr("Upstream nxnative…")) { model.upstream.showWindow = true } }
            }
            CommandGroup(after: .newItem) {
                Button(tr("Add Game…")) { model.addWithPanel() }.keyboardShortcut("o")
            }
            CommandGroup(after: .toolbar) {
                Button(model.showLog ? tr("Hide Log") : tr("Show Log")) { model.showLog.toggle() }.keyboardShortcut("y", modifiers: [.command, .shift])
            }
        }
        Window(tr("Set Up NX Pocket"), id: "setup") { SetupView().environmentObject(model) }
            .windowResizability(.contentSize)
        Window(tr("Upstream nxnative"), id: "upstream") { UpstreamView(upstream: model.upstream).environmentObject(model) }
            .defaultSize(width: 720, height: 560)
        Window(tr("Storage"), id: "storage") { StorageView().environmentObject(model).frame(minWidth: 640, minHeight: 360) }
            .defaultSize(width: 760, height: 460)
        Settings { SettingsView().environmentObject(model) }
    }
}

/// The About window: the standard one, with what NX Pocket is built on and that it has nothing to do with Nintendo as its credits
private func showAbout() {
    let p = NSMutableParagraphStyle(); p.alignment = .center
    let text = [About.basedOn, About.nxPlay, About.disclaimer].joined(separator: "\n\n")
    let credits = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: p])
    NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])   // "Version 1.0 (<build>)": the build is the commit count (build.sh)
    NSApp.activate()
}

extension AppModel {
    func addWithPanel() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = true; p.allowsMultipleSelection = true
        p.allowedContentTypes = []; p.prompt = tr("Add")
        p.message = tr("Choose a game's folder, or its NSP / XCI / NSZ / XCZ files.")
        if p.runModal() == .OK { add(p.urls) }
    }
}
