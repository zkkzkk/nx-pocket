// NX Pocket's look, shared by the iPhone's home screen (LauncherHome.swift) and NX Pocket for Mac (dm/mac/pocket): the palette, the selected game's cover blurred
// as the background, the wordmark, Liquid Glass buttons (round ones with a white symbol, and the one white primary button), a game's cover and the dashed tile that
// adds one. Dark, accent #4FD1C5, the system font (SF Pro Rounded for the wordmark).
import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
#if canImport(UIKit)
import UIKit
typealias PlatformImage = UIImage
extension Image { init(platformImage i: PlatformImage) { self.init(uiImage: i) } }
extension PlatformImage { convenience init(cg: CGImage) { self.init(cgImage: cg) }; var cg: CGImage? { cgImage } }
#else
import AppKit
typealias PlatformImage = NSImage
extension Image { init(platformImage i: PlatformImage) { self.init(nsImage: i) } }
extension PlatformImage {
    convenience init(cg: CGImage) { self.init(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)) }
    var cg: CGImage? { cgImage(forProposedRect: nil, context: nil, hints: nil) }
}
#endif


enum Palette {
    static let ground = Color(red: 0x0B / 255, green: 0x0C / 255, blue: 0x0F / 255)
    static let accent = Color(red: 0x4F / 255, green: 0xD1 / 255, blue: 0xC5 / 255)
    static let ink = Color(red: 0x11 / 255, green: 0x13 / 255, blue: 0x18 / 255)   // text on the white button
    static let soft = Color(red: 0xD4 / 255, green: 0xD9 / 255, blue: 0xE1 / 255)  // secondary text over the background
    static let label = Color(red: 0xE6 / 255, green: 0xE9 / 255, blue: 0xEE / 255)
    static let chip = Color.white.opacity(0.14)
    static let panel = Color(red: 18 / 255, green: 20 / 255, blue: 26 / 255).opacity(0.72)
    static let danger = Color(red: 1, green: 0.45, blue: 0.4)   // Remove, an import that failed
    static let ok = Color(red: 0.2, green: 0.85, blue: 0.4)
    static let warn = Color(red: 1, green: 0.78, blue: 0.3)
}

// MARK: - Background

/// The selected game's icon, enlarged past the edges, blurred and darkened; a new selection fades in over the last (key: the game). foldAt: portrait on a foldable,
/// the fold's height as a fraction (darker below it). Drawn whole by BackdropRender (off the main thread, once per game and size) rather than by SwiftUI's blur
/// and gradient: those blend in 8 bits, and a dark blur over a whole screen then shows bands
struct Backdrop: View {
    let image: PlatformImage?
    let key: String
    var foldAt: Double? = nil
    @State private var drawn: PlatformImage?
    @State private var drawnKey = ""

