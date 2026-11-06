import AppKit

/// Opaque covers over a locked app's windows, for apps that won't stay hidden: some (Steam) un-hide
/// and re-activate themselves the moment they're hidden, so hiding them again turns into a loop that
/// also steals focus from the Touch ID prompt. Covers stay put instead. Never captured (the app is
/// masked whole in shares anyway) and they block clicks.
final class LockShield {
    private var panels: [String: [NSPanel]] = [:]

    var isEmpty: Bool { panels.isEmpty }

    /// Re-covers the app's current on-screen windows (call periodically while it's locked).
    func cover(_ app: NSRunningApplication) {
        guard let b = app.bundleIdentifier else { return }
        let frames = LockShield.windowFrames(pid: app.processIdentifier)
        var existing = panels[b] ?? []
        while existing.count > frames.count { existing.removeLast().orderOut(nil) }
        while existing.count < frames.count { existing.append(LockShield.makePanel(icon: app.icon)) }
        for (p, f) in zip(existing, frames) {
            if p.frame != f { p.setFrame(f, display: true) }
            if !p.isVisible { p.orderFrontRegardless() }
        }
        panels[b] = existing
    }

    func remove(_ b: String) {
        panels.removeValue(forKey: b)?.forEach { $0.orderOut(nil) }
    }

    /// The app's normal on-screen windows, in AppKit (bottom-left) coordinates.
    private static func windowFrames(pid: pid_t) -> [NSRect] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        let primaryH = CGDisplayBounds(CGMainDisplayID()).height
        return list.compactMap { w in
            guard (w[kCGWindowOwnerPID as String] as? pid_t) == pid, (w[kCGWindowLayer as String] as? Int) == 0,
                  let d = w[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: d),
                  r.width > 40, r.height > 40 else { return nil }
            return NSRect(x: r.minX, y: primaryH - r.maxY, width: r.width, height: r.height)
        }
    }

    private static func makePanel(icon: NSImage?) -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .floating
        p.sharingType = .none
        p.isOpaque = true
        p.hasShadow = false
        p.backgroundColor = .windowBackgroundColor
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        p.isReleasedWhenClosed = false
        let v = NSVisualEffectView()
        v.material = .underWindowBackground; v.state = .active
        let iv = NSImageView()
        iv.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "Locked")?
            .withSymbolConfiguration(.init(pointSize: 40, weight: .medium))
        iv.contentTintColor = .secondaryLabelColor
        iv.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(iv)
        NSLayoutConstraint.activate([iv.centerXAnchor.constraint(equalTo: v.centerXAnchor), iv.centerYAnchor.constraint(equalTo: v.centerYAnchor)])
        p.contentView = v
        return p
    }
}
