import AppKit
import ApplicationServices

/// Reads notification banners (and Notification Center list entries) through Accessibility.
///
/// macOS 26+/27: while a banner shows, Notification Center has a FULL-SCREEN window (layer 21);
/// each banner is an AXGroup with subrole "AXNotificationCenter…" whose frame is the banner and whose
/// description starts with the sending app's name ("WhatsApp, title, subtitle, body").
/// Used for (1) masking only the banners in shares instead of the whole screen and (2) covering
/// banners of locked apps on the user's own screen.
final class NotificationWatcher {
    struct Banner: Equatable {
        var id: String
        var frame: CGRect        // global points, top-left origin
        var appName: String
    }

    private(set) var banners: [Banner] = []
    /// True when a Notification Center overlay window is up but banners couldn't be read (no
    /// Accessibility): callers must then fail closed.
    private(set) var unreadable = false
    var onChange: (([Banner]) -> Void)?
    private var timer: Timer?
    private var covers: [String: NSPanel] = [:]
    /// App names (as shown in banners) → bundle ID, for apps whose banners get covered locally.
    var coverApps: [String: String] = [:]

    /// Runs only while something needs it (capturing, or hiding locked apps' previews): twice a
    /// second normally, ten times a second while Notification Center is showing something.
    var needed = false { didSet { if needed != oldValue { needed ? start() : stop() } } }
    private var fast = false

    func start() {
        guard timer == nil else { return }
        schedule(interval: 0.5)
    }

