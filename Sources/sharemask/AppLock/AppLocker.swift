import AppKit
import ApplicationServices
import CGSPrivate

/// Keeps locked apps hidden until unlocked. A guard against casual snooping on an unlocked Mac,
/// not a security boundary (someone logged in as you can still read an app's files).
final class AppLocker {
    private(set) var config: AppLockConfig
    /// Settings are still in the Keychain from an older version and macOS didn't allow reading them:
    /// App lock can't know what to lock yet, so nothing is saved (that would replace the real
    /// settings) until `retryLoad()` succeeds.
    private(set) var settingsUnreadable = false
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
    static let closedDebounce: TimeInterval = 1.0
    /// Right after an app opens a window it may drop or swap windows while setting up (seen with
    /// WhatsApp: a window, then 0 windows 1.4 s later, while the user was just opening it). A drop to
    /// zero within this long of a window appearing doesn't count as "closed".
    static let windowSettle: TimeInterval = 2.0
    /// A reopen only counts if the app really sat at zero windows this long (ignores flickers).
    static let minClosedForReopen: TimeInterval = 0.25
    private var windowAppearedAt: [String: Date] = [:]
    /// Window-server IDs of the app's windows that were visible while it had windows. Only these
    /// are checked for "on another desktop" (apps have hidden helper windows on other Spaces —
    /// checking any window gave a false "away" for Activity Monitor after a real close).
    private var visibleWindowIDs: [String: Set<CGWindowID>] = [:]

    /// The app's normal-size windows that the window server shows on screen right now.
    private func onScreenWindowIDs(_ app: NSRunningApplication) -> Set<CGWindowID> {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        var ids = Set<CGWindowID>()
        for w in list where (w[kCGWindowOwnerPID as String] as? pid_t) == app.processIdentifier && ((w[kCGWindowLayer as String] as? Int) ?? 1) == 0 {
            let b = (w[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) } ?? .zero
            if b.width > 200 && b.height > 150, let id = w[kCGWindowNumber as String] as? UInt32 { ids.insert(id) }
        }
        return ids
    }
    /// For a few seconds after unlocking (the app is un-hiding) an empty window list is not trusted.
    static let unlockGrace: TimeInterval = 3
    private var unlockedAt: [String: Date] = [:]
    /// Recent hides per locked app; an app hidden this often is fighting back (it un-hides itself).
    private var recentHides: [String: [Date]] = [:]
    /// Locked apps that won't stay hidden: covered by `shield` instead of being hidden again.
    private var fighting: Set<String> = []
    private let shield = LockShield()
    static let fightHides = 4, fightWindow: TimeInterval = 2
    /// An app that quits this soon after being unlocked and comes back this quickly is restarting
    /// itself (Steam relaunches after starting/updating), not being closed by someone.
    static let selfRestartAfterUnlock: TimeInterval = 20, selfRestartWithin: TimeInterval = 10
    private var restarting: [String: Date] = [:]
    /// When each locked app was last hidden: its window can take a moment to go.
    private var lastHideAt: [String: Date] = [:]
    static let hideSettle: TimeInterval = 0.4
    /// Switching desktops (Spaces, or away from a full-screen app) makes Accessibility report zero
    /// windows for an app whose window is on another desktop — indistinguishable from "closed" by
    /// count alone. A drop to zero within this long after a Space change is treated as "away".
    static let spaceChangeWindow: TimeInterval = 2
    private var lastSpaceChange = Date.distantPast
    private var awayOnOtherSpace: Set<String> = []
    private var lastAwayNote: [String: String] = [:]
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    var onChange: (() -> Void)?
    /// Never lockable: sharemask itself and parts of macOS you need to unlock anything.
    static let unlockable: Set<String> = ["dev.sharemask.app", "com.apple.finder", "com.apple.loginwindow",
                                          "com.apple.systempreferences", "com.apple.SecurityAgent"]

