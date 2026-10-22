import AppKit

/// Small floating prompt at the top-centre of the real display ("Meeting detected — start the
/// proxy?"). Non-activating so it never steals focus from the call; `sharingType = .none` so it
/// never appears in a share. Auto-dismisses.
final class PromptPanel {
    private var panel: NSPanel?
    private var dismissTimer: Timer?
    private var onPrimary: (() -> Void)?
    private var onSecondary: (() -> Void)?

    func show(title: String, detail: String, primary: String, secondary: String, timeout: TimeInterval = 90,
              onPrimary: @escaping () -> Void, onSecondary: @escaping () -> Void) {
        dismiss()
        self.onPrimary = onPrimary
        self.onSecondary = onSecondary

        let width: CGFloat = 420
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 96),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .statusBar
        p.sharingType = .none
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false

        let bg = NSVisualEffectView(frame: p.contentView!.bounds)
        bg.material = .hudWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 12
        bg.autoresizingMask = [.width, .height]

        let icon = NSImageView(frame: NSRect(x: 16, y: 50, width: 28, height: 28))
        icon.image = NSImage(systemSymbolName: "eye.slash.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 22, weight: .medium))
        icon.contentTintColor = .systemGreen
        let t = NSTextField(labelWithString: title)
        t.font = .systemFont(ofSize: 13, weight: .semibold)
        t.frame = NSRect(x: 54, y: 62, width: width - 70, height: 18)
        let d = NSTextField(wrappingLabelWithString: detail)
        d.font = .systemFont(ofSize: 11)
        d.textColor = .secondaryLabelColor
        d.frame = NSRect(x: 54, y: 36, width: width - 70, height: 28)
        let b1 = NSButton(title: primary, target: self, action: #selector(primaryTapped))
        b1.bezelStyle = .rounded
        b1.keyEquivalent = "\r"
        let b2 = NSButton(title: secondary, target: self, action: #selector(secondaryTapped))
        b2.bezelStyle = .rounded
        b1.sizeToFit(); b2.sizeToFit()
        b1.frame.origin = NSPoint(x: width - 16 - b1.frame.width, y: 8)
        b2.frame.origin = NSPoint(x: b1.frame.minX - 8 - b2.frame.width, y: 8)
        [icon, t, d, b1, b2].forEach { bg.addSubview($0) }
        p.contentView = bg

        // Top-centre of the main (real) display, just under the menu bar.
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let vf = screen.visibleFrame
        p.setFrameOrigin(NSPoint(x: vf.midX - width / 2, y: vf.maxY - 96 - 12))
        p.orderFrontRegardless()
        panel = p
        dismissTimer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
            self?.onSecondary?(); self?.dismiss()
        }
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func dismiss() {
        dismissTimer?.invalidate(); dismissTimer = nil
        panel?.orderOut(nil)
        panel = nil
        onPrimary = nil; onSecondary = nil
    }

    @objc private func primaryTapped() { let h = onPrimary; dismiss(); h?() }
    @objc private func secondaryTapped() { let h = onSecondary; dismiss(); h?() }
}