    private func schedule(interval: TimeInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in self?.poll() }
        timer?.tolerance = interval * 0.2   // let macOS coalesce wake-ups
        fast = interval < 0.5
    }

    func stop() { timer?.invalidate(); timer = nil; banners = []; updateCovers() }

    private func adjustRate(showing: Bool) {
        if showing && !fast { schedule(interval: 0.1) } else if !showing && fast { schedule(interval: 0.5) }
    }

    private static let ncBundle = "com.apple.notificationcenterui"

    /// Cheap check first (window list); Accessibility only while Notification Center shows something.
    private func ncHasOverlayWindow() -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let nc = NSRunningApplication.runningApplications(withBundleIdentifier: NotificationWatcher.ncBundle).first else { return false }
        return list.contains { ($0[kCGWindowOwnerPID as String] as? pid_t) == nc.processIdentifier && (($0[kCGWindowLayer as String] as? Int) ?? 0) != 0 }
    }

    private func poll() {
        let fresh: [Banner]
        let showing = ncHasOverlayWindow()
        adjustRate(showing: showing)
        if showing {
            if AXIsProcessTrusted(), let nc = NSRunningApplication.runningApplications(withBundleIdentifier: NotificationWatcher.ncBundle).first {
                fresh = NotificationWatcher.readBanners(pid: nc.processIdentifier)
                unreadable = false
            } else { fresh = []; unreadable = true }
        } else { fresh = []; unreadable = false }
        guard fresh != banners else { return }
        let newOnes = fresh.filter { b in !banners.contains { $0.id == b.id } }
        for b in newOnes { Log.info("notification banner from \(b.appName) at \(Int(b.frame.minX)),\(Int(b.frame.minY)) \(Int(b.frame.width))x\(Int(b.frame.height))") }
        banners = fresh
        updateCovers()
        onChange?(fresh)
    }

    static func readBanners(pid: pid_t) -> [Banner] {
        var out: [Banner] = []
        func str(_ el: AXUIElement, _ a: String) -> String? {
            var v: CFTypeRef?
            guard AXUIElementCopyAttributeValue(el, a as CFString, &v) == .success else { return nil }
            return v as? String
        }
        func frame(_ el: AXUIElement) -> CGRect? {
            var p: CFTypeRef?, s: CFTypeRef?
            guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &p) == .success,
                  AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &s) == .success else { return nil }
            var pt = CGPoint.zero, sz = CGSize.zero
            AXValueGetValue(p as! AXValue, .cgPoint, &pt); AXValueGetValue(s as! AXValue, .cgSize, &sz)
            return CGRect(origin: pt, size: sz)
        }
        func walk(_ el: AXUIElement, _ depth: Int) {
            guard depth < 8 else { return }
            let role = str(el, kAXRoleAttribute) ?? ""
            if role == "AXMenuBar" { return }
            let sub = str(el, kAXSubroleAttribute) ?? ""
            if sub.hasPrefix("AXNotificationCenter"), let desc = str(el, kAXDescriptionAttribute), let f = frame(el), f.width > 20, f.height > 20 {
                let app = desc.components(separatedBy: ", ").first ?? desc
                out.append(Banner(id: str(el, kAXIdentifierAttribute) ?? "\(f)", frame: f, appName: app))
                return
            }
            var kids: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &kids) == .success, let k = kids as? [AXUIElement] {
                for c in k { walk(c, depth + 1) }
            }
        }
        walk(AXUIElementCreateApplication(pid), 0)
        return out
    }

    // MARK: Local covers for locked apps

    private func updateCovers() {
        let wanted = banners.filter { coverApps[$0.appName] != nil }
        for (id, panel) in covers where !wanted.contains(where: { $0.id == id }) {
            panel.orderOut(nil); covers[id] = nil
        }
        for b in wanted {
            let panel = covers[b.id] ?? makeCover(for: b)
            covers[b.id] = panel
            let primaryH = CGDisplayBounds(CGMainDisplayID()).height
            let f = NSRect(x: b.frame.minX, y: primaryH - b.frame.maxY, width: b.frame.width, height: b.frame.height)
            if panel.frame != f { panel.setFrame(f, display: true) }
            panel.orderFrontRegardless()
        }
    }

    private func makeCover(for b: Banner) -> NSPanel {
        Log.info("covering notification from locked app \(b.appName)")
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .popUpMenu                 // above Notification Center's layer
        p.ignoresMouseEvents = true          // clicks reach the banner → opens the app → lock card
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        // Solid, not a blur material: a blurred-behind background can leave banner text partly legible.
        let bg = NSView(); bg.wantsLayer = true; bg.layer?.cornerRadius = 16
        bg.layer?.backgroundColor = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedWhite: 0.16, alpha: 1) : NSColor(calibratedWhite: 0.95, alpha: 1) }.cgColor
        bg.autoresizingMask = [.width, .height]
        let icon = NSImageView(frame: NSRect(x: 14, y: 0, width: 38, height: 38))
        icon.image = coverApps[b.appName].map { AppModel.icon($0) }
        let lock = NSImageView(frame: NSRect(x: 40, y: 0, width: 16, height: 16))
        lock.image = NSImage(systemSymbolName: "lock.circle.fill", accessibilityDescription: nil)
        lock.contentTintColor = .systemGreen
        let t = NSTextField(labelWithString: b.appName); t.font = .systemFont(ofSize: 13, weight: .semibold)
        let d = NSTextField(labelWithString: "New notification — unlock to read"); d.font = .systemFont(ofSize: 12); d.textColor = .secondaryLabelColor
        let stack = NSView()
        [icon, lock, t, d].forEach { stack.addSubview($0) }
        bg.addSubview(stack)
        p.contentView = bg
        // Lay out relative to the banner height once the frame is known.
        let h = b.frame.height
        icon.frame = NSRect(x: 14, y: (h - 38) / 2, width: 38, height: 38)
        lock.frame = NSRect(x: 40, y: (h - 38) / 2 - 2, width: 16, height: 16)
        t.frame = NSRect(x: 64, y: h / 2 + 1, width: b.frame.width - 76, height: 18)
        d.frame = NSRect(x: 64, y: h / 2 - 18, width: b.frame.width - 76, height: 16)
        stack.frame = NSRect(x: 0, y: 0, width: b.frame.width, height: h)
        return p
    }
}
