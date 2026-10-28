import AppKit
import LocalAuthentication

private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// The lock prompt: "<App> is locked" with Touch ID / login password, and a field for the optional
/// sharemask password. Also used for "Quit sharemask?" and for changing App lock settings.
final class LockCard: NSObject, NSTextFieldDelegate {
    private var panel: NSPanel?
    private var field: NSSecureTextField?
    private var errorLabel: NSTextField?
    private var onResult: ((Bool) -> Void)?
    private var authContext: LAContext?
    /// Start the Touch ID / password prompt as soon as the card appears (no extra click).
    var autoPrompt = true
    private(set) var subject: String?           // bundle ID or a purpose key ("quit", "settings")
    var config: () -> AppLockConfig = { AppLockConfig() }
    var isVisible: Bool { panel?.isVisible ?? false }

    /// - subject: what this card is for (one card at a time; a new request replaces the old one).
    func show(subject: String, title: String, detail: String, icon: NSImage?, completion: @escaping (Bool) -> Void) {
        if self.subject == subject, isVisible { panel?.makeKeyAndOrderFront(nil); return }
        close(result: false)
        self.subject = subject
        onResult = completion
        let cfg = config()
        let hasCustom = cfg.passwordHash != nil
        let width: CGFloat = 360, height: CGFloat = hasCustom ? 268 : 214

        let p = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .modalPanel
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]   // (.moveToActiveSpace with .canJoinAllSpaces aborts)
        p.isReleasedWhenClosed = false
        let bg = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        bg.material = .popover; bg.state = .active; bg.wantsLayer = true; bg.layer?.cornerRadius = 16

        var y = height - 24 - 56
        let iv = NSImageView(frame: NSRect(x: (width - 56) / 2, y: y, width: 56, height: 56))
        iv.image = icon ?? NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil)
        bg.addSubview(iv)
        let badge = NSImageView(frame: NSRect(x: (width - 56) / 2 + 38, y: y - 4, width: 22, height: 22))
        badge.image = NSImage(systemSymbolName: "lock.circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 18, weight: .bold))
        badge.contentTintColor = .systemGreen
        bg.addSubview(badge)
        y -= 30
        let t = NSTextField(labelWithString: title)
        t.font = .systemFont(ofSize: 15, weight: .semibold); t.alignment = .center
        t.frame = NSRect(x: 16, y: y, width: width - 32, height: 20)
        bg.addSubview(t)
        y -= 20
        let d = NSTextField(labelWithString: detail)
        d.font = .systemFont(ofSize: 11); d.textColor = .secondaryLabelColor; d.alignment = .center
        d.frame = NSRect(x: 16, y: y, width: width - 32, height: 16)
        bg.addSubview(d)

        y -= 44
        let unlock = NSButton(title: Authenticator.touchIDAvailable ? "  Unlock with Touch ID" : "  Unlock with password",
                              target: self, action: #selector(systemAuth))
        unlock.image = NSImage(systemSymbolName: Authenticator.touchIDAvailable ? "touchid" : "key.fill", accessibilityDescription: nil)
        unlock.imagePosition = .imageLeading
        unlock.bezelStyle = .rounded; unlock.controlSize = .large
        unlock.keyEquivalent = hasCustom ? "" : "\r"
        unlock.frame = NSRect(x: 40, y: y, width: width - 80, height: 32)
        bg.addSubview(unlock)

        if hasCustom {
            y -= 40
            let f = NSSecureTextField(frame: NSRect(x: 40, y: y, width: width - 80, height: 26))
            f.placeholderString = "or sharemask password, then ⏎"
            f.target = self; f.action = #selector(customAuth)
            f.delegate = self
            bg.addSubview(f)
            field = f
            y -= 18
            let e = NSTextField(labelWithString: "")
            e.font = .systemFont(ofSize: 10); e.textColor = .systemRed; e.alignment = .center
            e.frame = NSRect(x: 16, y: y, width: width - 32, height: 14)
            bg.addSubview(e)
            errorLabel = e
        }
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
        cancel.bezelStyle = .inline; cancel.isBordered = false
        cancel.keyEquivalent = "\u{1b}"
        cancel.frame = NSRect(x: (width - 80) / 2, y: 12, width: 80, height: 20)
        bg.addSubview(cancel)

        p.contentView = bg
        let screen = NSScreen.main ?? NSScreen.screens[0]
        p.setFrameOrigin(NSPoint(x: screen.frame.midX - width / 2, y: screen.frame.midY - height / 2 + 60))
        panel = p
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
        if let f = field { p.makeFirstResponder(f) }
        Log.info("lock card: \(subject) (custom password \(hasCustom ? "set" : "not set"), auto prompt \(autoPrompt))")
        if autoPrompt {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self = self, self.subject == subject else { return }
                self.systemAuth()
            }
        }
    }

    @objc private func systemAuth() {
        let reason = subject.map { ["quit": "quit sharemask", "settings": "change App lock settings"][$0] ?? "unlock this app" } ?? "unlock"
        authContext?.invalidate()
        authContext = Authenticator.system(reason: reason) { [weak self] ok in
            if ok { Log.info("lock card \(self?.subject ?? "?"): unlocked via system prompt"); self?.close(result: true) }
        }
    }

    @objc private func customAuth() {
        guard let f = field else { return }
        if Authenticator.customPassword(f.stringValue, config: config()) {
            Log.info("lock card \(subject ?? "?"): unlocked via sharemask password")
            close(result: true)
        } else {
            f.stringValue = ""
            errorLabel?.stringValue = "Wrong password"
            Log.warn("lock card: wrong sharemask password for \(subject ?? "?")")
            panel?.shake()
        }
    }

    /// Test hook: same path as typing the password and pressing return.
    func submitForTesting(_ password: String) {
        field?.stringValue = password
        customAuth()
    }

    @objc private func cancelTapped() { close(result: false) }

    func close(result: Bool) {
        authContext?.invalidate()     // take down a still-open Touch ID prompt
        authContext = nil
        let cb = onResult
        onResult = nil
        let s = subject
        subject = nil
        panel?.orderOut(nil); panel = nil; field = nil; errorLabel = nil
        if s != nil { Log.info("lock card \(s!): \(result ? "authenticated" : "cancelled")") }
        cb?(result)
    }
}

private extension NSWindow {
    func shake() {
        let f = frame
        let anim = CAKeyframeAnimation()
        anim.values = [-8, 8, -6, 6, -3, 3, 0].map { NSValue(point: NSPoint(x: f.minX + $0, y: f.minY)) }
        anim.duration = 0.35
        animations = ["frameOrigin": anim]
        animator().setFrameOrigin(f.origin)
    }
}
