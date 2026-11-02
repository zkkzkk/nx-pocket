// The storage window: each game's build files (what the next build reuses) and game pack, the game pack folder's other packs, their sizes, and deleting any after
// the player confirms.
import SwiftUI

struct StorageView: View {
    @EnvironmentObject var model: AppModel
    @State private var rows: [StorageRow] = []
    @State private var loading = true
    @State private var confirm: (StorageRow, Bool)?   // the row, and whether it is its pack (else its build files)

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(tr("Storage")).font(.system(size: 20, weight: .bold))
                    Text(tr("Build files speed up the next build of a game; a game pack can be made again from them.")).font(.system(size: 12)).foregroundStyle(.secondary)
                    if !model.packsFolder.isEmpty {
                        Text(String(format: tr("Game packs: %@ in %@"), ByteCountFormatter.string(fromByteCount: rows.reduce(0) { $0 + ($1.packBytes ?? 0) }, countStyle: .file),
                                    (model.packsFolder as NSString).abbreviatingWithTildeInPath))
                            .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                else { Text(String(format: tr("%@ total"), ByteCountFormatter.string(fromByteCount: rows.reduce(0) { $0 + ($1.total ?? 0) }, countStyle: .file))).font(.system(size: 15, weight: .semibold).monospacedDigit()) }
            }
            .padding(20)
            Table(rows) {
                TableColumn(tr("Game")) { r in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(r.name).fontWeight(.medium)
                        Text((r.id as NSString).abbreviatingWithTildeInPath).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                    }
                }
                TableColumn(tr("Build files")) { r in sizeCell(r.buildBytes, delete: r.build == nil ? nil : { confirm = (r, false) }) }
                TableColumn(tr("Game pack")) { r in sizeCell(r.packBytes, delete: r.pack == nil ? nil : { confirm = (r, true) }) }
                TableColumn(tr("Total")) { r in Text(r.total.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "…").monospacedDigit().fontWeight(.semibold) }
            }
        }
        .tint(Palette.accent)
        .task { await load() }
        .confirmationDialog(confirm.map { $0.1 ? String(format: tr("Delete the game pack of %@?"), $0.0.name) : String(format: tr("Delete the build files of %@?"), $0.0.name) } ?? "",
                            isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), presenting: confirm) { c in
            Button(tr("Delete"), role: .destructive) {
                if let u = c.1 ? c.0.pack : c.0.build { try? FileManager.default.trashItem(at: u, resultingItemURL: nil) }
                model.rescan(c.0.id); Task { await load() }
            }
        } message: { c in
            Text(c.1 ? tr("It goes to the Trash. The game on the iPhone is not affected.") : tr("It goes to the Trash. The next build of this game starts from the beginning."))
        }
    }

    private func sizeCell(_ bytes: Int64?, delete: (() -> Void)?) -> some View {
        HStack {
            if let bytes { Text(bytes > 0 ? ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) : "—").monospacedDigit() }
            else { ProgressView().controlSize(.mini) }
            Spacer()
            if let delete, let bytes, bytes > 0 { Button(action: delete) { Image(systemName: "trash") }.buttonStyle(.borderless).help(tr("Delete")).accessibilityLabel(tr("Delete")) }
        }
    }

    private func load() async {
        loading = true
        let folder = model.packsURL
        rows = Storage.rows(model.games, packs: await Task.detached { PackEntry.index(folder) }.value)
        for i in rows.indices {
            let (b, p) = (rows[i].build, rows[i].pack)
            let sizes = await Task.detached { (Storage.size(b), Storage.size(p)) }.value
            guard i < rows.count else { break }
            rows[i].buildBytes = sizes.0; rows[i].packBytes = sizes.1
        }
        loading = false
    }
}
