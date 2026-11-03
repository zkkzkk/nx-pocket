// Launcher: NX Pocket's home screen, shown before the game starts (front_ios.m dm_show_launcher; the screen: LauncherHome.swift, its games: GameLibrary.swift). Its settings come from the
// app's dm/launcher.json, which build_ipa.sh writes for this game from dm/games/settings.tsv (dm/games/settings.py): each sets an environment variable the host reads when the game starts.
// A variable an env file set (Documents/env.txt, the bundle's dm/env.txt; main.m lists them in DM_ENV_FILE_KEYS) is shown but kept. The settings are drawn by section on the home screen's
// pages (rows: LauncherRow.swift): Game settings has them all, Local play and Button layout one section each. Choices that differ from the game's default are kept
// in UserDefaults; Reset to tested defaults shows the defaults, and Play then forgets them. DM_LAUNCHER=0 in Documents/env.txt starts the game at once with the saved choices; DM_SAVED_CHOICES=0 ignores them (and keeps them)
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import Darwin
import os

/// Cloud saves: an iCloud Drive folder shared with the Mac app (chosen in its settings window's
/// Cloud saves too). The host brings the save in from there when the game starts and
/// sends it there after each save (dm/host/save_sync.h); the folder is a bookmark (CloudSaves.m).
struct CloudSavesSection: View {
    @State private var folder: String = ""
    @State private var note: String = ""
    @State private var picking = false

    var body: some View {
        Section {
            HStack {
                Text(tr("Cloud saves"))
                Spacer()
                Text(folder.isEmpty ? tr("Off") : (folder as NSString).lastPathComponent)
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Button(folder.isEmpty ? tr("Choose a folder in iCloud Drive…") : tr("Choose a different folder…")) { picking = true }
                // The sheet sits on the button, not on the Section: SwiftUI hands a Section's modifiers to every row, so one tap presented a picker per row and they invalidated each other (LNPANDY/NX2Apple#315).
                .sheet(isPresented: $picking) {
                    DocumentPicker(types: [.folder]) { url in
                        picking = false
                        if dm_store_cloud_saves(url) {
                            note = tr("Folder saved. It takes effect the next time a game starts.")
                            refresh()
                        } else {
                            note = tr("This folder cannot be used. Choose another folder.")
                        }
                    } onCancel: { picking = false }
                }
            if !folder.isEmpty {
                Button(tr("Turn off cloud saves"), role: .destructive) {
                    dm_clear_cloud_saves(); refresh(); note = ""
                }
            }
        } footer: {
            Text(note.isEmpty
                 ? tr("Use the same iCloud Drive folder as Cloud Saves in the Mac app. Saves are downloaded when a game starts and uploaded after each save; replaced saves are kept in save-backups.")
                 : note)
        }

        .onAppear(perform: refresh)
    }

    private func refresh() {
        var stale: ObjCBool = false
        folder = dm_cloud_saves_path(&stale) ?? ""
        if stale.boolValue && folder.isEmpty {
            note = tr("The previously selected folder is no longer accessible. Choose it again.")
        }
    }
}

/// UIDocumentPickerViewController for a folder (the cloud-save folder, a game pack), in the two callbacks a SwiftUI sheet wants.
struct DocumentPicker: UIViewControllerRepresentable {
    var types: [UTType] = [.folder]
    let onPick: (URL) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // .open (not .import): the folder stays where it is and the bookmark keeps pointing at it.
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: false)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick, onCancel: onCancel) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        let onCancel: () -> Void
        init(onPick: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick; self.onCancel = onCancel
        }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first { onPick(url) } else { onCancel() }
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { onCancel() }
    }
}

/// The memory iOS still lets the app use, refreshed every 2 s (Settings page)
struct MemorySection: View {
    @State private var memory = os_proc_available_memory()

    var body: some View {
        Section {
            HStack {
                Text(tr("Memory available"))
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: Int64(memory), countStyle: .memory)).monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .task {
            while !Task.isCancelled {
                memory = os_proc_available_memory()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}

// This device's IPv4 address on Wi-Fi (en0), as local play's peers reach it (hle_sock.c dm_net_local picks the same interface)
func wifiAddress() -> String? {
    var list: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&list) == 0, let first = list else { return nil }
    defer { freeifaddrs(list) }
    for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
        let a = p.pointee
        guard let sa = a.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET), String(cString: a.ifa_name).hasPrefix("en"), a.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 { return String(cString: host) }
    }
    return nil
}

// UIHostingController on an iPhone leaves out upside-down portrait; the launcher turns either way up, as the game's root view controller does (front_ios.m, Halfold)
final class LauncherHost<Content: View>: UIHostingController<Content> {
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .all }
}

// Shows the launcher over the root view controller and calls done once the settings are in the environment; false (done is not called) when there is no launcher
@_cdecl("dm_show_launcher")
public func dmShowLauncher(_ viewController: UnsafeMutableRawPointer, _ done: @convention(c) () -> Void) -> Bool {
    guard let url = Bundle.main.resourceURL?.appendingPathComponent("dm/launcher.json"), let data = try? Data(contentsOf: url) else { return false }
    guard let file = try? JSONDecoder().decode(SettingsFile.self, from: data), !file.settings.isEmpty else { fputs("[RED] launcher: dm/launcher.json cannot be read; starting the game\n", stderr); return false }
    if ProcessInfo.processInfo.environment["DM_LAUNCHER"] == "0" { fputs("launcher: off (DM_LAUNCHER=0)\n", stderr); LauncherModel(file.settings).applySaved(); return false }
    let parent = Unmanaged<UIViewController>.fromOpaque(viewController).takeUnretainedValue()
    let library = GameLibrary.embedded(titleID: file.game, settings: file.settings)
    var host: UIViewController?
    let view = LauncherHome(library: library) {
        guard let h = host, library.selected.playable else { return }
        host = nil
        library.markPlayed(library.selected.id)
        library.model.apply()
        h.dismiss(animated: false) { done() }
    }
    let h = LauncherHost(rootView: view)
    h.modalPresentationStyle = .fullScreen
    host = h
    parent.present(h, animated: false)
    fputs("launcher: \(file.settings.count) settings shown\n", stderr)
    return true
}
