// NX Pocket's home screen (shown by Launcher.swift dm_show_launcher before the game starts): the selected game's icon, enlarged, blurred and darkened, as the background; its name,
// last-played time, Game settings and Play; a row (landscape) or grid (portrait) of the library's games with the selected one enlarged; Import game pack last; and four round
// shortcuts: Import, Local play, Button layout, Settings. Its pages (game settings, local play, controls, settings) draw the same settings rows as before (SettingsList, LauncherRow.swift).
// Portrait follows HalfoldKit (hf_kit.h): the upper region holds the selected game and Play, the lower one the games and the shortcuts, and nothing sits on the fold between them
// (the iPhone Duo's inner screen; the window's middle on a phone with no hinge across it). Colours: dark, a white primary button, accent #4FD1C5; the system font.
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// The palette, the backdrop, the wordmark and the buttons are PocketStyle.swift's, shared with NX Pocket for Mac
private let pick = Animation.spring(response: 0.32, dampingFraction: 0.78)   // a game tile growing or shrinking as the selection moves

enum LauncherPage: Hashable { case details, importer, localPlay, controls, settings }

/// The hinge status and the fold (window points; nil: none reported, the window's middle), from DmFoldProbe (LauncherFold.m)
struct FoldState: Equatable { var hinge: Int32 = 0; var fold: CGRect? }

private struct FoldReader: UIViewRepresentable {
    @Binding var state: FoldState
    func makeUIView(context: Context) -> DmFoldProbe {
        let v = DmFoldProbe()
        v.onChange = { hinge, have, fold in
            let s = FoldState(hinge: hinge, fold: have ? fold : nil)
            DispatchQueue.main.async { if state != s { state = s; fputs("launcher: hinge \(hinge), fold \(have ? "\(fold)" : "at the middle")\n", stderr) } }
        }
        return v
    }
    func updateUIView(_ v: DmFoldProbe, context: Context) {}
}

struct LauncherHome: View {
    @ObservedObject var library: GameLibrary
    let play: () -> Void
    var close: (() -> Void)? = nil   // NX Pocket: close the game paused under the home screen
    var m: LauncherModel { library.model }   // the selected game's settings
    @State private var fold = FoldState()
    @State private var page: LauncherPage?
    @State private var deleting: GameEntry?   // the pack Game settings' Delete asks about
    @State private var trashFor: String?      // the tile held down: it shows a trash button that deletes its pack
    @State private var trashSince = Date.distantPast   // the finger lifting off the held tile is not a tap that puts the trash away
    @AppStorage(AppLanguage.key) private var language = ""   // Settings › Language: the screen is drawn again in it (.id below), the open page kept

