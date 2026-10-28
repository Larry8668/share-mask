import AppKit
import ScreenCaptureKit
import ApplicationServices

/// First-run setup: sharemask has no window of its own (it lives in the menu bar), so without this
/// a new user sees nothing after installing. Shows where the icon is, gets the two permissions
/// with live ✓ status, and gives the four things to know. Reopen: Settings ▸ Setup & permissions…
final class WelcomeWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var timer: Timer?
    private var screenStatus = NSTextField(labelWithString: "")
    private var axStatus = NSTextField(labelWithString: "")
    private var screenButton: NSButton?
    private var axButton: NSButton?
    var onOpenMenu: (() -> Void)?
    var onRelaunch: (() -> Void)?
    private var screenGrantedAtOpen = false

    static let seenKey = "welcomeSeenVersion"
    static let currentVersion = 1
    static var shouldShowAutomatically: Bool {
        UserDefaults.standard.integer(forKey: seenKey) < currentVersion || !CGPreflightScreenCaptureAccess()
    }

    var isVisible: Bool { window?.isVisible ?? false }

    func show() {
        if let w = window { NSApp.activate(ignoringOtherApps: true); w.makeKeyAndOrderFront(nil); return }
        screenGrantedAtOpen = CGPreflightScreenCaptureAccess() && !pretendFresh
        let W: CGFloat = 560, H: CGFloat = 470
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: W, height: H), styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.title = "Welcome to sharemask"
        w.isReleasedWhenClosed = false
        w.delegate = self
        let v = NSView(frame: NSRect(x: 0, y: 0, width: W, height: H))

        var y = H - 30
        func text(_ s: String, size: CGFloat = 13, weight: NSFont.Weight = .regular, color: NSColor = .labelColor, x: CGFloat = 28, width: CGFloat? = nil, height: CGFloat = 18) -> NSTextField {
            let t = NSTextField(wrappingLabelWithString: s)
            t.font = .systemFont(ofSize: size, weight: weight); t.textColor = color
            t.frame = NSRect(x: x, y: y - height, width: width ?? (W - x - 28), height: height)
            v.addSubview(t)
            return t
        }

        let icon = NSImageView(frame: NSRect(x: 28, y: y - 52, width: 52, height: 52))
        icon.image = NSImage(named: NSImage.applicationIconName)
        v.addSubview(icon)
        _ = text("sharemask lives in your menu bar", size: 18, weight: .semibold, x: 92, height: 24)
        y -= 26
        let eye = NSImageView(frame: NSRect(x: 92, y: y - 18, width: 18, height: 18))
        eye.image = NSImage(systemSymbolName: "eye.slash.fill", accessibilityDescription: nil)
        eye.contentTintColor = .secondaryLabelColor
        v.addSubview(eye)
        _ = text("Look for the crossed eye at the top right of your screen. Everything is in its menu.",
                 color: .secondaryLabelColor, x: 116, height: 32)
        y -= 48

        // Step 1: Screen Recording
        y -= 8
        _ = text("1  Allow Screen Recording  (required)", size: 14, weight: .semibold, height: 20)
        y -= 22
        _ = text("Needed to show a masked copy of your screen. Nothing leaves your Mac; frames are never saved.",
                 color: .secondaryLabelColor, width: W - 28 - 180, height: 32)
        let sb = NSButton(title: "Allow…", target: self, action: #selector(askScreen))
        sb.bezelStyle = .rounded; sb.frame = NSRect(x: W - 28 - 110, y: y - 28, width: 110, height: 28)
        v.addSubview(sb); screenButton = sb
        screenStatus.frame = NSRect(x: W - 28 - 170, y: y - 24, width: 56, height: 18); screenStatus.alignment = .right
        v.addSubview(screenStatus)
        y -= 46

        // Step 2: Accessibility
        _ = text("2  Allow Accessibility  (recommended)", size: 14, weight: .semibold, height: 20)
        y -= 22
        _ = text("Lets sharemask move stray windows back to your screen and notice when a locked app's window closes.",
                 color: .secondaryLabelColor, width: W - 28 - 180, height: 32)
        let ab = NSButton(title: "Allow…", target: self, action: #selector(askAX))
        ab.bezelStyle = .rounded; ab.frame = NSRect(x: W - 28 - 110, y: y - 28, width: 110, height: 28)
        v.addSubview(ab); axButton = ab
        axStatus.frame = NSRect(x: W - 28 - 170, y: y - 24, width: 56, height: 18); axStatus.alignment = .right
        v.addSubview(axStatus)
        y -= 50

        // How to use it
        _ = text("How to use it", size: 14, weight: .semibold, height: 20)
        y -= 24
        let tips = [
            "In a call, sharemask asks to start. Then share the screen called “sharemask” in Zoom / Meet / Teams.",
            "Choose what to blur: menu ▸ Edit regions ▸ pick an app, draw boxes, Save.",
            "While sharing: ⌃⌥B blurs everything instantly, ⌃⌥K shows all keys.",
            "Lock apps with Touch ID: menu ▸ App lock.",
        ]
        for t in tips {
            _ = text("•  " + t, height: 34)
            y -= 34
        }

        let done = NSButton(title: "Done", target: self, action: #selector(doneTapped))
        done.bezelStyle = .rounded; done.keyEquivalent = "\r"
        done.frame = NSRect(x: W - 28 - 100, y: 18, width: 100, height: 30)
        v.addSubview(done)
        let menu = NSButton(title: "Show me the menu", target: self, action: #selector(openMenu))
        menu.bezelStyle = .rounded
        menu.frame = NSRect(x: W - 28 - 100 - 12 - 160, y: 18, width: 160, height: 30)
        v.addSubview(menu)

        w.contentView = v
        w.center()
        window = w
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        Log.info("welcome window shown (screen recording \(screenGrantedAtOpen ? "granted" : "not granted"), accessibility \(AXIsProcessTrusted() ? "granted" : "not granted"))")
    }

    /// Test/README only: show the window as a brand-new user sees it (nothing granted yet).
    private let pretendFresh = ProcessInfo.processInfo.environment["SHAREMASK_PRETEND_NO_PERMISSIONS"] != nil

    private func refresh() {
        let screen = CGPreflightScreenCaptureAccess() && !pretendFresh
        let ax = AXIsProcessTrusted() && !pretendFresh
        screenStatus.stringValue = screen ? "✓" : ""
        screenStatus.textColor = .systemGreen
        screenStatus.font = .systemFont(ofSize: 16, weight: .bold)
        if screen && !screenGrantedAtOpen {
            // macOS only applies a new Screen Recording grant after a relaunch.
            screenButton?.title = "Relaunch"
            screenButton?.action = #selector(relaunchTapped)
        } else {
            screenButton?.title = screen ? "Allowed" : "Allow…"
            screenButton?.isEnabled = !screen
        }
        axStatus.stringValue = ax ? "✓" : ""
        axStatus.textColor = .systemGreen
        axStatus.font = .systemFont(ofSize: 16, weight: .bold)
        axButton?.title = ax ? "Allowed" : "Allow…"
        axButton?.isEnabled = !ax
    }

    @objc private func askScreen() {
        Log.info("welcome: requesting Screen Recording")
        if !CGRequestScreenCaptureAccess() {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
    }

    @objc private func askAX() {
        Log.info("welcome: requesting Accessibility")
        WindowEvacuator.requestTrust()
    }

    @objc private func relaunchTapped() { markSeen(); onRelaunch?() }
    @objc private func openMenu() { onOpenMenu?() }
    @objc private func doneTapped() { window?.close() }

    private func markSeen() { UserDefaults.standard.set(WelcomeWindow.currentVersion, forKey: WelcomeWindow.seenKey) }

    func windowWillClose(_ notification: Notification) {
        markSeen()
        timer?.invalidate(); timer = nil
        window = nil
        Log.info("welcome window closed")
    }

    /// Test/README helper: screenshot of the real on-screen window (ScreenCaptureKit), as users see it.
    func snapshot(to path: String) {
        guard let w = window else { return }
        let id = CGWindowID(w.windowNumber)
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let sw = content.windows.first(where: { $0.windowID == id }) else { Log.error("welcome snapshot: window not found"); return }
                let cfg = SCStreamConfiguration()
                cfg.width = Int(sw.frame.width * 2); cfg.height = Int(sw.frame.height * 2)
                cfg.captureResolution = .best; cfg.showsCursor = false
                let img = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: sw), configuration: cfg)
                let rep = NSBitmapImageRep(cgImage: img)
                try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                Log.info("welcome snapshot written to \(path)")
            } catch { Log.error("welcome snapshot failed: \(error)") }
        }
    }
}
