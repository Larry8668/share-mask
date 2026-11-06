import AppKit

/// Opaque covers over a locked app's windows, for when hiding it doesn't keep it out of sight:
/// - some apps (Steam) un-hide and re-activate themselves the moment they're hidden, so hiding them
///   again turns into a loop that also steals focus from the Touch ID prompt;
/// - sometimes a hide doesn't take (the app was still launching or activating): macOS counts the
///   app as hidden while its window stays on screen behind the lock card.
/// Covers sit just above the app's own windows (not over other apps) unless it's frontmost, block
/// clicks (a click brings up the lock card), and are never captured (the app is masked whole in
/// shares anyway).
final class LockShield {
    private var panels: [String: [NSPanel]] = [:]
    /// Called with the bundle ID when a cover is clicked.
    var onClick: ((String) -> Void)?

    var isEmpty: Bool { panels.isEmpty }
    func covers(_ b: String) -> Bool { !(panels[b] ?? []).isEmpty }

    struct Window { let id: CGWindowID; let frame: NSRect }

    /// Normal on-screen windows per process, in AppKit (bottom-left) coordinates. One window-list
    /// read, shared by every `cover` call in a pass.
    static func onScreenWindows() -> [pid_t: [Window]] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [:] }
        let primaryH = CGDisplayBounds(CGMainDisplayID()).height
        var out: [pid_t: [Window]] = [:]
        for w in list {
            guard let pid = w[kCGWindowOwnerPID as String] as? pid_t, (w[kCGWindowLayer as String] as? Int) == 0,
                  let id = w[kCGWindowNumber as String] as? UInt32,
                  let d = w[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: d),
                  r.width > 40, r.height > 40 else { continue }
            out[pid, default: []].append(Window(id: id, frame: NSRect(x: r.minX, y: primaryH - r.maxY, width: r.width, height: r.height)))
        }
        return out
    }

    /// Covers the app's current on-screen windows (none → covers removed). Call periodically while
    /// it's locked. Returns whether anything is covered.
    @discardableResult
    func cover(_ app: NSRunningApplication, windows: [pid_t: [Window]]? = nil) -> Bool {
        guard let b = app.bundleIdentifier else { return false }
        let wins = (windows ?? LockShield.onScreenWindows())[app.processIdentifier] ?? []
        var existing = panels[b] ?? []
        while existing.count > wins.count { existing.removeLast().orderOut(nil) }
        while existing.count < wins.count { existing.append(makePanel(for: b, icon: app.icon)) }
        // Frontmost (it activated itself): above everything. Otherwise just above its own window, so
        // the apps you're using in front of it stay visible.
        let front = app.isActive
        for (p, w) in zip(existing, wins) {
            if p.frame != w.frame { p.setFrame(w.frame, display: true) }
            if front {
                if p.level != .floating { p.level = .floating }
                if !p.isVisible { p.orderFrontRegardless() }
            } else {
                if p.level != .normal { p.level = .normal }
                p.order(.above, relativeTo: Int(w.id))
            }
        }
        if existing.isEmpty { panels[b] = nil } else { panels[b] = existing }
        return !existing.isEmpty
    }

    func remove(_ b: String) {
        panels.removeValue(forKey: b)?.forEach { $0.orderOut(nil) }
    }

    func removeAll() {
        for b in Array(panels.keys) { remove(b) }
    }

    private func makePanel(for b: String, icon: NSImage?) -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .normal
        p.sharingType = .none
        p.isOpaque = true
        p.hasShadow = false
        p.backgroundColor = .windowBackgroundColor
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        p.isReleasedWhenClosed = false
        let v = CoverView()
        v.material = .underWindowBackground; v.state = .active
        v.onClick = { [weak self] in self?.onClick?(b) }
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

private final class CoverView: NSVisualEffectView {
    var onClick: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }
}