    var body: some View {
        // The reader keeps the safe area so its insets are known; the screen itself is drawn over the whole window (the background under the notch and the home indicator)
        GeometryReader { g in
            let safe = g.safeAreaInsets
            let size = CGSize(width: g.size.width + safe.leading + safe.trailing, height: g.size.height + safe.top + safe.bottom)
            let layout = homeLayout(size, safe)
            let portrait = layout.posture != HF_LANDSCAPE
            ZStack(alignment: .topLeading) {
                Backdrop(image: library.selected.icon, key: library.selected.id, foldAt: portrait ? layout.controls.y / max(size.height, 1) : nil)
                    .contentShape(Rectangle()).onTapGesture { dismissTrash() }
                Group {
                    if portrait { PortraitHome(home: self, layout: layout, safe: safe) } else { LandscapeHome(home: self, size: size, safe: safe) }
                }
                .opacity(page == nil || page == .importer ? 1 : 0)
                if let page { pageView(page, size: size, safe: safe, portrait: portrait).transition(.opacity) }
            }
            .id(language)
            .frame(width: size.width, height: size.height)
            .offset(x: -safe.leading, y: -safe.top)
            .animation(.easeInOut(duration: 0.2), value: page)
            .onChange(of: library.opening) { _, u in if u != nil, library.canImport { page = .importer } }
            .onAppear { if library.opening != nil, library.canImport { page = .importer } }
        }
        .background(FoldReader(state: $fold).ignoresSafeArea())
        .background(Palette.ground)
        .foregroundStyle(.white)
        .alert(String(format: tr("Delete %@?"), deleting?.name ?? ""), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { g in
            if g.titleID == library.runningID {
                Button(tr("OK"), role: .cancel) {}
            } else {
                Button(tr("Cancel"), role: .cancel) {}
                Button(tr("Delete"), role: .destructive) { page = nil; library.remove(g.titleID) }
            }
        } message: { g in
            Text(tr(g.titleID == library.runningID ? "Close the game before deleting it."
                    : g.pack?.linked == true ? "The link to the game pack is removed; the pack itself stays in its location. Saves and settings are kept."
                    : "The game pack is removed from this device. Saves and settings are kept."))
        }
        .environment(\.colorScheme, .dark)   // the pages' lists and menus too, whatever the phone's appearance
        .preferredColorScheme(.dark)
        .statusBarHidden()
    }

    // HalfoldKit's regions for this window: landscape = the whole window; portrait / tabletop = the upper (picture) and lower (controls) regions either side of the fold
    private func homeLayout(_ size: CGSize, _ safe: EdgeInsets) -> hf_layout {
        let w = Double(size.width), h = Double(size.height)
        let insets = hf_insets(top: safe.top, left: safe.leading, bottom: safe.bottom, right: safe.trailing)
        let posture = hf_posture_of(w, h, fold.hinge)
        guard let f = fold.fold else { return hf_layout_make_at(posture, w, h, insets, fold.hinge, 0, nil) }
        var d = hf_rect(x: f.minX, y: f.minY, w: f.width, h: f.height)
        return hf_layout_make_at(posture, w, h, insets, fold.hinge, 0, &d)
    }

    func open(_ p: LauncherPage) { page = p }
    // Holding a pack's tile shows a trash button on it (not on the game paused under the home screen: close it first); a tap on the trash deletes the pack, a tap
    // anywhere else puts the trash away
    var trashShown: String? { trashFor }
    func holdTile(_ g: GameEntry) -> (() -> Void)? {
        g.pack == nil || g.titleID == library.runningID ? nil : { trashSince = Date(); withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { trashFor = g.id } }
    }
    func tapTile(_ g: GameEntry) {
        if trashFor != nil { if Date().timeIntervalSince(trashSince) > 0.6 { withAnimation(.easeOut(duration: 0.15)) { trashFor = nil } } } else { select(g) }
    }
    func dismissTrash() { if trashFor != nil { withAnimation(.easeOut(duration: 0.15)) { trashFor = nil } } }
    func deleteNow(_ g: GameEntry) { withAnimation(.easeOut(duration: 0.2)) { trashFor = nil; library.remove(g.titleID) } }
    func select(_ g: GameEntry) { withAnimation(pick) { library.selectedID = g.id } }

    // DM_NET's toggle (settings.tsv's Local play section): nil when the game has no local play
    var localPlayOn: Bool? {
        guard let s = m.settings.first(where: { $0.env == "DM_NET" }) else { return nil }
        return (m.values[s.env] ?? s.def) == s.onValue
    }

    var runningSelected: Bool { library.runningID != nil && library.runningID == library.selected.titleID }

    func lastPlayed(_ g: GameEntry) -> String {
        if g.titleID == library.runningID { return tr("Paused") }
        guard let d = g.lastPlayed else { return tr("Not played yet") }
        let f = RelativeDateTimeFormatter()
        if launcherChinese { f.locale = Locale(identifier: "zh-Hans") }
        return String(format: tr("Last played %@"), f.localizedString(for: d, relativeTo: Date()))
    }

    @ViewBuilder private func pageView(_ p: LauncherPage, size: CGSize, safe: EdgeInsets, portrait: Bool) -> some View {
        let back = { page = nil }
        switch p {
        case .importer: ImportDialog(library: library, close: back)
        case .details:
            let g = library.selected
            let remove: (() -> Void)? = g.pack == nil ? nil : { deleting = g }
            SettingsPage(title: g.name, size: size, safe: safe, portrait: portrait, back: back, side: { GameInfo(game: g, portrait: portrait) }) {
                if g.playable {
                    SettingsList(m: m, sections: m.sections, note: tr(g.titleID == library.runningID ? "Kept for this game only. Changes apply the next time the game starts." : "Kept for this game only."),
                                 reset: true, remove: g.titleID == library.runningID ? nil : remove, linked: g.pack?.linked ?? false)
                } else if g.pack != nil {
                    SettingsList(m: m, sections: [], note: tr("This pack did not pass its checks. Import it again for details."), remove: remove, linked: g.pack?.linked ?? false)
                } else {
                    SettingsList(m: m, sections: [], note: tr("This game's settings appear once its pack is imported."))
                }
            }
        case .localPlay:
            SettingsPage(title: tr("Local play"), size: size, safe: safe, portrait: portrait, back: back, side: { PageBadge(symbol: "person.2", title: tr("Local play"), note: tr("Runs the game's local wireless mode with devices on the same Wi-Fi network.")) }) {
                SettingsList(m: m, sections: m.sections.filter { $0 == "Local play" }, note: localPlayOn == nil ? tr("This game does not support local play.") : "")
            }
        case .controls:
            SettingsPage(title: tr("Button layout"), size: size, safe: safe, portrait: portrait, back: back, side: { PageBadge(symbol: "gamecontroller", title: tr("Button layout"), note: tr("To move, resize or hide touch controls, start the game and tap Edit to the right of +. In games started from NX Pocket, Home to the left of − pauses the game and returns here.")) }) {
                SettingsList(m: m, sections: m.sections.filter { $0 == "Controls" }, note: "")
            }
        case .settings:
            SettingsPage(title: tr("Settings"), size: size, safe: safe, portrait: portrait, back: back, side: { PageBadge(symbol: "gearshape", title: tr("Settings"), note: tr("Per-game options are in Game settings.")) }) {
                SettingsList(m: m, sections: [], note: "", app: true, certificate: PocketCertificate.importP12 == nil ? nil : { library.reload() }, about: library.canImport)
            }
        }
    }
}

// MARK: - Pieces shared by both orientations

/// The top bar: the app's wordmark on the left; local play, the time and the battery on the right, as on a console's home screen
private struct TopBar: View {
    var lightBehind = false   // the background behind it is light (Wordmark)
    let localPlayOn: Bool?
    let openLocalPlay: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Wordmark(light: lightBehind)   // level with the game's name below it
            Spacer()
            if let on = localPlayOn {
                Button(action: openLocalPlay) {
                    HStack(spacing: 7) {
                        Image(systemName: "wifi").font(.system(size: 11, weight: .semibold)).foregroundStyle(on ? Palette.accent : Color.white.opacity(0.45))
                        Text(tr(on ? "Local play on" : "Local play off")).font(.system(size: 12, weight: .medium))
                    }
                    .padding(.horizontal, 12).frame(height: 28).contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)
            }
            StatusClock()
        }
        .frame(height: 32)
    }
}

/// Whether the top of the home screen's background is light: the game icon's top rows, as the backdrop dims them (its shade is 62 % black at the top)
private enum BackdropTone {
    private static var cache: [String: Bool] = [:]
    static func light(_ g: GameEntry) -> Bool {
        if let v = cache[g.titleID] { return v }
        var v = false
        if let cg = g.icon?.cgImage, let ctx = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 4, height: 4))
            if let d = ctx.data?.assumingMemoryBound(to: UInt8.self) {
                var sum = 0.0
                for x in 0..<4 { let p = d + (3 * 16) + x * 4; sum += 0.2126 * Double(p[0]) + 0.7152 * Double(p[1]) + 0.0722 * Double(p[2]) }   // the top row (CG's rows run bottom up)
                v = sum / 4 / 255 * 0.38 > 0.5
            }
        }
        cache[g.titleID] = v
        return v
    }
}

