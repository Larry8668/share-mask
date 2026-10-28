import AppKit
import ApplicationServices

/// Keeps locked apps hidden until unlocked. A guard against casual snooping on an unlocked Mac,
/// not a security boundary (someone logged in as you can still read an app's files).
final class AppLocker {
    private(set) var config = AppLockStore.load()
    let card = LockCard()
    /// bundle ID → when it was last frontmost while unlocked (for relock timing).
    private var unlocked: [String: Date] = [:]
    /// Unlocked apps that have shown at least one window since unlocking. Relock when such an app
    /// is back to zero windows (closed with the red button), but not right after unlock while
    /// it's still opening its first window.
    private var hadWindow: Set<String> = []
    private var warnedNoAX = false
    /// Last window count seen per unlocked app (for logging changes) and when it first hit zero.
    private var lastWindowCount: [String: Int] = [:]
    private var zeroSince: [String: Date] = [:]
    /// Zero windows must last this long before relocking: while an app un-hides or switches
    /// Spaces, Accessibility can briefly report no windows (seen in testing: a false relock 2.7 s
    /// after unlocking).
    static let closedDebounce: TimeInterval = 0.5
    /// For a few seconds after unlocking (the app is un-hiding) an empty window list is not trusted.
    static let unlockGrace: TimeInterval = 3
    private var unlockedAt: [String: Date] = [:]
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    var onChange: (() -> Void)?
    /// Never lockable: sharemask itself and parts of macOS you need to unlock anything.
    static let unlockable: Set<String> = ["dev.sharemask.app", "com.apple.finder", "com.apple.loginwindow",
                                          "com.apple.systempreferences", "com.apple.SecurityAgent"]

    init() {
        card.config = { [weak self] in self?.config ?? AppLockConfig() }
    }

    var isActive: Bool { config.enabled && !config.apps.isEmpty }
    func isLocked(_ bundleID: String) -> Bool { isActive && config.apps.contains(bundleID) && unlocked[bundleID] == nil }

