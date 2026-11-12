// Settings: the player's prod.keys (only the path is kept, the keys never copied), how game packs are signed, NX Pocket's bundle ID on the iPhone (found by its
// name when empty), and, folded away under Advanced, what a developer changes: the code folder, the Python, an environment script, where updates and upstream come from.
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var signs = false
    @State private var advanced = false
    @AppStorage(AppLanguage.key) private var language = ""
    @AppStorage("updateRepo") private var updateRepo = "zkkzkk/nx-pocket"
    @AppStorage("upstreamURL") private var upstreamURL = ""
    @AppStorage("upstreamBranch") private var upstreamBranch = ""

    var body: some View {
        Form {
            Section {
                Picker(tr("Language"), selection: Binding(get: { language }, set: { AppLanguage.choose($0); language = $0; model.rescan() })) {
                    Text(tr("System")).tag("")
                    Text("简体中文").tag("zh-Hans")
                    Text("English").tag("en")
                }
            } footer: { Text(tr("The menu bar's standard items follow the next time NX Pocket starts.")).font(.footnote).foregroundStyle(.secondary) }
            Section(tr("Keys")) {
                path("prod.keys", model.keys) { model.perform(.chooseKeys) }
            }
            Section {
                Picker(tr("Signing"), selection: $signs) {
                    Text(tr("Unsigned: NX Pocket signs it on the iPhone")).tag(false)
                    Text(tr("Signed with my team")).tag(true)
                }
                .pickerStyle(.radioGroup).horizontalRadioGroupLayout()
                if signs { TextField(tr("Team ID"), text: $model.team, prompt: Text("ABCDE12345")) }
                path(tr("Game pack folder"), model.packsFolder) { if let u = model.choose(folder: true, prompt: tr("Choose")) { model.packsFolder = u.path } }
                Toggle(isOn: $model.fullVerify) {
                    Text(tr("Full check (recommended when sharing packs)"))
                    Text(tr("Puts checksums for all of the game data in the pack, so the iPhone can check every part. Reads the game data once more if its checksums were not saved during extraction.")).font(.footnote)
                }
            } header: { Text(tr("Game packs")) } footer: {
                Text(tr("New game packs are made in the game pack folder, apart from the build files. A game's pack is found there by its title ID, else in the game's folder.")
                     + " " + tr("An unsigned pack plays in anyone's NX Pocket that holds a developer certificate. A pack signed with your team plays in an NX Pocket signed by the same team.")).font(.footnote).foregroundStyle(.secondary)
            }
            Section(tr("iPhone")) {
                TextField(tr("NX Pocket's bundle ID"), text: $model.bundleID, prompt: Text(tr("Found automatically")))
                TextField(tr("Team for installing NX Pocket"), text: $model.pocketTeam, prompt: Text("ABCDE12345"))
            }
            Section {
                DisclosureGroup(tr("Advanced"), isExpanded: $advanced) {
                    path(tr("Code folder"), model.repo) { model.perform(.chooseRepo) }
                    path("Python", model.python) { model.perform(.choosePython) }
                    path(tr("Environment script"), model.envScript) { model.perform(.chooseEnv) }
                    TextField(tr("Releases from (GitHub owner/name)"), text: $updateRepo, prompt: Text("zkkzkk/nx-pocket"))
                    TextField(tr("Upstream nxnative"), text: $upstreamURL, prompt: Text("https://github.com/seedds/nxnative"))
                    TextField(tr("Upstream branch"), text: $upstreamBranch, prompt: Text("main"))
                }
            } footer: {
                Text(tr("NX Pocket for Mac checks this repository's GitHub releases once a day and installs a newer one only when its signature checks out. Upstream nxnative is only compared with your checkout: nothing is merged, and nothing is written to GitHub."))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 620, height: 600)
        .tint(Palette.accent)
        .onAppear { signs = !model.team.isEmpty }
        .onChange(of: signs) { _, s in if !s { model.team = "" } }
    }

    private func path(_ title: String, _ value: String, choose: @escaping () -> Void) -> some View {
        LabeledContent(title) {
            HStack {
                Text(value.isEmpty ? tr("Not chosen") : (value as NSString).abbreviatingWithTildeInPath).font(.system(size: 12)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled).help(value)
                    .frame(maxWidth: 330, alignment: .trailing)
                Button(tr("Choose…"), action: choose)
            }
        }
    }
}