/// The time and the battery, refreshed every 30 s
private struct StatusClock: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            HStack(spacing: 10) {
                Text(ctx.date, format: .dateTime.hour().minute()).font(.system(size: 15, weight: .semibold).monospacedDigit())
                battery
            }
        }
        .onAppear { UIDevice.current.isBatteryMonitoringEnabled = true }
        .accessibilityElement(children: .combine)
    }
    private var battery: some View {
        let level = UIDevice.current.batteryLevel, charging = UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full
        let pct = level < 0 ? nil : Int((level * 100).rounded())
        let symbol = charging ? "battery.100percent.bolt" : pct.map { $0 > 87 ? "battery.100percent" : $0 > 62 ? "battery.75percent" : $0 > 37 ? "battery.50percent" : $0 > 12 ? "battery.25percent" : "battery.0percent" } ?? "battery.100percent"
        return HStack(spacing: 4) {
            if let pct { Text("\(pct)%").font(.system(size: 12, weight: .medium).monospacedDigit()).foregroundStyle(Palette.soft) }
            Image(systemName: symbol).font(.system(size: 16)).foregroundStyle(pct.map { $0 <= 15 && !charging } == true ? Palette.danger : .white)
        }
    }
}

/// Play (Resume for the game paused under the home screen): the screen's one white button (PrimaryButton, PocketStyle.swift)
private struct PlayButton: View {
    let enabled: Bool
    var resume = false
    var height: CGFloat = 48
    var wide = false
    let action: () -> Void

    var body: some View {
        PrimaryButton(title: tr(resume ? "Resume" : "Play"), symbol: "play.fill", height: height, wide: wide, enabled: enabled, action: action)
    }
}

/// One game's icon; the selected one is larger (landscape) or scaled up (portrait), with a white ring and a shadow
private struct GameTile: View {
    let game: GameEntry
    let selected: Bool
    var focus: CGFloat? = nil   // the ring and shadow's strength (CoverArt), when it changes as the row scrolls
    let side: CGFloat
    var paused = false   // the game under the home screen
    var trash = false                    // held down: the trash button shows on it
    var hold: (() -> Void)? = nil        // what holding it does (nil: nothing to delete)
    var delete: () -> Void = {}
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            CoverArt(image: game.icon, name: game.name, side: side, selected: selected, focus: focus)
            .overlay(alignment: .topLeading) {
                if paused {
                    HStack(spacing: 4) { Image(systemName: "pause.fill").font(.system(size: 9, weight: .bold)); Text(tr("Paused")).font(.system(size: 11, weight: .semibold)) }
                        .padding(.horizontal, 8).frame(height: 22)
                        .background(Color.black.opacity(0.6), in: Capsule())
                        .padding(side * 0.06)
                }
            }
        }
        .buttonStyle(PressStyle(scale: 0.97))
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in
            guard let hold else { return }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred(); hold()
        })
        .overlay {
            if trash {
                Button(action: delete) {
                    Image(systemName: "trash.fill").font(.system(size: max(side * 0.13, 18), weight: .semibold)).foregroundStyle(.white)
                        .frame(width: max(side * 0.3, 52), height: max(side * 0.3, 52))
                        .background(Circle().fill(Palette.danger.opacity(0.92)))
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.35), lineWidth: 1.5))
                        .shadow(color: .black.opacity(0.45), radius: 14, y: 6)
                }
                .buttonStyle(PressStyle(scale: 0.88))
                .transition(.scale(scale: 0.4).combined(with: .opacity))
                .accessibilityLabel("\(tr("Delete Game Pack")) · \(game.name)")
            }
        }
        .accessibilityLabel(game.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct ImportTile: View {
    let side: CGFloat
    let action: () -> Void
    var body: some View { DashedTile(side: side, symbol: "plus", title: tr("Import game pack"), action: action) }
}

/// The row under the games, after the Switch's home screen: round buttons alike, white symbols on Liquid Glass, their names under them. Local play shows whether it is
/// on (a dot), and is dimmed and inactive for a game without it
private struct Shortcuts: View {
    let home: LauncherHome
    var circle: CGFloat = 52

    var body: some View {
        let lp = home.localPlayOn
        GlassEffectContainer(spacing: circle) {
            HStack(alignment: .top, spacing: circle * 0.7) {
                RoundButton(symbol: "square.and.arrow.down", title: tr("Import"), size: circle, showTitle: true) { home.open(.importer) }
                RoundButton(symbol: "person.2.wave.2", title: tr(lp == nil ? "No local play" : "Local play"), size: circle, showTitle: true, dot: lp, enabled: lp != nil) { home.open(.localPlay) }
                RoundButton(symbol: "gamecontroller", title: tr("Button layout"), size: circle, showTitle: true) { home.open(.controls) }
                RoundButton(symbol: "gearshape", title: tr("Settings"), size: circle, showTitle: true) { home.open(.settings) }
            }
        }
    }
}

// MARK: - Landscape: one column, the games in a sideways row

private struct LandscapeHome: View {
    let home: LauncherHome
    let size: CGSize
    let safe: EdgeInsets

    var body: some View {
        let library = home.library, game = library.selected
        let notch: CGFloat = max(safe.leading, safe.trailing)
        let side: CGFloat = notch > 0 ? notch + 8 : 32
        let bottom: CGFloat = safe.bottom > 0 ? safe.bottom + 4 : 14
        // The row takes the height the other rows leave (390 pt: a 176 pt selected tile and 140 pt ones), up to a 276 pt selected tile on a taller screen
        let rest: CGFloat = size.height - 16 - bottom - 32 - 48 - 76 - 24
        let row: CGFloat = min(max(rest, 120), 300)
        let big: CGFloat = (row - 24).rounded()
        let small: CGFloat = (big / 1.257).rounded()
        VStack(alignment: .leading, spacing: 8) {
            TopBar(lightBehind: BackdropTone.light(home.library.selected), localPlayOn: home.localPlayOn) { home.open(.localPlay) }
            HStack {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(game.name).font(.system(size: 24, weight: .bold)).lineLimit(1).shadow(color: .black.opacity(0.4), radius: 6, y: 2)
                    Text(home.lastPlayed(game)).font(.system(size: 12)).foregroundStyle(Palette.soft).lineLimit(1)
                }
                .layoutPriority(-1)
                Spacer(minLength: 12)
                GlassEffectContainer(spacing: 14) {
                    HStack(spacing: 12) {
                        if home.runningSelected, let close = home.close { RoundButton(symbol: "xmark", title: tr("Close"), size: 46, action: close) }
                        RoundButton(symbol: "ellipsis", title: tr("Game settings"), size: 46) { home.open(.details) }
                        PlayButton(enabled: game.playable || home.runningSelected, resume: home.runningSelected, height: 46, action: home.play)
                    }
                }
            }
            .frame(height: 48)
            Spacer(minLength: 0)
            GameRow(home: home, library: library, row: row, big: big, small: small, side: side, width: size.width)
            Spacer(minLength: 0)
            Shortcuts(home: home).frame(maxWidth: .infinity)
        }
        .padding(.leading, side).padding(.trailing, side).padding(.top, 16 + safe.top).padding(.bottom, bottom)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }
}

