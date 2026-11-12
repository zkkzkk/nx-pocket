// The setup window (first launch, or Setup in the sidebar): what making game packs needs, each with its state and the way to fix it (install, open, choose),
// the output of an install below. Install All runs every install in one go (in Terminal when one asks for the password); Done when nothing is missing;
// Later leaves it for now.
import SwiftUI

struct SetupView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                if let logo = PlatformImage(named: "PocketLogo") {
                    Image(platformImage: logo).resizable().frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 56 * 0.225, style: .continuous))
                        .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(tr("Welcome to NX Pocket")).font(.system(size: 22, weight: .bold))
                    Text(tr("Before making game packs, check that this Mac has everything they need.")).font(.system(size: 12.5)).foregroundStyle(.secondary)
                }
            }
            .padding(24)
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    if model.setup.isEmpty { ProgressView().padding(40) }
                    ForEach(model.setup) { item in
                        row(item)
                        if item.id != model.setup.last?.id { Divider().padding(.leading, 58) }
                    }
                }
                .padding(.vertical, 6)
            }
            .frame(height: 430)
            if let run = model.setupRun { InstallLog(run: run) }
            else if model.setupInTerminal {
                Label(tr("Installing in Terminal. Type your Mac's password there when it asks (nothing shows as you type). This list updates when you come back."), systemImage: "terminal")
                    .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 22).padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading).background(Color.primary.opacity(0.04))
            }
            Divider()
            Text(About.disclaimer).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 22).padding(.top, 12)
            HStack {
                Button { model.checkSetup() } label: { Label(tr("Check Again"), systemImage: "arrow.clockwise") }
                Spacer()
                Button(tr("Later")) { dismiss() }.keyboardShortcut(.cancelAction)
                if model.setupInstallable {
                    Button { model.installAll() } label: { Label(tr("Install All"), systemImage: "arrow.down.circle") }
                        .keyboardShortcut(.defaultAction).buttonStyle(.glassProminent).disabled(model.setupRun?.status == .running)
                } else {
                    Button(tr("Done")) { model.setupDone = true; dismiss() }.keyboardShortcut(.defaultAction).buttonStyle(.glassProminent).disabled(model.setupMissing || model.setup.isEmpty)
                }
            }
            .padding(16)
        }
        .frame(width: 640)
        .tint(Palette.accent)
        .onAppear { model.checkSetup() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in   // back from Terminal (or the App Store)
            if model.setupRun?.status != .running { model.setupInTerminal = false; model.checkSetup() }
        }
    }

    private func row(_ item: SetupItem) -> some View {
        HStack(spacing: 14) {
            Group {
                switch item.state {
                case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.ok)
                case .missing: Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.danger)
                case .optional: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Palette.warn)
                case .checking: ProgressView().controlSize(.small)
                }
            }
            .font(.system(size: 20)).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.system(size: 13.5, weight: .semibold))
                Text(item.detail).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
            }
            Spacer()
            if let a = item.alternate, item.state != .ok { Button(label(a, ok: false)) { model.perform(a) }.disabled(model.setupRun?.status == .running) }
            if let a = item.install, item.state != .ok || a == .chooseRepo || a == .chooseKeys || a == .choosePython || a == .chooseEnv {
                Button(label(a, ok: item.state == .ok)) { model.perform(a) }.disabled(model.setupRun?.status == .running)
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 11)
    }

    private func label(_ a: SetupAction, ok: Bool) -> String {
        switch a {
        case .command, .terminal, .installTools: return tr("Install")
        case .open: return tr("Open")
        case .chooseRepo, .chooseKeys, .choosePython, .chooseEnv: return ok ? tr("Change…") : tr("Choose…")
        }
    }
}

private struct InstallLog: View {
    @ObservedObject var run: ToolRun
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if run.status == .running { ProgressView().controlSize(.small) }
                Text(run.status == .running ? tr("Installing…") : run.status == .succeeded ? tr("Installed") : tr("The install failed. See its output.")).font(.system(size: 12, weight: .semibold))
            }
            ScrollView {
                Text(run.log.suffix(200).joined(separator: "\n")).font(.system(size: 10.5, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }
            .frame(height: 110)
        }
        .padding(.horizontal, 22).padding(.vertical, 10)
        .background(Color.primary.opacity(0.04))
    }
}
