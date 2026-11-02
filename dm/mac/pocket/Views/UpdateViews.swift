// The update sheet (Updater: a newer NX Pocket for Mac, its notes, downloading, checking and installing it, and how to open an app macOS has not seen notarized) and the
// upstream window (Upstream: how this checkout stands against nxnative's, its new commits, and which game packs merging them would put out of date).
import SwiftUI

struct UpdateSheet: View {
    @ObservedObject var updater: Updater
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                if let logo = PlatformImage(named: "PocketLogo") { Image(platformImage: logo).resizable().frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous)) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr("NX Pocket Updates")).font(.system(size: 17, weight: .bold))
                    Text(String(format: tr("This is build %d."), Updater.currentBuild)).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            switch updater.state {
            case .idle, .checking: HStack { ProgressView().controlSize(.small); Text(tr("Checking for updates…")) }
            case .upToDate: Label(tr("NX Pocket is up to date."), systemImage: "checkmark.circle.fill").foregroundStyle(Palette.ok)
            case .failed(let why): Label(why, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Palette.warn).fixedSize(horizontal: false, vertical: true)
            case .downloading: HStack { ProgressView().controlSize(.small); Text(tr("Downloading and checking its signature…")) }
            case .available(let m), .ready(let m):
                Text(String(format: tr("Version %@ (build %d) is out."), m.version, m.build)).font(.system(size: 14, weight: .semibold))
                if let n = m.notes, !n.isEmpty {
                    ScrollView { Text(n).font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                        .frame(maxHeight: 160).padding(8).background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
                }
                if case .ready = updater.state {
                    Label(tr("Downloaded. The signature is valid."), systemImage: "checkmark.seal.fill").foregroundStyle(Palette.ok)
                    if !updater.replaceable {
                        Text(tr("NX Pocket cannot replace itself where it is. Quit it and put the new copy in Applications yourself.")).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
            }
            Text(tr("NX Pocket is not notarized by Apple. If macOS says it cannot be opened, open System Settings › Privacy & Security and click Open Anyway (or Control-click the app and choose Open)."))
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(tr("Check Again")) { Task { await updater.check(manual: true) } }.disabled(updater.state == .checking || updater.state == .downloading)
                Spacer()
                Button(tr("Done")) { dismiss() }.keyboardShortcut(.cancelAction)
                switch updater.state {
                case .available(let m): Button(tr("Download")) { Task { await updater.download(m) } }.buttonStyle(.glassProminent)
                case .ready:
                    if updater.replaceable { Button(tr("Install and Reopen")) { updater.install() }.buttonStyle(.glassProminent) }
                    else { Button(tr("Show in Finder")) { updater.showNewApp() }.buttonStyle(.glassProminent) }
                default: EmptyView()
                }
            }
        }
        .padding(20).frame(width: 520)
        .tint(Palette.accent)
    }
}

struct UpstreamView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var upstream: Upstream

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(tr("Upstream nxnative")).font(.system(size: 20, weight: .bold))
                    Text("\(upstream.url) · \(upstream.branch)").font(.system(size: 11.5)).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer()
                Button { Task { await upstream.check(repo: model.repo) } } label: { Label(tr("Check Now"), systemImage: "arrow.clockwise") }.disabled(upstream.state == .checking)
            }
            switch upstream.state {
            case .idle: Text(tr("Not checked yet.")).foregroundStyle(.secondary)
            case .checking: HStack { ProgressView().controlSize(.small); Text(tr("Fetching upstream's commits…")) }
            case .failed(let why): Label(why, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Palette.warn).fixedSize(horizontal: false, vertical: true)
            case .done(let r): report(r)
            }
            Text(tr("NX Pocket only shows the difference: it does not merge or switch your code. Merge upstream in your checkout yourself (git merge). The packs listed keep working; make them again when you want what changed."))
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(20).frame(minWidth: 640, minHeight: 460).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .tint(Palette.accent)
        .task { if upstream.state == .idle { await upstream.check(repo: model.repo) } }   // opened before the day's check: check now
    }

    @ViewBuilder private func report(_ r: UpstreamReport) -> some View {
        HStack(spacing: 20) {
            stat("\(r.behind)", tr("new upstream commits"), r.behind > 0 ? Palette.warn : Palette.ok)
            stat("\(r.ahead)", tr("of yours not upstream"), Palette.accent)
            Text(String(format: tr("Checked %@"), r.checked.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(Locale(identifier: launcherChinese ? "zh-Hans" : "en_US")))))
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        let hit = model.games.compactMap { g -> (String, [String])? in let c = upstream.wouldChange(g); return c.isEmpty ? nil : (g.name, c) }
        if r.behind > 0 {
            GroupBox(tr("Game packs with a newer version after merging (they still play)")) {
                VStack(alignment: .leading, spacing: 4) {
                    if hit.isEmpty { Text(tr("None: its changes do not touch what your packs are made of.")).foregroundStyle(.secondary) }
                    ForEach(hit, id: \.0) { name, parts in Text("\(name): \(parts.joined(separator: tr(", ")))").foregroundStyle(.secondary) }
                }
                .font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
            }
            List(r.commits) { c in
                HStack(spacing: 10) {
                    Text(c.id).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    Text(c.subject).lineLimit(1)
                    Spacer()
                    Text("\(c.author) · \(c.date)").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .font(.system(size: 12))
            }
            .frame(minHeight: 200)
        } else {
            Label(tr("Your checkout has every upstream commit."), systemImage: "checkmark.circle.fill").foregroundStyle(Palette.ok)
        }
    }
    private func stat(_ n: String, _ label: String, _ c: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) { Text(n).font(.system(size: 26, weight: .bold).monospacedDigit()).foregroundStyle(c); Text(label).font(.system(size: 11)).foregroundStyle(.secondary) }
    }
}