/// The games in a sideways row that scrolls with momentum: a fling carries on, slows and settles with a game at the start of the row, as a console's home row does.
/// Every tile takes the same place in the row; how large it shows follows where it is as the row moves: full size at the start of the row, shrinking as it leaves, and
/// the tiles after it moved along to make room, so a game grows as it comes to the start and nothing jumps when the row settles. The game it settles on is selected
/// (the name and the background follow); each game passing the start ticks like a dial. A tap selects a game and brings it there. When all the tiles fit on the
/// screen the row does not scroll: the selection moves to the tapped game, which grows where it is
private struct GameRow: View {
    let home: LauncherHome
    @ObservedObject var library: GameLibrary
    let row, big, small, side, width: CGFloat
    @State private var position = ScrollPosition(idType: String.self)   // the tile at the start of the row
    @State private var scrolled: CGFloat = 0                              // how far the row has moved (points; 0: the first tile at the start)
    @State private var lastAtStart: String?
    private let tick = UISelectionFeedbackGenerator()
    private let gap: CGFloat = 18

    var body: some View {
        let slot = small + gap, extra = big - small
        let fits = 2 * side + CGFloat(library.games.count + 1) * slot - gap + extra <= width   // the games and Import, one of them large
        let selected = CGFloat(library.games.firstIndex { $0.id == library.selectedID } ?? 0)
        let at = fits ? selected : scrolled / slot   // where the start of the row is, in tiles
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .center, spacing: gap) {
                ForEach(Array(library.games.enumerated()), id: \.element.id) { i, g in
                    let near = max(0, 1 - abs(CGFloat(i) - at))   // 1 at the start of the row, 0 a tile away
                    GameTile(game: g, selected: g.id == library.selectedID, focus: near, side: big, paused: g.id == library.runningID,
                             trash: home.trashShown == g.id, hold: home.holdTile(g), delete: { home.deleteNow(g) }) { home.tapTile(g) }
                        .modifier(Place(index: CGFloat(i), at: at, near: near, small: small, big: big))
                        .zIndex(near)
                        .id(g.id)
                }
                ImportTile(side: small)  { home.open(.importer) }
                    .offset(x: extra * min(max(CGFloat(library.games.count) - at, 0), 1))
                    .id("import")
            }
            .scrollTargetLayout()
            .frame(height: row)
            .background(Color.white.opacity(0.001).onTapGesture { home.dismissTrash() })   // a tap beside the tiles puts the trash away
            .animation(pick, value: library.selectedID)
        }
        .contentMargins(.leading, side, for: .scrollContent)
        // The row ends with the last game at the start, Import beside it: a fling always settles on a game, and neither end leaves the screen
        .contentMargins(.trailing, fits ? side : max(width - side - slot - small, side), for: .scrollContent)
        .scrollTargetBehavior(.viewAligned(limitBehavior: .never))   // momentum across several games, then it settles on one
        .scrollPosition($position, anchor: .leading)
        .scrollDisabled(fits)
        .padding(.horizontal, -side)   // the row runs to the screen's edges; its content starts level with the name above
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.x + $0.contentInsets.leading } action: { _, x in scrolled = x }
        .onChange(of: position) { _, p in
            let id = p.viewID(type: String.self)
            if let id, id != lastAtStart { lastAtStart = id; tick.selectionChanged() }
        }
        .onScrollPhaseChange { _, phase in
            guard phase == .idle, let id = position.viewID(type: String.self), id != library.selectedID, library.games.contains(where: { $0.id == id }) else { return }
            withAnimation(pick) { library.selectedID = id }
        }
        .onChange(of: library.selectedID) { _, id in if !fits { withAnimation(pick) { position.scrollTo(id: id, anchor: .leading) } } }
        .onAppear { if !fits { position.scrollTo(id: library.selectedID, anchor: .leading) }; lastAtStart = library.selectedID; tick.prepare() }
    }
}

/// A game tile's place in the row: drawn at the large size and scaled to what its distance from the start of the row gives, growing from its leading edge, and moved
/// along by what the tiles before it have grown (only the one at or just before the start is larger than small)
private struct Place: ViewModifier {
    let index, at, near, small, big: CGFloat
    func body(content: Content) -> some View {
        let shown = small + (big - small) * near
        content
            .scaleEffect(shown / big)
            .frame(width: small, height: small)
            .offset(x: (shown - small) / 2 + (big - small) * min(max(index - at, 0), 1))
    }
}

// MARK: - Portrait (the iPhone Duo's inner screen): the selected game above the fold, the games and the shortcuts below it

private struct PortraitHome: View {
    let home: LauncherHome
    let layout: hf_layout
    let safe: EdgeInsets

    var body: some View {
        let top = rect(layout.picture), bottom = rect(layout.controls)
        ZStack(alignment: .topLeading) {
            upper(top).frame(width: top.width, height: top.height).offset(x: top.minX, y: top.minY)
            lower(bottom).frame(width: bottom.width, height: bottom.height).offset(x: bottom.minX, y: bottom.minY)
        }
    }

    private func rect(_ r: hf_rect) -> CGRect { CGRect(x: r.x, y: r.y, width: r.w, height: r.h) }

