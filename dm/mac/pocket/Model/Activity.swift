// What NX Pocket for Mac tells the player outside its window: a system notification when a game pack is made or sent (or fails), and the work in progress on the Dock
// icon (a bar under the icon, the share done as its badge). After NX Play (github.com/varyform/nx-native-wrapper, MIT, the notice in BuildProgress.swift), which shows its
// builds on the Dock the same way.
import AppKit
import UserNotifications

enum Activity {
    /// A notification; asked for permission the first time
    static func notify(_ title: String, _ body: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { ok, _ in
            guard ok else { return }
            let c = UNMutableNotificationContent()
            c.title = title; c.body = body; c.sound = .default
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
        }
    }

    /// The Dock icon: nil puts it back as it was, else the bar and the percentage
    @MainActor static func dock(_ fraction: Double?) {
        let tile = NSApp.dockTile
        guard let f = fraction else {
            if tile.contentView != nil || tile.badgeLabel != nil { tile.contentView = nil; tile.badgeLabel = nil; tile.display() }
            return
        }
        let view = (tile.contentView as? DockProgress) ?? DockProgress(frame: NSRect(origin: .zero, size: tile.size))
        let pct = Int((f * 100).rounded(.down))
        if tile.contentView !== view || view.fraction != f { view.fraction = f; tile.contentView = view; tile.badgeLabel = "\(pct)%"; tile.display() }
    }
}

/// The app's icon with a bar along its foot
private final class DockProgress: NSView {
    var fraction = 0.0
    override func draw(_ dirty: NSRect) {
        NSApp.applicationIconImage?.draw(in: bounds)
        let bar = NSRect(x: bounds.width * 0.14, y: bounds.height * 0.08, width: bounds.width * 0.72, height: bounds.height * 0.085)
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: bar, xRadius: bar.height / 2, yRadius: bar.height / 2).fill()
        var done = bar.insetBy(dx: bar.height * 0.18, dy: bar.height * 0.18); done.size.width *= max(0, min(fraction, 1))
        NSColor(red: 0x4F / 255, green: 0xD1 / 255, blue: 0xC5 / 255, alpha: 1).setFill()   // Palette.accent
        NSBezierPath(roundedRect: done, xRadius: done.height / 2, yRadius: done.height / 2).fill()
    }
}