    func start() {
        guard timer == nil else { return }
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didUnhideApplicationNotification] {
            observers.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] n in
                guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                self?.appEvent(app, activated: name == NSWorkspace.didActivateApplicationNotification)
            })
        }
        observers.append(ws.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let self = self, let b = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier,
                  self.unlocked[b] != nil else { return }
            self.relock(b, reason: "app quit")
        })
        observers.append(ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            if self?.config.relockOnSleep == true { self?.lockAll(reason: "display sleep") }
        })
        observers.append(DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            if self?.config.relockOnSleep == true { self?.lockAll(reason: "screen locked") }
        })
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.enforce() }
        enforce()   // first thing after (re)launch: re-hide anything locked
    }

    func update(_ change: (inout AppLockConfig) -> Void) {
        var c = config
        change(&c)
        c.apps = c.apps.filter { !AppLocker.unlockable.contains($0) }
        guard c != config else { return }
        config = c
        AppLockStore.save(c)
        Log.info("app lock config: enabled=\(c.enabled) apps=\(c.apps) relock=\(c.relockMinutes)m sleep=\(c.relockOnSleep) quit=\(c.guardQuit) keepAlive=\(c.keepAlive) password=\(c.passwordHash != nil)")
        enforce()
        onChange?()
    }

    func lockAll(reason: String) {
        guard isActive, !unlocked.isEmpty else { return }
        Log.info("app lock: relocking all (\(reason)): \(unlocked.keys.sorted())")
        unlocked.removeAll()
        hadWindow.removeAll()
        enforce()
        onChange?()
    }

    private func relock(_ b: String, reason: String) {
        guard unlocked[b] != nil else { return }
        unlocked[b] = nil
        hadWindow.remove(b)
        zeroSince[b] = nil
        lastWindowCount[b] = nil
        Log.info("app lock: \(b) relocked (\(reason))")
        enforce()
        onChange?()
    }

    /// Lock the frontmost app now: relock it if it's on the list, or add it to the list (adding
    /// only makes things stricter, so no authentication).
    func lockFrontmost() {
        guard let app = NSWorkspace.shared.frontmostApplication, let b = app.bundleIdentifier else { return }
        guard !AppLocker.unlockable.contains(b) else { Log.info("app lock: \(b) can't be locked"); return }
        if config.apps.contains(b) && config.enabled {
            if unlocked[b] != nil { relock(b, reason: "lock-this-app shortcut") } else { hide(app) }
        } else {
            Log.info("app lock: adding \(b) via lock-this-app shortcut")
            update { $0.apps.append(b); $0.enabled = true }
        }
    }

    /// Windows the app has, including minimized ones (via Accessibility). nil if unknown.
    private func windowCount(_ app: NSRunningApplication) -> Int? {
        guard AXIsProcessTrusted() else {
            if !warnedNoAX { warnedNoAX = true; Log.warn("app lock: Accessibility not granted; can't relock on window close (only on quit/idle/sleep)") }
            return nil
        }
        var value: CFTypeRef?
        let r = AXUIElementCopyAttributeValue(AXUIElementCreateApplication(app.processIdentifier), kAXWindowsAttribute as CFString, &value)
        guard r == .success, let wins = value as? [AXUIElement] else { return r == .noValue ? 0 : nil }
        return wins.count   // minimized windows are included, closed ones are gone
    }

    private func inGrace(_ b: String) -> Bool {
        unlockedAt[b].map { Date().timeIntervalSince($0) < AppLocker.unlockGrace } ?? false
    }

    private func appEvent(_ app: NSRunningApplication, activated: Bool) {
        guard let b = app.bundleIdentifier, isActive, config.apps.contains(b) else { return }
        if unlocked[b] != nil {
            // Reopened after its window was closed: clicking the Dock icon activates the app BEFORE it
            // draws a new window, so "activated with no windows" means closed-then-reopened. Lock now,
            // however quickly it was reopened.
            if activated, hadWindow.contains(b), !inGrace(b), config.closeDelay >= 0, windowCount(app) == 0 {
                let closedFor = zeroSince[b].map { Date().timeIntervalSince($0) } ?? 0
                if config.closeDelay == 0 || closedFor >= Double(config.closeDelay) {
                    relock(b, reason: "reopened after its window was closed")
                    hide(app)
                    promptUnlock(app)
                    return
                }
            }
            if activated { unlocked[b] = Date() }
            return
        }
        hide(app)
        if activated { promptUnlock(app) }
    }

    /// Runs twice a second: hide locked apps that are showing, relock idle unlocked apps.
    private func enforce() {
        guard isActive else { return }
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        for (b, last) in unlocked {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: b).first, let n = windowCount(app) {
                if lastWindowCount[b] != n {
                    Log.info("app lock: \(b) windows \(lastWindowCount[b].map(String.init) ?? "?") → \(n)\(app.isHidden ? " (hidden)" : "")")
                    lastWindowCount[b] = n
                }
                if n > 0 { hadWindow.insert(b); zeroSince[b] = nil }
                else if hadWindow.contains(b) && !app.isHidden && !inGrace(b) && config.closeDelay >= 0 {
                    let since = zeroSince[b] ?? Date()
                    zeroSince[b] = since
                    if Date().timeIntervalSince(since) >= max(AppLocker.closedDebounce, Double(config.closeDelay)) {
                        relock(b, reason: "all windows closed")
                        continue
                    }
                }
            }
            if b == front { unlocked[b] = Date(); continue }
            if Date().timeIntervalSince(last) >= Double(config.relockMinutes) * 60 {
                relock(b, reason: config.relockMinutes == 0 ? "switched away" : "\(config.relockMinutes) min in background")
            }
        }
        for app in NSWorkspace.shared.runningApplications {
            guard let b = app.bundleIdentifier, config.apps.contains(b), unlocked[b] == nil, !app.isHidden, !app.isTerminated else { continue }
            hide(app)
        }
    }

    private func hide(_ app: NSRunningApplication) {
        guard !app.isHidden else { return }
        app.hide()
        Log.info("app lock: hid \(app.bundleIdentifier ?? "?")")
    }

    func promptUnlock(_ app: NSRunningApplication) {
        guard let b = app.bundleIdentifier else { return }
        let name = app.localizedName ?? b
        card.show(subject: b, title: "\(name) is locked", detail: "Unlock to use it. It relocks \(relockText).",
                  icon: app.icon) { [weak self] ok in
            guard ok, let self = self else { return }
            self.unlocked[b] = Date()
            self.unlockedAt[b] = Date()
            self.hadWindow.remove(b)
            Log.info("app lock: unlocked \(b)")
            app.unhide()
            app.activate()
            self.onChange?()
        }
    }

    var relockText: String {
        config.relockMinutes == 0 ? "as soon as you switch away" : "after \(config.relockMinutes) min in the background"
    }

    var unlockedApps: [String] { Array(unlocked.keys) }

    /// Ask for Touch ID / password before doing something sensitive (quit, settings changes).
    func authorize(_ purpose: String, title: String, detail: String, then action: @escaping () -> Void) {
        guard isActive else { action(); return }
        card.show(subject: purpose, title: title, detail: detail, icon: NSImage(named: NSImage.applicationIconName)) { ok in
            if ok { action() }
        }
    }
}