    var body: some View {
        GeometryReader { g in
            let want = "\(key)|\(Int(g.size.width))x\(Int(g.size.height))|\(foldAt ?? -1)"
            ZStack {
                Palette.ground
                if let drawn {
                    Image(platformImage: drawn).resizable().interpolation(.high).frame(width: g.size.width, height: g.size.height)
                        .id(drawnKey).transition(.opacity)
                } else {
                    BackdropRender.shade(foldAt)   // before the first is drawn: the shading alone, no flash of the sharp icon
                }
            }
            .animation(.easeInOut(duration: 0.35), value: drawnKey)
            .task(id: want) {
                guard let image, g.size.width > 0, g.size.height > 0 else { drawn = nil; return }
                let (size, fold) = (g.size, foldAt)
                let made = await Task.detached(priority: .userInitiated) { BackdropRender.image(image, size: size, foldAt: fold) }.value
                drawn = made; drawnKey = want
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// The background drawn in one pass of Core Image in 16-bit floating point: the icon filled past the edges (120 points), blurred (28 points; 30 on the foldable's
/// portrait), its colours raised (saturation 1.2, brightness −0.08), the shading over it, then a dither of under ±1/255 as it goes to 8 bits, which keeps the bands
/// away without any grain to see. At twice the view's size in points at most
enum BackdropRender {
    // sRGB, not Core Image's linear default: SwiftUI's blur and gradient (as before) blend in sRGB, and linear blending made the background darker and harsher
    static let context = CIContext(options: [.workingFormat: CIFormat.RGBAh, .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, .cacheIntermediates: false])
    static let ink = (r: 6.0 / 255, g: 7.0 / 255, b: 10.0 / 255)

    /// The shading's stops: (where from the top, 0…1, how dark)
    static func stops(_ foldAt: Double?) -> [(Double, Double)] {
        guard let f = foldAt else { return [(0, 0.62), (0.45, 0.42), (1, 0.7)] }
        return [(0, 0.35), (max(f - 0.04, 0), 0.55), (min(f + 0.04, 1), 0.78), (1, 0.84)]
    }
    static func shade(_ foldAt: Double?) -> LinearGradient {
        let c = Color(red: ink.r, green: ink.g, blue: ink.b)
        return LinearGradient(stops: stops(foldAt).map { .init(color: c.opacity($0.1), location: $0.0) }, startPoint: .top, endPoint: .bottom)
    }

    static func image(_ icon: PlatformImage, size: CGSize, foldAt: Double?) -> PlatformImage? {
        guard let cg = icon.cg else { return nil }
        let s: CGFloat = 2, w = (size.width * s).rounded(), h = (size.height * s).rounded()
        let target = CGRect(x: 0, y: 0, width: w, height: h)
        // the icon over the view and 60 points past each edge, centred (scaledToFill)
        let src = CIImage(cgImage: cg), side = (max(size.width, size.height) + 120) * s
        let k = side / max(src.extent.width, src.extent.height)
        let placed = src.transformed(by: CGAffineTransform(scaleX: k, y: k)).transformed(by: CGAffineTransform(translationX: (w - side) / 2, y: (h - side) / 2))
        let blurred = placed.clampedToExtent().applyingGaussianBlur(sigma: Double((foldAt == nil ? 28 : 30) * s)).cropped(to: target)
        let colour = CIFilter.colorControls(); colour.inputImage = blurred; colour.saturation = 1.2; colour.brightness = -0.08
        // the shading, one row per pixel of height (Core Image's rows run from the bottom)
        let rows = Int(h), st = stops(foldAt)
        var px = [Float](repeating: 0, count: rows * 4)
        for y in 0..<rows {
            let t = 1 - (Double(y) + 0.5) / Double(rows)
            let i = st.lastIndex { $0.0 <= t } ?? 0, j = min(i + 1, st.count - 1)
            let a = st[j].0 > st[i].0 ? st[i].1 + (st[j].1 - st[i].1) * (t - st[i].0) / (st[j].0 - st[i].0) : st[i].1
            px[y * 4] = Float(ink.r * a); px[y * 4 + 1] = Float(ink.g * a); px[y * 4 + 2] = Float(ink.b * a); px[y * 4 + 3] = Float(a)   // premultiplied
        }
        let column = CIImage(bitmapData: px.withUnsafeBytes { Data($0) }, bytesPerRow: 16, size: CGSize(width: 1, height: rows), format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        let shading = column.transformed(by: CGAffineTransform(scaleX: w, y: 1)).cropped(to: target)
        let shaded = shading.composited(over: colour.outputImage!.cropped(to: target))
        // the dither: uniform noise of ±0.5/255 per channel, added before the 8-bit rounding
        let noise = CIFilter.randomGenerator().outputImage!.cropped(to: target)
        let scale = CIFilter.colorMatrix(); scale.inputImage = noise
        let d = CGFloat(1.0 / 255)
        scale.rVector = CIVector(x: d, y: 0, z: 0, w: 0); scale.gVector = CIVector(x: 0, y: d, z: 0, w: 0); scale.bVector = CIVector(x: 0, y: 0, z: d, w: 0)
        scale.aVector = CIVector(x: 0, y: 0, z: 0, w: 0); scale.biasVector = CIVector(x: -d / 2, y: -d / 2, z: -d / 2, w: 0)
        let add = CIFilter.additionCompositing(); add.inputImage = scale.outputImage!; add.backgroundImage = shaded
        guard let out = context.createCGImage(add.outputImage!.cropped(to: target), from: target, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else { return nil }
        return PlatformImage(cg: out)
    }
}

// MARK: - Controls

/// Console-like press feedback: the control shrinks a little and dims while held (with a light tap on a phone)
struct PressStyle: ButtonStyle {
    var scale: CGFloat = 0.95
    func makeBody(configuration c: Configuration) -> some View {
        c.label
            .scaleEffect(c.isPressed ? scale : 1)
            .brightness(c.isPressed ? -0.08 : 0)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: c.isPressed)
#if canImport(UIKit)
            .onChange(of: c.isPressed) { _, down in if down { Haptics.tap() } }
#endif
    }
}
#if canImport(UIKit)
enum Haptics {
    static let light = UIImpactFeedbackGenerator(style: .light)
    static func tap() { light.impactOccurred(intensity: 0.6) }
}
#endif

/// NX Pocket's wordmark: its logo (rounded at 22.5 %, as the app icon) and "NX Pocket" in SF Pro Rounded bold, "Pocket" in a gradient: on a light background dark "NX"
/// with blue-violet to pink, on a dark one white "NX" with cyan to yellow (the logo's own colours). An app without the logo (a game's own) shows the words alone
struct Wordmark: View {
    let light: Bool
    var size: CGFloat = 20

    var body: some View {
        HStack(spacing: size * 0.45) {
            if let logo = PlatformImage(named: light ? "PocketLogo" : "PocketLogoDark") {
                Image(platformImage: logo).resizable().interpolation(.high).frame(width: size * 1.45, height: size * 1.45)
                    .clipShape(RoundedRectangle(cornerRadius: size * 1.45 * 0.225, style: .continuous))
                    .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
                    .accessibilityHidden(true)
            }
            (Text("NX ").foregroundStyle(light ? Palette.ink : Color.white)
             + Text("Pocket").foregroundStyle(LinearGradient(colors: light ? Self.lightGradient : Self.darkGradient, startPoint: .leading, endPoint: .trailing)))
                .font(.system(size: size, weight: .bold, design: .rounded))
        }
        .accessibilityElement(children: .combine).accessibilityLabel("NX Pocket")
    }
    static let lightGradient = [Color(red: 0x3A / 255, green: 0x2B / 255, blue: 1), Color(red: 0xA4 / 255, green: 0x3D / 255, blue: 1), Color(red: 1, green: 0x4F / 255, blue: 0xC8 / 255)]
    static let darkGradient = [Color(red: 0x31 / 255, green: 0xE7 / 255, blue: 1), Color(red: 1, green: 0xE0 / 255, blue: 0x3A / 255)]
}

/// The screen's one white button (Play, Make Game Pack, Send to iPhone), as a console's game page has it: its symbol and name, on Liquid Glass that answers the touch
struct PrimaryButton: View {
    let title: String
    var symbol: String? = nil
    var height: CGFloat = 48
    var wide = false
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: height * 0.18) {
                if let symbol { Image(systemName: symbol).font(.system(size: height * 0.3, weight: .bold)) }
                Text(title).font(.system(size: height * 0.35, weight: .semibold))
            }
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, height * 0.55)
            .frame(maxWidth: wide ? .infinity : nil).frame(height: height)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(.white).interactive(), in: .capsule)
        .disabled(!enabled).opacity(enabled ? 1 : 0.5)
    }
}

/// A Liquid Glass capsule with a white symbol and name: the secondary actions beside a PrimaryButton (Export, Log, Stop)
struct GlassButton: View {
    let title: String
    var symbol: String? = nil
    var height: CGFloat = 40
    var tint: Color? = nil   // a tinted action (Stop: the danger colour)
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let symbol { Image(systemName: symbol).font(.system(size: height * 0.34, weight: .semibold)) }
                Text(title).font(.system(size: height * 0.35, weight: .medium))
            }
            .foregroundStyle(.white.opacity(enabled ? 1 : 0.4))
            .padding(.horizontal, height * 0.45).frame(height: height).contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(tint.map { .regular.tint($0.opacity(0.55)).interactive(enabled) } ?? .regular.interactive(enabled), in: .capsule)
        .disabled(!enabled)
    }
}