    // Above the fold: the top bar, then the selected game's icon beside its name, last-played time, Play and Game settings. 16 pt clear of the fold
    private func upper(_ r: CGRect) -> some View {
        let game = home.library.selected
        let padTop = 20 + safe.top, side: CGFloat = 32
        let cover = max(min(300, (r.width - 2 * side) * 0.5, r.height - padTop - 16 - 36 - 24), 96)
        return VStack(alignment: .leading, spacing: 24) {
            TopBar(lightBehind: BackdropTone.light(home.library.selected), localPlayOn: home.localPlayOn) { home.open(.localPlay) }
            HStack(spacing: 28) {
                Group {
                    if let icon = game.icon { Image(uiImage: icon).resizable().scaledToFill() } else { Color.white.opacity(0.1) }
                }
                .frame(width: cover, height: cover)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .shadow(color: .black.opacity(0.5), radius: 35, y: 28)
                .id(game.id).transition(.opacity)
                .accessibilityLabel(game.name)
                VStack(alignment: .leading, spacing: 14) {
                    Text(game.name).font(.system(size: 28, weight: .bold)).lineLimit(3).minimumScaleFactor(0.7).shadow(color: .black.opacity(0.4), radius: 8, y: 2)
                    Text(home.lastPlayed(game)).font(.system(size: 13)).foregroundStyle(Palette.soft)
                    PlayButton(enabled: game.playable || home.runningSelected, resume: home.runningSelected, height: 56, wide: true, action: home.play)
                    GlassEffectContainer(spacing: 22) {
                        HStack(spacing: 22) {
                            RoundButton(symbol: "ellipsis", title: tr("Game settings"), size: 46, showTitle: true) { home.open(.details) }
                            if home.runningSelected, let close = home.close { RoundButton(symbol: "xmark", title: tr("Close"), size: 46, showTitle: true, action: close) }
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
        .padding(.horizontal, side).padding(.top, padTop).padding(.bottom, 16)
    }

    // Below the fold: My games as a grid (selected 1.1×, the rest 0.9×), Import game pack last, the shortcuts at the bottom. 20 pt clear of the fold
    private func lower(_ r: CGRect) -> some View {
        let library = home.library
        let side: CGFloat = 32, gap: CGFloat = 16
        let columns = max(3, Int((r.width - 2 * side + gap) / (130 + gap)))
        // As wide as the columns allow, but no taller than lets two rows (the games and Import game pack) fit between the heading and the shortcuts
        let byWidth: CGFloat = (r.width - 2 * side - 8 - gap * CGFloat(columns - 1)) / CGFloat(columns)
        let rows: CGFloat = CGFloat((library.games.count + 1 + columns - 1) / columns)
        let room: CGFloat = r.height - 20 - 20 - safe.bottom - 18 - 14 - 14 - 80 - 24
        let byHeight: CGFloat = (room - gap * (min(rows, 2) - 1)) / min(rows, 2)
        let tile = max(min(byWidth, byHeight), 72).rounded(.down)
        return VStack(alignment: .leading, spacing: 14) {
            Text(tr("My games")).font(.system(size: 14, weight: .medium)).foregroundStyle(Palette.label)
            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(tile), spacing: gap), count: columns), alignment: .center, spacing: gap) {
                    ForEach(library.games) { g in
                        let on = g.id == library.selectedID
                        GameTile(game: g, selected: on, side: tile, paused: g.id == library.runningID,
                                 trash: home.trashShown == g.id, hold: home.holdTile(g), delete: { home.deleteNow(g) }) { home.tapTile(g) }
                            .scaleEffect(on ? 1.1 : 0.9).zIndex(on ? 1 : 0)
                    }
                    ImportTile(side: tile) { home.open(.importer) }.scaleEffect(0.9)
                }
                .frame(maxWidth: .infinity)
                .padding(12)
                .background(Color.white.opacity(0.001).onTapGesture { home.dismissTrash() })
                .animation(pick, value: library.selectedID)
            }
            .padding(.horizontal, -10)
            Shortcuts(home: home, circle: 54).frame(maxWidth: .infinity)
        }
        .padding(.horizontal, side).padding(.top, 20).padding(.bottom, 20 + safe.bottom)
    }
}

// MARK: - Pages

/// A page over the blurred background: Back and a side column (the game, or what the page is for) beside the settings in landscape, above them in portrait
private struct SettingsPage<Side: View, Content: View>: View {
    let title: String
    let size: CGSize
    let safe: EdgeInsets
    let portrait: Bool
    let back: () -> Void
    @ViewBuilder let side: () -> Side
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(red: 6 / 255, green: 7 / 255, blue: 10 / 255).opacity(0.5).ignoresSafeArea()
            let pad = EdgeInsets(top: 20 + safe.top, leading: max(32, safe.leading + 8), bottom: max(12, safe.bottom), trailing: max(32, safe.trailing + 8))
            if portrait {
                VStack(alignment: .leading, spacing: 12) {
                    backButton
                    side()
                    content()
                }
                .padding(pad)
            } else {
                HStack(alignment: .top, spacing: 28) {
                    VStack(alignment: .leading, spacing: 12) {
                        backButton
                        side()
                        Spacer(minLength: 0)
                    }
                    .frame(width: min(236, size.width * 0.3), alignment: .leading)
                    content()
                }
                .padding(pad)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    private var backButton: some View {
        Button(action: back) {
            HStack(spacing: 4) { Image(systemName: "chevron.left").font(.system(size: 15, weight: .semibold)); Text(tr("Back")).font(.system(size: 15)) }
                .frame(height: 32)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(tr("Back")) · \(title)")
    }
}

private struct GameInfo: View {
    let game: GameEntry
    let portrait: Bool

    var body: some View {
        let layout = portrait ? AnyLayout(HStackLayout(alignment: .center, spacing: 16)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
        layout {
            Group {
                if let icon = game.icon { Image(uiImage: icon).resizable().scaledToFill() } else { Color.white.opacity(0.1) }
            }
            .frame(width: portrait ? 96 : 168, height: portrait ? 96 : 168)
            .clipShape(RoundedRectangle(cornerRadius: portrait ? 14 : 16, style: .continuous))
            .shadow(color: .black.opacity(0.45), radius: 22, y: 18)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(game.name).font(.system(size: 20, weight: .bold)).lineLimit(2)
                VStack(alignment: .leading, spacing: 4) {
                    if !game.version.isEmpty { Text("\(tr("Version")) \(game.version)") }
                    Text("\(tr("Title ID")) \(game.titleID)").textSelection(.enabled)
                }
                .font(.system(size: 12)).foregroundStyle(Palette.soft)
            }
        }
    }
}

private struct PageBadge: View {
    let symbol: String
    let title: String
    let note: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Circle().fill(Palette.chip).frame(width: 56, height: 56).overlay(Image(systemName: symbol).font(.system(size: 24)))
            Text(title).font(.system(size: 20, weight: .bold))
            Text(note).font(.system(size: 13)).foregroundStyle(Palette.soft).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The settings rows of some sections on a frosted panel (Game settings, Local play, Button layout), or the app's own rows (app: cloud saves and memory; Settings)
struct SettingsList: View {
    @ObservedObject var m: LauncherModel
    let sections: [String]
    let note: String
    var reset = false
    var app = false
    var remove: (() -> Void)? = nil   // a pack in NX Pocket: Delete Game Pack (asks first)
    var linked = false                // used in place: removing forgets the link, the pack stays
    var certificate: (() -> Void)? = nil   // NX Pocket's Settings: its developer certificate (called after a change: the packs' checks change with it)
    var about = false                       // NX Pocket's Settings: About NX Pocket, last

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !note.isEmpty { Text(note).font(.system(size: 13)).foregroundStyle(Palette.soft) }
            if !sections.isEmpty || app || remove != nil {
                List {
                    ForEach(sections, id: \.self) { section in
                        let rows = m.rows(in: section)
                        if !rows.isEmpty {
                            Section {
                                ForEach(rows) { SettingRow(s: $0, m: m).listRowBackground(Palette.panel) }
                            } header: {
                                Text(tr(section))
                            } footer: {
                                if section == "Local play" {   // the address the other devices type in
                                    Text("\(tr("This device's address")): \(wifiAddress() ?? tr("No Wi-Fi address"))").textSelection(.enabled)
                                }
                            }
                        }
                    }
                    if reset {
                        Section {
                            Button(tr("Reset to tested defaults")) { m.reset() }.disabled(!m.changed).listRowBackground(Palette.panel)
                        } footer: {
                            Text(tr("Restores the settings this game was tested with."))
                        }
                    }
                    if let remove {
                        Section {
                            Button(tr("Delete Game Pack"), role: .destructive, action: remove).foregroundStyle(Palette.danger).listRowBackground(Palette.panel)
                        } footer: {
                            Text(tr(linked ? "Removes the link only; the pack stays in its location. Saves and settings are kept." : "Deletes the copy stored in NX Pocket. Saves and settings are kept."))
                        }
                    }
                    if let certificate { CertificateSection(changed: certificate) }
                    if about { LanguageSection().listRowBackground(Palette.panel) }
                    if app {
                        CloudSavesSection().listRowBackground(Palette.panel)
                        MemorySection().listRowBackground(Palette.panel)
                    }
                    if about { AboutSection().listRowBackground(Palette.panel) }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .contentMargins(.horizontal, 12, for: .scrollContent)
                .tint(Palette.accent)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.ultraThinMaterial).opacity(0.35))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
    }
}

/// Settings › Language: the system's, Simplified Chinese or English. The home screen and its pages draw again in it at once (LauncherHome's .id); a game started
/// afterwards uses it too (DM_UI_LANG), and the system's own words (permission prompts) follow from the next launch
private struct LanguageSection: View {
    @AppStorage(AppLanguage.key) private var language = ""
    var body: some View {
        Section {
            Picker(tr("Language"), selection: Binding(get: { language }, set: { AppLanguage.choose($0); language = $0 })) {
                Text(tr("System")).tag("")
                Text("简体中文").tag("zh-Hans")
                Text("English").tag("en")
            }
        } footer: { Text(tr("System alerts follow the next time NX Pocket starts.")) }
    }
}

/// About NX Pocket (Settings): its version, what it is built on, and that it has nothing to do with Nintendo and brings no games or keys
private struct AboutSection: View {
    var body: some View {
        Section {
            HStack { Text(tr("Version")); Spacer(); Text(About.version).monospacedDigit().foregroundStyle(.secondary) }
            Text(About.basedOn).font(.system(size: 13)).foregroundStyle(.secondary)
            Text(About.disclaimer).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } header: { Text(tr("About NX Pocket")) }
    }
}

/// NX Pocket's developer certificate: which one it holds and until when, Import (a .p12 picked in Files, then its password) and Remove. NX Pocket signs a pack's library
/// with it on the phone (PackSigner.swift); it must be the certificate NX Pocket itself is signed with
private struct CertificateSection: View {
    let changed: () -> Void
    @State private var info = PocketCertificate.current?()
    @State private var picking = false
    @State private var picked: Data?
    @State private var asking = false
    @State private var password = ""
    @State private var message = ""

    var body: some View {
        Section {
            HStack {
                Text(tr("Developer certificate"))
                Spacer()
                Text(info.map { $0.name.replacingOccurrences(of: "Apple Development: ", with: "") } ?? tr("None")).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            .listRowBackground(Palette.panel)
            if let info {
                HStack {
                    Text(tr("Team")); Spacer(); Text(info.team).foregroundStyle(.secondary)
                }
                .listRowBackground(Palette.panel)
                HStack {
                    Text(tr("Expires")); Spacer()
                    Text(expiry(info.expires)).foregroundStyle(info.expires.timeIntervalSinceNow < 7 * 86400 ? Palette.danger : .secondary)
                }
                .listRowBackground(Palette.panel)
            }
            Button(tr(info == nil ? "Import certificate (.p12)…" : "Replace certificate…")) { picking = true }.listRowBackground(Palette.panel)
            if info != nil {
                Button(tr("Remove certificate"), role: .destructive) { PocketCertificate.remove?(); info = nil; message = ""; changed() }
                    .foregroundStyle(Palette.danger).listRowBackground(Palette.panel)
            }
        } header: {
            Text(tr("Signing"))
        } footer: {
            Text(message.isEmpty ? tr("Used to sign game packs on this device. It must be the certificate NX Pocket is signed with, exported as a .p12 with its private key, and is stored in this device's Keychain.") : message)
        }
        .sheet(isPresented: $picking) {
            DocumentPicker(types: [.pkcs12]) { url in
                picking = false
                let ok = url.startAccessingSecurityScopedResource(); defer { if ok { url.stopAccessingSecurityScopedResource() } }
                picked = try? Data(contentsOf: url)
                if picked == nil { message = tr("The file could not be read.") } else { password = ""; asking = true }
            } onCancel: { picking = false }
        }
        .alert(tr("Certificate password"), isPresented: $asking) {
            SecureField(tr("Password"), text: $password)
            Button(tr("Cancel"), role: .cancel) { picked = nil }
            Button(tr("Import")) {
                guard let data = picked, let imp = PocketCertificate.importP12 else { return }
                do { info = try imp(data, password); message = tr("Certificate imported. Game packs are signed on this device when they start."); changed() }
                catch { message = error.localizedDescription }
                picked = nil; password = ""
            }
        } message: {
            Text(tr("Enter the password set when the .p12 was exported. Leave it empty if none was set."))
        }
    }

    private func expiry(_ d: Date) -> String {
        let days = Int(ceil(d.timeIntervalSinceNow / 86400))
        if days <= 0 { return tr("Expired") }
        return String(format: tr("in %d days (%@)"), days, d.formatted(date: .abbreviated, time: .omitted))
    }
}

/// Import game pack. In NX Pocket: pick a pack folder (<name>.nxpack, build_pack.py) in Files, see its checks (format and files, the team that signed its library, its shader
/// libraries), then copy it into NX Pocket or use it where it is (a pack on a drive or in another folder: no copy, a bookmark). In a game's own app: where packs are played
struct ImportDialog: View {
    @ObservedObject var library: GameLibrary
    let close: () -> Void
    @State private var picking = false
    @State private var picked: URL?
    @State private var info: PackInfo?
    @State private var checks: PackInfo.Checks?
    @State private var busy: String?     // the import in progress
    @State private var copying: GameLibrary.CopyProgress?   // a copy in progress: its progress bar and Cancel
    @State private var failure: String?
    @State private var cloud = false     // the chosen pack is in iCloud Drive and not all on this device yet
    @State private var quickOnly = false // a single-file pack without every chunk's checksum: only the quick check can be made
    @State private var notice: String?   // after an import: what the player should know (the quick check only)

    var body: some View {
        ZStack {
            Color(red: 6 / 255, green: 7 / 255, blue: 10 / 255).opacity(0.72).ignoresSafeArea().onTapGesture { if busy == nil { close() } }
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .center, spacing: 14) {
                    Image(systemName: "shippingbox.fill").font(.system(size: 22)).foregroundStyle(Palette.accent).frame(width: 46, height: 46)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.accent.opacity(0.14)))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(tr("Import Game Pack")).font(.system(size: 19, weight: .bold))
                        Text(subtitle).font(.system(size: 13)).foregroundStyle(Palette.soft).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let info {   // the chosen pack
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(info.name).font(.system(size: 15, weight: .semibold))
                            Text("\(tr("Version")) \(info.version) · \(info.titleID)").font(.system(size: 12).monospacedDigit()).foregroundStyle(Palette.soft)
                        }
                        Spacer()
                    }
                    .padding(12).background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.06)))
                }
                if library.canImport {
                    VStack(alignment: .leading, spacing: 12) {
                        check("doc.zipper", tr("Package format and game data"), checks.map { $0.files })
                        check("signature", tr("Code signature"), checks.map { $0.signature })
                        check("cube.transparent", tr("Shader libraries"), checks.map { $0.shaders })
                    }
                }
                if let busy {
                    if let copying {
                        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                            VStack(alignment: .leading, spacing: 6) {
                                ProgressView(value: copying.fraction).tint(Palette.accent)
                                HStack {
                                    Text(copying.stage ?? busy).font(.system(size: 13)).foregroundStyle(Palette.soft)
                                    Spacer()
                                    // bytes for a copy or a check; a share alone for unpacking (its total is not bytes)
                                    Text(copying.total <= 1000 ? "\(Int(copying.fraction * 100))%" : "\(Int(copying.fraction * 100))% · \(ByteCountFormatter.string(fromByteCount: copying.done, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: copying.total, countStyle: .file))")
                                        .font(.system(size: 12).monospacedDigit()).foregroundStyle(Palette.soft)
                                }
                            }
                        }
                    } else {
                        HStack(spacing: 10) { ProgressView().tint(.white); Text(busy).font(.system(size: 13)).foregroundStyle(Palette.soft) }
                    }
                }
                if cloud, busy == nil {
                    Label(tr("Part of this pack is still in iCloud Drive. Used in place, it downloads in the background; the game can start once it is on this device."), systemImage: "icloud.and.arrow.down")
                        .font(.system(size: 12)).foregroundStyle(Palette.soft).fixedSize(horizontal: false, vertical: true)
                }
                if let failure { Label(failure, systemImage: "exclamationmark.triangle.fill").font(.system(size: 13)).foregroundStyle(Palette.danger).fixedSize(horizontal: false, vertical: true) }
                if let notice { Label(notice, systemImage: "checkmark.shield").font(.system(size: 13)).foregroundStyle(Palette.soft).fixedSize(horizontal: false, vertical: true) }
                if library.canImport, busy == nil, picked != nil, checks?.passed == true {
                    Text(tr("Use in place keeps the pack where it is, which must stay available. Copying stores a second copy on this device.")).font(.system(size: 12)).foregroundStyle(Palette.soft)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 10) {
                    Spacer()
                    if notice != nil {
                        primary(tr("OK"), action: close)
                    } else if let copying, busy != nil {
                        secondary(tr("Cancel")) { copying.cancel() }
                    } else if library.canImport, busy == nil {
                        if let picked, checks?.passed == true {
                            secondary(tr("Copy to NX Pocket")) { run(picked, mode: .copy) }
                            primary(tr("Use in Place")) { run(picked, mode: .link) }
                        } else {
                            secondary(tr("Cancel"), action: close)
                            primary(tr(picked == nil ? "Select Pack" : "Select Another")) { picking = true }
                        }
                    } else if busy == nil {
                        primary(tr("OK"), action: close)
                    }
                }
            }
            .padding(.horizontal, 24).padding(.vertical, 22)
            .frame(maxWidth: 500)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Color(red: 20 / 255, green: 22 / 255, blue: 28 / 255).opacity(0.7)))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Color.white.opacity(0.12)))
            .shadow(color: .black.opacity(0.5), radius: 40, y: 30)
            .padding(24)
            .accessibilityAddTraits(.isModal)
        }
        .sheet(isPresented: $picking) {
            DocumentPicker(types: [.nxpack, .folder]) { url in picking = false; inspect(url) } onCancel: { picking = false }
        }
        .onAppear { if let u = library.opening { library.opening = nil; inspect(u) } }   // a pack opened from the Files app or AirDrop (PocketApp.swift)
        .onChange(of: library.opening) { _, u in if let u, busy == nil { library.opening = nil; inspect(u) } }
    }

    private var subtitle: String {
        guard library.canImport else { return tr("This app contains a single game. Import game packs in NX Pocket.") }
        return tr("Select a game pack (.nxpack) in Files. NX Pocket checks it before adding it to your library.")
    }

    private func primary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 14, weight: .bold)).foregroundStyle(Palette.ink)
                .padding(.horizontal, 22).frame(height: 40).background(Capsule().fill(.white))
        }
        .buttonStyle(PressStyle())
    }
    private func secondary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 14, weight: .medium))
                .padding(.horizontal, 18).frame(height: 40)
                .background(Capsule().fill(Color.white.opacity(0.12))).overlay(Capsule().strokeBorder(Color.white.opacity(0.16)))
        }
        .buttonStyle(PressStyle())
    }

    private func inspect(_ url: URL) {
        let ok = url.startAccessingSecurityScopedResource(); defer { if ok { url.stopAccessingSecurityScopedResource() } }
        let (i, c) = PackInfo.load(url)
        picked = url; info = i; checks = c; failure = nil; notice = nil
        quickOnly = PackFile.isFile(url) && (try? PackFile(url))?.fullyHashed == false
        cloud = c.passed && GameLibrary.waitingForICloud(url)
        fputs("pocket: picked \(url.path): \(c.passed ? "checks passed" : "checks failed")\n", stderr)
        // Already in NX Pocket's own Documents (the Finder, the Files app): nothing to choose and nothing to copy, it joins the library as it is
        if c.passed, GameLibrary.location(url) != .elsewhere { run(url, mode: .inside) }
    }

    private func run(_ url: URL, mode: GameLibrary.ImportMode) {
        let job = mode == .copy || info?.format ?? 0 >= 3 ? GameLibrary.CopyProgress() : nil   // a single-file pack is checked and unpacked, with its progress, whatever the mode
        busy = mode == .copy ? String(format: tr("Copying %@…"), info?.name ?? url.lastPathComponent) : tr("Adding to library…")
        copying = job; failure = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try GameLibrary.importPack(url, mode: mode, progress: job) }
            DispatchQueue.main.async {
                busy = nil; copying = nil
                switch result {
                case .success(let id):
                    library.reload(); library.selectedID = id
                    if quickOnly { notice = tr("Added after a quick check only: this pack does not carry checksums for all of its game data. If the game misbehaves, make the pack again with Full Check on and send it again.") }
                    else { close() }
                case .failure(let e): failure = e.localizedDescription
                }
            }
        }
    }

    // One check: its symbol and name, then pending (a dashed circle) before a pack is chosen, passed or failed (with the reason) after
    private func check(_ symbol: String, _ s: String, _ problem: String??) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 14)).foregroundStyle(Palette.soft).frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(s).font(.system(size: 14, weight: .medium))
                if case .some(.some(let why)) = problem { Text(why).font(.system(size: 12)).foregroundStyle(Palette.soft).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 8)
            switch problem {
            case .none: Image(systemName: "circle.dashed").foregroundStyle(Color.white.opacity(0.35))
            case .some(.none): Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.accent)
            case .some(.some): Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.danger)
            }
        }
        .font(.system(size: 17))
    }
}

