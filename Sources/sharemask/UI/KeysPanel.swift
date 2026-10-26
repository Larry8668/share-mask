import AppKit

/// The session-key cheat sheet: a small click-through card on the real display, never captured.
/// Shown when a session starts (once per launch) and from Troubleshooting ▸ Keyboard shortcuts.
final class KeysPanel {
    static let lines: [(String, String)] = [
        ("⌃⌥B", "Panic: pixellate everything / restore"),
        ("⌃⌥M", "All per-app masks off / on"),
        ("⌃⌥R (hold)", "Reveal the frontmost app while held"),
        ("⌃⌥1 … ⌃⌥9", "Unmask / re-mask app #1–9 (numbers in Masks ▸)"),
        ("⌃⌥0", "Re-enable every mask"),
        ("⌃⌥A", "Allowlist mode on / off"),
        ("⌃⌥X", "End share / stop presenting"),
        ("⌃⌥K", "Show this card"),
    ]

    private var panel: NSPanel?
    private var timer: Timer?

    func show(seconds: TimeInterval = 8, on displayID: CGDirectDisplayID) {
        hide()
        let width: CGFloat = 380, rowH: CGFloat = 20
        let height = CGFloat(KeysPanel.lines.count) * rowH + 52
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .statusBar
        p.sharingType = .none
        p.ignoresMouseEvents = true
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        let bg = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        bg.material = .hudWindow; bg.state = .active; bg.wantsLayer = true; bg.layer?.cornerRadius = 12
        let title = NSTextField(labelWithString: "sharemask keys (active while sharing)")
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.frame = NSRect(x: 16, y: height - 30, width: width - 32, height: 18)
        bg.addSubview(title)
        for (i, (k, d)) in KeysPanel.lines.enumerated() {
            let y = height - 52 - CGFloat(i) * rowH
            let kl = NSTextField(labelWithString: k)
            kl.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
            kl.frame = NSRect(x: 16, y: y, width: 100, height: 18)
            let dl = NSTextField(labelWithString: d)
            dl.font = .systemFont(ofSize: 12)
            dl.textColor = .secondaryLabelColor
            dl.frame = NSRect(x: 120, y: y, width: width - 136, height: 18)
            bg.addSubview(kl); bg.addSubview(dl)
        }
        p.contentView = bg
        let b = CGDisplayBounds(displayID)
        let primaryH = CGDisplayBounds(CGMainDisplayID()).height
        p.setFrameOrigin(NSPoint(x: b.maxX - width - 20, y: primaryH - b.maxY + 20))
        p.orderFrontRegardless()
        panel = p
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in self?.hide() }
    }

    func hide() { timer?.invalidate(); timer = nil; panel?.orderOut(nil); panel = nil }
}
