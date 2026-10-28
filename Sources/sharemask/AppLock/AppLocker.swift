import AppKit

/// Keeps locked apps hidden until unlocked. A guard against casual snooping on an unlocked Mac,
/// not a security boundary (someone logged in as you can still read an app's files).
final class AppLocker {
    private(set) var config = AppLockStore.load()
    let card = LockCard()
    /// bundle ID → when it was last frontmost while unlocked (for relock timing).
    private var unlocked: [String: Date] = [:]
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
        Log.info("app lock: relocking all (\(reason))")
        unlocked.removeAll()
        enforce()
        onChange?()
    }

    private func appEvent(_ app: NSRunningApplication, activated: Bool) {
        guard let b = app.bundleIdentifier, isActive, config.apps.contains(b) else { return }
        if unlocked[b] != nil { if activated { unlocked[b] = Date() }; return }
        hide(app)
        if activated { promptUnlock(app) }
    }

    /// Runs twice a second: hide locked apps that are showing, relock idle unlocked apps.
    private func enforce() {
        guard isActive else { return }
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        for (b, last) in unlocked {
            if b == front { unlocked[b] = Date(); continue }
            if Date().timeIntervalSince(last) >= Double(config.relockMinutes) * 60 {
                Log.info("app lock: \(b) relocked after \(config.relockMinutes) min in background")
                unlocked[b] = nil
                onChange?()
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