/// What the busy note shows: the line under the bar, and how far the work is (nil: a spinner)
final class BusyState: ObservableObject {
    @Published var text: String
    @Published var fraction: Double?
    init(text: String, fraction: Double?) { self.text = text; self.fraction = fraction }
}

/// NX Pocket's note while a game's pack is being prepared or signed (PocketApp.swift play): its icon and name in a glass card like the home screen's controls, over the home screen dimmed,
/// so the row of games under it does not read as one of them chosen
struct BusyNote: View {
    let game: GameEntry
    @ObservedObject var state: BusyState

    /// Puts the note over `window`: a bar (`measured`: the work reports how far it is) or a spinner. Its state changes on the main thread
    static func show(in window: UIWindow, game: GameEntry, _ text: String, measured: Bool = false) -> (view: UIView, state: BusyState) {
        let state = BusyState(text: text, fraction: measured ? 0 : nil)
        let host = UIHostingController(rootView: BusyNote(game: game, state: state))
        host.view.frame = window.bounds; host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]; host.view.backgroundColor = .clear
        window.addSubview(host.view)
        return (host.view, state)
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.62).ignoresSafeArea()
            VStack(spacing: 16) {
                CoverArt(image: game.icon, name: game.name, side: 72)
                if let f = state.fraction {
                    VStack(spacing: 6) {
                        ProgressView(value: f).tint(Palette.accent)
                        Text("\(Int((f * 100).rounded(.down)))%").font(.system(size: 13, weight: .semibold).monospacedDigit()).foregroundStyle(Palette.soft)
                    }
                } else {
                    ProgressView().controlSize(.large).tint(.white)
                }
                Text(state.text).font(.system(size: 15, weight: .medium)).foregroundStyle(.white).multilineTextAlignment(.center)
                    .lineLimit(2).minimumScaleFactor(0.85).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 28).padding(.vertical, 26)
            .frame(width: 340)
            .glassEffect(.regular.tint(.black.opacity(0.45)), in: RoundedRectangle(cornerRadius: 28, style: .continuous))   // dark enough that the tiles under it do not show through
            .animation(.easeOut(duration: 0.2), value: state.fraction)
        }
        .preferredColorScheme(.dark)
    }
}