    init() {
        config = AppLockConfig()
        applyLoaded(AppLockStore.load())
        card.config = { [weak self] in self?.config ?? AppLockConfig() }
        card.checkPassword = { [weak self] pw in self?.checkPassword(pw) ?? .unavailable }
        shield.onClick = { [weak self] b in
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: b).first else { return }
            Log.info("app lock: cover over \(b) clicked")
            self?.promptUnlock(app)
        }
    }

    private func applyLoaded(_ loaded: AppLockStore.Loaded) {
        switch loaded {
        case .ok(let c): config = c; settingsUnreadable = false
        case .keychainDenied: settingsUnreadable = true
        }
    }

    /// Asks macOS for Keychain access again (the window's "Try again").
    func retryLoad() {
        guard settingsUnreadable else { return }
        applyLoaded(AppLockStore.load())
        Log.info("app lock: settings \(settingsUnreadable ? "still unreadable" : "loaded") after retry")
        guard !settingsUnreadable else { return }
        reschedule()
        enforce()
        onChange?()
    }

    // MARK: sharemask password

    enum PasswordCheck { case ok, wrong, unavailable }
    /// Read from the Keychain the first time it's needed, then kept for this run.
    private var passwordHashCache: String?

    func checkPassword(_ pw: String) -> PasswordCheck {
        guard config.hasPassword, !pw.isEmpty else { return .wrong }
        if passwordHashCache == nil {
            if let legacy = config.passwordHash { passwordHashCache = legacy }   // not yet moved (see AppLockStore.load)
            else {
                switch AppLockStore.readPasswordHash() {
                case .hash(let h): passwordHashCache = h
                case .missing: Log.warn("app lock: sharemask password is set but missing from the Keychain"); return .unavailable
                case .denied(let s): Log.warn("app lock: Keychain access to the sharemask password not allowed (\(s))"); return .unavailable
                }
            }
        }
        return AppLockStore.verify(pw, against: passwordHashCache ?? "") ? .ok : .wrong
    }

    /// Sets (or with nil removes) the sharemask password. Returns false if the Keychain refused.
    @discardableResult
    func setPassword(_ pw: String?) -> Bool {
        guard !settingsUnreadable else { return false }
        if let pw = pw {
            let h = AppLockStore.hash(pw)
            guard AppLockStore.setPasswordHash(h) else { return false }
            passwordHashCache = h
            update { $0.passwordSet = true; $0.passwordHash = nil }
            Log.info("app lock: sharemask password set")
        } else {
            guard AppLockStore.deletePasswordHash() else { return false }
            passwordHashCache = nil
            update { $0.passwordSet = nil; $0.passwordHash = nil }
            Log.info("app lock: sharemask password removed")
        }
        return true
    }

    var isActive: Bool { config.enabled && !config.apps.isEmpty }
    func isLocked(_ bundleID: String) -> Bool { isActive && config.apps.contains(bundleID) && unlocked[bundleID] == nil }

    private var started = false
    func start() {
        guard !started else { return }
        started = true
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didUnhideApplicationNotification] {
            observers.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] n in
                guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                self?.appEvent(app, activated: name == NSWorkspace.didActivateApplicationNotification)
            })
        }
        observers.append(ws.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let self = self, let b = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier else { return }
            if NSRunningApplication.runningApplications(withBundleIdentifier: b).isEmpty { self.shield.remove(b); self.fighting.remove(b) }
            guard self.unlocked[b] != nil else { return }
            if let at = self.unlockedAt[b], Date().timeIntervalSince(at) < AppLocker.selfRestartAfterUnlock {
                // Possibly restarting itself: keep it unlocked if it's back within a few seconds.
                self.restarting[b] = Date()
                Log.info("app lock: \(b) quit \(Int(Date().timeIntervalSince(at))) s after unlocking; waiting \(Int(AppLocker.selfRestartWithin)) s in case it's restarting itself")
                DispatchQueue.main.asyncAfter(deadline: .now() + AppLocker.selfRestartWithin) { [weak self] in
                    guard let self = self, self.restarting.removeValue(forKey: b) != nil else { return }
                    if NSRunningApplication.runningApplications(withBundleIdentifier: b).isEmpty { self.relock(b, reason: "app quit") }
                }
                return
            }
            self.relock(b, reason: "app quit")
        })
        observers.append(ws.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            self.lastSpaceChange = Date()
            if !self.unlocked.isEmpty { Log.info("app lock: desktop (Space) changed") }
        })
        observers.append(ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            if self?.config.relockOnSleep == true { self?.lockAll(reason: "display sleep") }
        })
        observers.append(DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            if self?.config.relockOnSleep == true { self?.lockAll(reason: "screen locked") }
        })
        reschedule()
        enforce()   // first thing after (re)launch: re-hide anything locked
    }

    func update(_ change: (inout AppLockConfig) -> Void) {
        guard !settingsUnreadable else {
            Log.warn("app lock: settings not saved — the saved ones are still waiting for Keychain access")
            return
        }
        var c = config
        change(&c)
        c.apps = c.apps.filter { !AppLocker.unlockable.contains($0) }
        guard c != config else { return }
        for b in Set(config.apps).subtracting(c.apps) {
            unlocked[b] = nil; restarting[b] = nil; fighting.remove(b); shield.remove(b); unobserve(b)
        }
        config = c
        AppLockStore.save(c)
        reschedule()
        Log.info("app lock config: enabled=\(c.enabled) apps=\(c.apps) relock=\(c.relockMinutes)m sleep=\(c.relockOnSleep) quit=\(c.guardQuit) keepAlive=\(c.keepAlive) password=\(c.hasPassword) perApp=\((c.appSettings ?? [:]).mapValues { "close=\($0.closeRelockSeconds.map(String.init) ?? "-") bg=\($0.relockMinutes.map(String.init) ?? "-") hide=\($0.hideNotifications.map { "\($0)" } ?? "-")" })")
        enforce()
        onChange?()
    }

    func lockAll(reason: String) {
        guard isActive, !unlocked.isEmpty else { return }
        Log.info("app lock: relocking all (\(reason)): \(unlocked.keys.sorted())")
        unlocked.removeAll()
        hadWindow.removeAll()
        for b in Array(axObservers.keys) { unobserve(b) }
        enforce()
        onChange?()
    }

    /// True if the app's main window is on a desktop (Space) other than the active one — e.g. you
    /// swiped to another desktop, or the app is full screen. A window closed with the red button
    /// (many apps just hide it) stays on the active desktop, so this tells the two apart.
    func isOnAnotherDesktop(_ app: NSRunningApplication) -> Bool {
        guard SMSpacesAPIAvailable() else { return false }
        // Every monitor shows its own Space ("Displays have separate Spaces"), so a window on the
        // external monitor is visible even though it isn't on the active (focused) Space.
        let current = Set(SMCurrentSpaces().map { $0.uint64Value })
        guard !current.isEmpty, let all = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return false }
        let known = app.bundleIdentifier.flatMap { visibleWindowIDs[$0] } ?? []
        guard !known.isEmpty else { return false }   // never saw it visible → can't claim it's elsewhere
        let mains = all.filter {
            ($0[kCGWindowOwnerPID as String] as? pid_t) == app.processIdentifier
                && ($0[kCGWindowNumber as String] as? UInt32).map { known.contains($0) } ?? false
        }
        for w in mains {
            guard let id = w[kCGWindowNumber as String] as? UInt32 else { continue }
            let spaces = SMSpacesForWindow(id).map { $0.uint64Value }
            if !spaces.isEmpty && current.isDisjoint(with: spaces) {
                // Polled 4×/s: log only when the answer changes.
                let note = "window \(id) is on desktop \(spaces) (shown: \(current.sorted()))"
                if lastAwayNote[app.bundleIdentifier ?? "?"] != note {
                    lastAwayNote[app.bundleIdentifier ?? "?"] = note
                    Log.info("app lock: \(app.bundleIdentifier ?? "?") \(note)")
                }
                return true
            }
        }
        return false
    }

    // MARK: Reopen detection
    //
    // Clicking the Dock icon of an app that is still frontmost (its window was just closed) sends no
    // "activated" notification — the app simply opens a new window. So watch for window creation
    // via an Accessibility observer (instant), backed by the 0.25 s window-count poll.

    private var axObservers: [String: AXObserver] = [:]

    private func shouldRelockOnReopen(_ b: String, closedSince: Date) -> Bool {
        let delay = config.closeDelay(for: b)
        guard unlocked[b] != nil, hadWindow.contains(b), !inGrace(b), delay >= 0 else { return false }
        let closedFor = Date().timeIntervalSince(closedSince)
        guard closedFor >= AppLocker.minClosedForReopen else { return false }
        return delay == 0 || closedFor >= Double(delay)
    }

    private func relockReopened(_ app: NSRunningApplication, _ b: String, via: String) {
        relock(b, reason: "reopened after its window was closed (\(via))")
        hide(app)
        promptUnlock(app)
    }

    /// Called from the AX observer when the app creates a window.
    fileprivate func windowCreated(pid: pid_t) {
        guard let app = NSRunningApplication(processIdentifier: pid), let b = app.bundleIdentifier, unlocked[b] != nil else { return }
        // Was it at zero windows (closed) just before this window appeared?
        let wasClosed = !awayOnOtherSpace.contains(b) && (zeroSince[b] != nil || lastWindowCount[b] == 0)
        defer { windowAppearedAt[b] = Date() }
        Log.info("app lock: \(b) created a window (was closed: \(wasClosed))")
        if wasClosed, shouldRelockOnReopen(b, closedSince: zeroSince[b] ?? .distantPast) {
            relockReopened(app, b, via: "window created")
        }
    }

    private func observe(_ app: NSRunningApplication, _ b: String) {
        guard axObservers[b] == nil, AXIsProcessTrusted() else { return }
        var obs: AXObserver?
        guard AXObserverCreate(app.processIdentifier, appLockAXCallback, &obs) == .success, let o = obs else { return }
        let el = AXUIElementCreateApplication(app.processIdentifier)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(o, el, kAXWindowCreatedNotification as CFString, refcon)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(o), .defaultMode)
        axObservers[b] = o
    }

    private func unobserve(_ b: String) {
        guard let o = axObservers.removeValue(forKey: b) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(o), .defaultMode)
    }

    /// Lock one app now (from the app window's "Lock now").
    func lockNow(_ b: String) {
        guard unlocked[b] != nil else { return }
        relock(b, reason: "Lock now")
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: b).first { hide(app) }
    }

    private func relock(_ b: String, reason: String) {
        guard unlocked[b] != nil else { return }
        unlocked[b] = nil
        restarting[b] = nil
        hadWindow.remove(b)
        awayOnOtherSpace.remove(b)
        visibleWindowIDs[b] = nil
        unobserve(b)
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
        if unlocked[b] != nil, restarting.removeValue(forKey: b) != nil {
            Log.info("app lock: \(b) restarted itself right after unlocking → still unlocked")
            unlockedAt[b] = Date()
            hadWindow.remove(b)
            zeroSince[b] = nil; lastWindowCount[b] = nil
            observe(app, b)
            return
        }
        if unlocked[b] != nil {
            // Reopened after its window was closed: clicking the Dock icon activates the app BEFORE it
            // draws a new window, so "activated with no windows" means closed-then-reopened. Lock now,
            // however quickly it was reopened.
            if activated, hadWindow.contains(b), !inGrace(b), config.closeDelay(for: b) >= 0, windowCount(app) == 0 {
                let closedFor = zeroSince[b].map { Date().timeIntervalSince($0) } ?? 0
                if config.closeDelay(for: b) == 0 || closedFor >= Double(config.closeDelay(for: b)) {
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
        if activated && card.subjectShowing != b { promptUnlock(app) }
    }

    private var fastTimer = false
    /// 4×/s while some locked app is unlocked (reopen detection needs it); otherwise once a second
    /// as a backstop (launch/activate/unhide notifications do the real work); no timer at all while
    /// App lock is off.
    private func reschedule() {
        // Fast too while a lock card is up or something is covered: a locked app whose hide didn't
        // take is covered within a quarter second.
        let wantFast = isActive && (!unlocked.isEmpty || !fighting.isEmpty || card.isVisible || !shield.isEmpty)
        if !isActive {
            timer?.invalidate(); timer = nil
            shield.removeAll()
            fighting.removeAll()
            return
        }
        if timer != nil && wantFast == fastTimer { return }
        timer?.invalidate()
        let interval = wantFast ? 0.25 : 1.0
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in self?.tick() }
        timer?.tolerance = interval * 0.2
        fastTimer = wantFast
    }

    private func tick() {
        guard isActive else { return }
        enforce()
        reschedule()
    }

    /// Hide locked apps that are showing, relock idle unlocked apps.
    private func enforce() {
        guard isActive else { return }
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        for (b, last) in unlocked {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: b).first, let n = windowCount(app) {
                if lastWindowCount[b] != n {
                    Log.info("app lock: \(b) windows \(lastWindowCount[b].map(String.init) ?? "?") → \(n)\(app.isHidden ? " (hidden)" : "")")
                    lastWindowCount[b] = n
                }
                if n > 0 {
                    let vis = onScreenWindowIDs(app)
                    if !vis.isEmpty { visibleWindowIDs[b] = vis }
                }
                if n > 0 && (lastWindowCount[b] ?? 0) == 0 && windowAppearedAt[b].map({ Date().timeIntervalSince($0) > 0.5 }) ?? true {
                    windowAppearedAt[b] = Date()
                }
                if n > 0 && awayOnOtherSpace.contains(b) {
                    awayOnOtherSpace.remove(b)
                    Log.info("app lock: \(b) window visible again on this desktop (was on another desktop, not closed)")
                    hadWindow.insert(b); zeroSince[b] = nil
                    continue
                }
                if n == 0, hadWindow.contains(b), !onScreenWindowIDs(app).isEmpty {
                    // Accessibility says no windows, the window server still shows one: a glitch
                    // (seen with WhatsApp right after opening), not a close.
                    if zeroSince[b] == nil { Log.info("app lock: \(b) reports 0 windows but one is still on screen → ignoring") }
                    continue
                }
                if n == 0, hadWindow.contains(b), zeroSince[b] == nil, isOnAnotherDesktop(app) {
                    if !awayOnOtherSpace.contains(b) { Log.info("app lock: \(b) has no windows here but its window is on another desktop → not relocking") }
                    awayOnOtherSpace.insert(b)
                } else if n == 0, hadWindow.contains(b), zeroSince[b] == nil, !SMSpacesAPIAvailable(),
                   Date().timeIntervalSince(lastSpaceChange) < AppLocker.spaceChangeWindow {
                    if !awayOnOtherSpace.contains(b) { Log.info("app lock: \(b) has no windows right after a desktop switch → on another desktop, not relocking") }
                    awayOnOtherSpace.insert(b)
                }
                if n == 0 && awayOnOtherSpace.contains(b) { continue }
                if n > 0 {
                    if let since = zeroSince[b], shouldRelockOnReopen(b, closedSince: since) {
                        relockReopened(app, b, via: "window list")
                        continue
                    }
                    hadWindow.insert(b); zeroSince[b] = nil
                }
                else if hadWindow.contains(b) && !app.isHidden && !inGrace(b) && config.closeDelay(for: b) >= 0
                            && !(windowAppearedAt[b].map { Date().timeIntervalSince($0) < AppLocker.windowSettle } ?? false) {
                    let since = zeroSince[b] ?? Date()
                    zeroSince[b] = since
                    if Date().timeIntervalSince(since) >= max(AppLocker.closedDebounce, Double(config.closeDelay(for: b))) {
                        relock(b, reason: "all windows closed")
                        continue
                    }
                }
            }
            if b == front { unlocked[b] = Date(); continue }
            let mins = config.relockMinutes(for: b)
            if Date().timeIntervalSince(last) >= Double(mins) * 60 {
                relock(b, reason: mins == 0 ? "switched away" : "\(mins) min in background")
            }
        }
        var windows: [pid_t: [LockShield.Window]]?   // read once, only if a locked app is running
        for app in NSWorkspace.shared.runningApplications {
            guard let b = app.bundleIdentifier, config.apps.contains(b), unlocked[b] == nil, !app.isTerminated else { continue }
            if windows == nil { windows = LockShield.onScreenWindows() }
            if fighting.contains(b) { shield.cover(app, windows: windows); continue }
            if !app.isHidden { hide(app); continue }
            // Counted as hidden, but its window can still be on screen: a hide that didn't take
            // (it was launching or activating), seen with WhatsApp behind the lock card. Cover it.
            if let t = lastHideAt[b], Date().timeIntervalSince(t) < AppLocker.hideSettle { continue }
            let was = shield.covers(b)
            let now = shield.cover(app, windows: windows)
            if now != was {
                Log.info(now ? "app lock: \(b) is hidden but its window is still on screen → covered"
                             : "app lock: \(b) window gone → cover removed")
            }
        }
    }

    private func hide(_ app: NSRunningApplication) {
        guard let b = app.bundleIdentifier else { return }
        if fighting.contains(b) { shield.cover(app); return }
        guard !app.isHidden else { return }
        let now = Date()
        var h = (recentHides[b] ?? []).filter { now.timeIntervalSince($0) < AppLocker.fightWindow }
        h.append(now)
        recentHides[b] = h
        if h.count > AppLocker.fightHides {
            // It un-hides itself as soon as it's hidden: stop the loop, cover its windows instead.
            fighting.insert(b)
            recentHides[b] = nil
            Log.warn("app lock: \(b) keeps un-hiding itself → covering its windows instead of hiding it")
            shield.cover(app)
            reschedule()
            return
        }
        app.hide()
        lastHideAt[b] = now
        Log.info("app lock: hid \(b)")
        // Check it really went (cover it if not) as soon as it's had time to.
        DispatchQueue.main.asyncAfter(deadline: .now() + AppLocker.hideSettle + 0.05) { [weak self] in self?.enforce() }
        // Hiding the frontmost app hands focus to some other app, and the Touch ID prompt only takes
        // a finger while sharemask has focus: take it back if a lock card is up.
        if card.isVisible {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.card.regainFocus() }
        }
    }

    /// `detail` overrides the card's second line; `then` runs after a successful unlock.
    func promptUnlock(_ app: NSRunningApplication, detail: String? = nil, then: (() -> Void)? = nil) {
        guard let b = app.bundleIdentifier else { return }
        let name = app.localizedName ?? b
        card.show(subject: b, title: "\(name) is locked", detail: detail ?? "Unlock to use it. It relocks \(relockText(for: b)).",
                  icon: app.icon) { [weak self] ok in
            guard ok, let self = self else { return }
            self.unlocked[b] = Date()
            self.unlockedAt[b] = Date()
            self.hadWindow.remove(b)
            self.shield.remove(b)
            self.fighting.remove(b)
            self.recentHides[b] = nil
            self.observe(app, b)
            self.reschedule()
            Log.info("app lock: unlocked \(b)")
            app.unhide()
            app.activate()
            self.onChange?()
            then?()
        }
        reschedule()   // fast checks while the card is up
        DispatchQueue.main.asyncAfter(deadline: .now() + AppLocker.hideSettle + 0.1) { [weak self] in self?.enforce() }
    }

    /// Test hooks: cover an app's windows as if its hide hadn't taken, and click the cover.
    func coverForTesting(_ b: String) {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: b).first else { return }
        Log.info("app lock test: covered \(b): \(shield.cover(app))")
    }
    func clickCoverForTesting(_ b: String) { shield.onClick?(b) }

    /// Accessibility window count (incl. minimized), for callers that need to wait for a window.
    func windowCountFor(_ app: NSRunningApplication) -> Int { windowCount(app) ?? 0 }

    func relockText(for b: String) -> String {
        let m = config.relockMinutes(for: b)
        return m == 0 ? "as soon as you switch away" : "after \(m) min in the background"
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

/// C callback for the Accessibility observer (window created in an unlocked app).
private func appLockAXCallback(_ observer: AXObserver, _ element: AXUIElement, _ notification: CFString, _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon = refcon else { return }
    let locker = Unmanaged<AppLocker>.fromOpaque(refcon).takeUnretainedValue()
    var pid: pid_t = 0
    AXUIElementGetPid(element, &pid)
    DispatchQueue.main.async { locker.windowCreated(pid: pid) }
}