/// A round Liquid Glass button with a white symbol (Game settings, Close; the shortcuts): its name under it where asked, and always as its accessibility label
struct RoundButton: View {
    let symbol: String
    let title: String
    var size: CGFloat = 48
    var showTitle = false
    var dot: Bool? = nil       // a status dot at its top right: on (green) or off
    var enabled = true
    let action: () -> Void

    var body: some View {
        VStack(spacing: 7) {
            Button(action: action) {
                Image(systemName: symbol).font(.system(size: size * 0.36, weight: .semibold)).foregroundStyle(.white.opacity(enabled ? 1 : 0.35))
                    .frame(width: size, height: size).contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(enabled), in: .circle)
            .overlay(alignment: .topTrailing) {
                if let dot { Circle().fill(dot ? Palette.ok : Color(white: 0.55)).frame(width: size * 0.2, height: size * 0.2)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.4), lineWidth: 1.5)).offset(x: -size * 0.04, y: size * 0.04) }
            }
            .disabled(!enabled)
            if showTitle { Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(enabled ? Palette.label : Palette.soft).lineLimit(1).fixedSize() }
        }
        .accessibilityElement(children: .combine).accessibilityLabel(title)
    }
}

/// A panel of Liquid Glass over the backdrop (the Mac's game details, a dialog)
struct GlassPanel<Content: View>: View {
    var radius: CGFloat = 24
    @ViewBuilder let content: () -> Content
    var body: some View {
        content().glassEffect(.regular, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

// MARK: - Games

/// A game's cover: its own icon (no art is fetched from anywhere), else its name's first letter; selected, a white ring round it and a shadow under it
struct CoverArt: View {
    let image: PlatformImage?
    let name: String
    let side: CGFloat
    var selected = false
    var focus: CGFloat? = nil   // 0…1: how strongly it shows as selected (the ring, the shadow), as a row scrolls it towards the selected place; nil: `selected`

    var body: some View {
        let f = focus ?? (selected ? 1 : 0)
        Group {
            if let image { Image(platformImage: image).resizable().interpolation(.high).antialiased(true).scaledToFill() }   // a 256 icon drawn large: smooth, not blocky
            else { LinearGradient(colors: [Color.white.opacity(0.14), Color.white.opacity(0.05)], startPoint: .top, endPoint: .bottom)
                    .overlay(Text(name.prefix(1)).font(.system(size: side * 0.36, weight: .bold, design: .rounded)).foregroundStyle(.white.opacity(0.8))) }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: side * 0.11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: side * 0.11 + 5, style: .continuous).strokeBorder(.white, lineWidth: 3).padding(-7).opacity(f))
        .shadow(color: .black.opacity(0.5 * f), radius: 20, y: 16)
    }
}

/// The dashed tile at the end of the games: Import game pack on the phone, Add game (and the drop target) on the Mac
struct DashedTile: View {
    let side: CGFloat
    let symbol: String
    let title: String
    var highlighted = false   // a drag over it
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 24, weight: .regular))
                Text(title).font(.system(size: 13)).foregroundStyle(Palette.label).multilineTextAlignment(.center)
            }
            .frame(width: side, height: side)
            .background(RoundedRectangle(cornerRadius: side * 0.11, style: .continuous).fill(highlighted ? Palette.accent.opacity(0.18) : Color.white.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: side * 0.11, style: .continuous)
                .strokeBorder(highlighted ? Palette.accent : Color.white.opacity(0.45), style: StrokeStyle(lineWidth: 2, dash: [6, 5])))
            .contentShape(RoundedRectangle(cornerRadius: side * 0.11, style: .continuous))
        }
        .buttonStyle(PressStyle(scale: 0.97))
    }
}

// MARK: - About

/// What both apps say of themselves (About NX Pocket on the iPhone, the About window and the setup window on the Mac): the version, what they are built on, and that
/// they have nothing to do with Nintendo and bring no games or keys
enum About {
    /// "1.0 (436, a1b2c3d4e5f6)": the version, the build number (the checkout's commit count) and the commit, from Info.plist
    static var version: String {
        let i = Bundle.main.infoDictionary ?? [:]
        let v = i["CFBundleShortVersionString"] as? String ?? "1.0", b = i["CFBundleVersion"] as? String ?? "", c = i["NXPocketCommit"] as? String ?? ""
        return v + (b.isEmpty ? "" : " (\(b)\(c.isEmpty ? "" : ", " + c))")
    }
    static var disclaimer: String { tr("NX Pocket is not affiliated with, authorized or endorsed by Nintendo. Nintendo Switch is a trademark of Nintendo. NX Pocket provides no games or keys; use only games and console keys you legally own.") }
    static var short: String { tr("Not affiliated with Nintendo · Only games you own") }
    static var basedOn: String { tr("Based on nxnative (seedds, MIT License).") }
    static var nxPlay: String { tr("NX Pocket for Mac adapts parts of NX Play (varyform, MIT License): reading the build's progress and running its tools.") }
}

