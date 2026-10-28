import AppKit
import ApplicationServices
import Carbon
import ServiceManagement
import ScreenCaptureKit

@main
enum Main {
    static var signalSources: [DispatchSourceSignal] = []
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        Log.start(role: args.first == "--probe" ? "probe" : "app")
        if args.first == "--probe" {
            exit(Probe.run(arguments: Array(args.dropFirst())))
        }
        if args.contains("--help") || args.contains("-h") {
            print("sharemask [--demo] [--probe ...]\n  --demo   add the M1 hard-coded pixellate rect (100,100,400,300)\n  --probe  CLI display diagnostics (see Probe.swift)")
            exit(0)
        }

        // Invariant 4: create the virtual display BEFORE anything enumerates displays
        // (NSApplication init, NSScreen, SCShareableContent). Reading the main display's mode
        // is the one unavoidable query; mode reporting for the virtual display is only needed
        // by the `--probe <id>` child process anyway.
        let launch = Launch.createVirtualDisplayEarly()

        // SIGTERM/SIGINT (pkill, the Homebrew update script, logout) → a normal quit, so the proxy
        // display is released and any TV mirroring we switched off is restored.
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { Log.info("signal \(sig)"); AppDelegate.shared?.handleTerminationSignal() ?? NSApp.terminate(nil) }
            src.resume()
            Main.signalSources.append(src)
        }
        // One sharemask at a time (the keep-alive agent and a manual launch could otherwise overlap).
        // Wait briefly for a quitting instance (relaunch / agent handover) before giving up.
        let me = getpid()
        func others() -> [NSRunningApplication] {
            NSRunningApplication.runningApplications(withBundleIdentifier: "dev.sharemask.app").filter { $0.processIdentifier != me && !$0.isTerminated }
        }
        var waited = 0.0
        while !others().isEmpty && waited < 3 { Thread.sleep(forTimeInterval: 0.2); waited += 0.2 }
        if let other = others().first {
            Log.info("another sharemask (pid \(other.processIdentifier)) is running; exiting")
            exit(0)
        }
        let app = NSApplication.shared
        let delegate = AppDelegate(launch: launch, demo: args.contains("--demo"))
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

/// Result of the pre-AppKit launch step.
struct Launch {
    var source: SourceDisplay
    var spec: VirtualDisplay.Spec
    var error: String?

    /// Verifies the private API and computes the proxy display spec. The display itself is created
    /// on demand by the pipeline when capture starts (so no hidden screen exists outside meetings).
    /// Consequence of creating it after AppKit enumerated displays: CGDisplayCopyDisplayMode returns
    /// NULL for it in this process. Nothing here needs it (bounds/pixels still work; --probe <id>
    /// runs as a child process).
    static func createVirtualDisplayEarly() -> Launch {
        let source = SourceDisplay.current()
        let spec = VirtualDisplay.Spec.forSource(pixelsWide: Int(source.geometry.pixelSize.width),
                                                 pixelsHigh: Int(source.geometry.pixelSize.height))
        do {
            try VirtualDisplay.checkAPI()
            return Launch(source: source, spec: spec, error: nil)
        } catch {
            return Launch(source: source, spec: spec, error: "\(error)")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var launch: Launch
    private let demo: Bool
    private var menuBar: MenuBar!
    private var pipeline: Pipeline?
    private let config = ConfigStore()
    private let hotkeys = Hotkeys()
    private let tracker = WindowTracker()
    private let hud = StatusHUD()
    private var pointerGuard: PointerGuard?
    private var picker: RegionPicker?
    private var meetings: MeetingCoordinator?
    private let preview = PreviewWindow()
    private let recorder = HotkeyRecorder()
    private let updates = UpdateChecker()
    private let keysPanel = KeysPanel()
    private var sessionKeysOn = false
    private var shownKeysThisLaunch = false
    private var knownExternals: Set<String> = []
    private let alerts = PromptPanel()
    private var options = ResolveOptions() { didSet { pipeline?.options = effectiveOptions; refreshMenu(); updateHUD() } }
    /// Session options plus App lock's apps masked whole-window in shares.
    private var effectiveOptions: ResolveOptions {
        var o = options
        if locker.isActive { o.forceMasked = Set(locker.config.apps) }
        return o
    }
    private var refreshTimer: Timer?
    private var permissionMissing = false
    private var pointerGuardEnabled = true
    private var hudEnabled = false

    init(launch: Launch, demo: Bool) {
        self.launch = launch
        self.demo = demo
    }

    static weak var shared: AppDelegate?
    let locker = AppLocker()
    /// Set after the user authenticated a quit, for shutdown/logout, and for our own relaunch/update.
    private var quitAllowed = false
    /// Last app in front other than sharemask (menu clicks don't change it for an accessory app, but be safe).
    private var previousFrontApp: NSRunningApplication? {
        let f = NSWorkspace.shared.frontmostApplication
        return f?.bundleIdentifier == Bundle.main.bundleIdentifier ? lastOtherFront : f
    }
    private var lastOtherFront: NSRunningApplication?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        // App lock first: a relaunch after a force-quit must re-hide locked apps immediately.
        locker.onChange = { [weak self] in self?.syncLockState() }
        locker.start()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            if let a = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, a.bundleIdentifier != Bundle.main.bundleIdentifier { self?.lastOtherFront = a }
        }
        if CommandLine.arguments.contains("--no-auto-touchid") { locker.card.autoPrompt = false }   // tests
        if handOverToKeepAliveIfNeeded() { return }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main) { [weak self] _ in
            self?.quitAllowed = true
            Log.info("logout/shutdown: quit allowed")
        }
        menuBar = MenuBar(actions: .init(
            toggleProxy: { [weak self] in self?.toggleProxy() },
            panic: { [weak self] in self?.togglePanic() },
            toggleRegions: { [weak self] in self?.toggleRegions() },
            pick: { [weak self] in self?.pickRegion() },
            pickFor: { [weak self] pid, bundleID in self?.pickRegion(pid: pid, bundleID: bundleID) },
            removeApp: { [weak self] bundleID in
                do { try self?.config.removeApp(bundleID: bundleID) } catch { self?.alert("Could not update presets.json", "\(error)") }
            },
            toggleMask: { [weak self] key in self?.toggleMask(key) },
            toggleAllowlist: { [weak self] in self?.toggleAllowlist() },
            togglePreview: { [weak self] in self?.togglePreview() },
            endShare: { [weak self] in self?.endShare(confirm: true) },
            dumpWindows: { [weak self] in self?.dumpWindows() },
            changeHotkey: { [weak self] name in self?.changeHotkey(name) },
            toggleLoginItem: { [weak self] in self?.toggleLoginItem() },
            openPresets: { NSWorkspace.shared.open(ConfigStore.fileURL) },
            openLogs: { NSWorkspace.shared.activateFileViewerSelecting([Log.fileURL]) },
            reloadPresets: { [weak self] in self?.config.reload() },
            togglePointerGuard: { [weak self] in self?.togglePointerGuard() },
            toggleHUD: { [weak self] in self?.toggleHUD() },
            openScreenRecordingSettings: {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
            },
            relaunch: { [weak self] in self?.relaunch() },
            bringBackStrays: { [weak self] in self?.bringBackStrays() },
            chooseScreen: { [weak self] id in self?.chooseScreen(id) },
            appLock: { [weak self] c, arg in self?.appLockCommand(c, arg) },
            present: { [weak self] tv, mirror in self?.present(tv: tv, mirror: mirror) },
            stopPresenting: { [weak self] in self?.stopPresenting() },
            showKeys: { [weak self] in self?.keysPanel.show(on: self?.launch.source.id ?? CGMainDisplayID()) },
            checkUpdates: { [weak self] in self?.updates.check(manual: true) },
            updateNow: { [weak self] in
                guard let self = self else { return }
                self.locker.authorize("settings", title: "Update sharemask", detail: "sharemask will quit and relaunch.") {
                    self.quitAllowed = true
                    self.updates.updateNow()
                }
            },
            copyUpdateCommand: { [weak self] in self?.updates.copyCommand() },
            openReleasePage: { [weak self] in self?.updates.openReleasePage() },
            toggleUpdateChecks: { [weak self] in self?.updates.enabled.toggle(); self?.refreshMenu() },
            removeDisplay: { [weak self] in self?.bringBackStrays(forceRemove: true) },
            quit: { NSApp.terminate(nil) }))
        menuBar.onMenuWillOpen = { [weak self] in self?.refreshMenu(); self?.refreshAppMenus() }

        updates.onChange = { [weak self] in self?.refreshMenu() }
        updates.start()
        config.onChange = { [weak self] cfg in self?.applyConfig(cfg) }
        config.onError = { [weak self] _ in self?.refreshMenu() }
        config.start()
        RunLoop.main.run(until: Date())   // deliver the initial onChange before building the pipeline

        if let err = launch.error {
            showFatal(err)
            refreshMenu()
            return
        }
        let p = Pipeline(source: savedSource() ?? launch.source, tracker: tracker)
        p.config = config.config
        p.options = effectiveOptions
        p.captureMode = Pipeline.CaptureMode(rawValue: config.config.captureMode) ?? .ask
        let mc = MeetingCoordinator(pipeline: p, prompt: alerts)
        mc.ignoreWatcher = { [weak p] in
            guard let p = p else { return false }
            return p.output != .proxy || p.recentlyReconfigured || AppDelegate.airPlayConnected
        }
        p.onSourceLost = { [weak self] in
            UserDefaults.standard.removeObject(forKey: "sourceScreen")
            Log.info("forgot remembered share screen (it disappeared)")
            self?.refreshMenu()
        }
        mc.mode = p.captureMode
        mc.calendarLookahead = config.config.calendarLookahead
        mc.onStatus = { [weak self] _ in self?.refreshMenu() }
        mc.screenChoices = { [weak self] in
            let screens = AppDelegate.shareableScreens()
            let sel = screens.firstIndex { $0.id == self?.pipeline?.source.id } ?? 0
            return (screens.map { $0.name }, sel)
        }
        mc.onChooseScreen = { [weak self] i in
            let screens = AppDelegate.shareableScreens()
            if i < screens.count { self?.chooseScreen(screens[i].id) }
        }
        meetings = mc
        if demo { p.setDemoRegions([CGRect(x: 100, y: 100, width: 400, height: 300)]) }
        p.onStateChange = { [weak self] _ in self?.refreshMenu(); self?.updateSessionKeys() }
        p.onStall = { [weak self] msg in self?.stallAlert(msg) }
        var snapDir = ProcessInfo.processInfo.environment["SHAREMASK_SNAPSHOT"]
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count { snapDir = CommandLine.arguments[i + 1] }
        if let dir = snapDir { p.snapshotDirectory = URL(fileURLWithPath: dir) }
        p.onPreview = { [weak self] img in
            guard let self = self, let p = self.pipeline else { return }
            self.preview.update(img, status: "\(p.panic ? "PANIC · " : "")\(self.options.allowlistMode ? "allowlist · " : "")\(p.clock.summary().fps.rounded()) fps")
        }
        pipeline = p
        pointerGuard = PointerGuard(virtualDisplayID: { [weak p] in p?.guardedDisplayID }, sourceDisplayID: { [weak p] in p?.source.id ?? CGMainDisplayID() })
        p.onDisplayChange = { [weak self] up in
            if !up { self?.promptedStrayIDs.removeAll(); self?.strayCount = 0 }
            self?.refreshMenu()
            if up { DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self?.checkStrays() } }
        }
        p.start()
        meetings?.start()

        knownExternals = Set(AppDelegate.externalScreens().map { AppDelegate.screenKey($0.id) })
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.screensChanged() }
        }
        runTestHooks()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.checkStrays(); self?.refreshMenu() }
        refreshMenu()
        if ProcessInfo.processInfo.environment["SHAREMASK_DUMP_WINDOWS"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.dumpWindows() }
        }
    }

    /// Quit guard: ⌘Q / menu Quit / AppleScript quit need authentication while App lock is on.
    /// Shutdown, restart and logout are never blocked.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard locker.isActive, locker.config.guardQuit, !quitAllowed else { return .terminateNow }
        Log.info("quit requested while App lock is on: asking for authentication")
        // Cancel now and quit again after authenticating. (.terminateLater runs the main thread in a
        // modal mode where queued work, timers and notifications stall — including App lock's own
        // enforcement and the Touch ID callback.)
        locker.card.show(subject: "quit", title: "Quit sharemask?", detail: "Locked apps stay unprotected until sharemask runs again.",
                         icon: NSImage(named: NSImage.applicationIconName)) { [weak self] ok in
            guard ok else { return }
            self?.quitAllowed = true
            NSApp.terminate(nil)
        }
        return .terminateCancel
    }

    /// SIGTERM/SIGINT. With App lock + keep-alive on, exit non-zero after cleanup so the agent
    /// relaunches sharemask (a `pkill` must not be a way around the lock); otherwise a normal quit.
    func handleTerminationSignal() {
        if locker.isActive && locker.config.keepAlive && KeepAlive.runningUnderAgent && !quitAllowed {
            Log.warn("terminated by signal while App lock is on: cleaning up; the keep-alive agent will relaunch")
            meetings?.stop()
            pipeline?.stop()
            exit(75)
        }
        if locker.isActive && locker.config.guardQuit && !quitAllowed {
            NSApp.terminate(nil)   // goes through the quit guard
        } else {
            quitAllowed = true
            NSApp.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        meetings?.stop()
        hotkeys.unregisterAll()
        pipeline?.stop()          // also removes the proxy display if it exists
    }

    // MARK: Config

    private func applyConfig(_ cfg: PresetConfig) {
        pipeline?.config = cfg
        let mode = Pipeline.CaptureMode(rawValue: cfg.captureMode) ?? .ask
        pipeline?.captureMode = mode
        meetings?.mode = mode
        meetings?.calendarLookahead = cfg.calendarLookahead
        hotkeys.set(.panic, combo: cfg.hotkeys.panic) { [weak self] in DispatchQueue.main.async { self?.togglePanic() } }
        hotkeys.set(.toggle, combo: cfg.hotkeys.toggle) { [weak self] in DispatchQueue.main.async { self?.toggleRegions() } }
        hotkeys.set(.pick, combo: cfg.hotkeys.pick) { [weak self] in DispatchQueue.main.async { self?.pickRegion() } }
        hotkeys.set(.reveal, combo: cfg.hotkeys.reveal,
                    handler: { [weak self] in DispatchQueue.main.async { self?.setReveal(true) } },
                    onRelease: { [weak self] in DispatchQueue.main.async { self?.setReveal(false) } })
        hotkeys.set(.allowlist, combo: cfg.hotkeys.allowlist) { [weak self] in DispatchQueue.main.async { self?.toggleAllowlist() } }
        hotkeys.set(.lockAll, combo: cfg.hotkeys.lockAll) { [weak self] in DispatchQueue.main.async { Log.info("hotkey: lock all"); self?.locker.lockAll(reason: "hotkey") } }
        hotkeys.set(.lockApp, combo: cfg.hotkeys.lockApp) { [weak self] in DispatchQueue.main.async { Log.info("hotkey: lock this app"); self?.locker.lockFrontmost() } }
        hotkeys.set(.endShare, combo: cfg.hotkeys.endShare) { [weak self] in DispatchQueue.main.async { self?.endShare(confirm: false) } }
        pointerGuardEnabled = cfg.pointerGuard
        hudEnabled = cfg.hud
        updatePointerGuard()
        updateHUD()
        refreshMenu()
    }

    // MARK: Actions

    private func toggleProxy() {
        guard let p = pipeline else { return }
        // While presenting to a TV, capture is held on by the output mode itself; "Stop" must end
        // the presentation (it used to leave it running).
        if p.output != .proxy { stopPresenting(); return }
        if p.captureMode == .ask || p.captureMode == .auto {
            // Start/Stop means "capture now" / "stop capturing"; the proxy display itself stays.
            if p.state.isRunning || p.state == .starting { meetings?.userStoppedManually() }
            else if p.state == .waitingForWatcher { meetings?.userStartedManually() }
            else { p.start(); meetings?.userStartedManually() }
        } else {
            if p.state.isRunning || p.state == .starting || p.state == .waitingForWatcher { p.stop() } else { p.start() }
        }
        updateHUD()
    }

    private func togglePanic() {
        guard let p = pipeline else { return }
        p.panic.toggle()           // read by the processor on the next frame; no debounce
        Log.info("panic \(p.panic ? "ON" : "off")")
        refreshMenu()
        updateHUD()
    }

    private func toggleRegions() {
        guard let p = pipeline else { return }
        p.regionsEnabled.toggle()
        Log.info("regions \(p.regionsEnabled ? "enabled" : "disabled")")
        refreshMenu()
        updateHUD()
    }

    private func pickRegion() {
        let front = NSWorkspace.shared.frontmostApplication
        pickRegion(pid: front?.processIdentifier ?? 0, bundleID: front?.bundleIdentifier ?? "")
    }

    private func pickRegion(pid: pid_t, bundleID: String) {
        guard picker == nil else { picker?.bringToFront(); return }
        let picker = RegionPicker(bundleID: bundleID, pid: pid,
                                  existing: config.config.apps[bundleID]?.regions ?? [])
        picker.onSave = { [weak self] bundleID, regions in
            guard let self = self else { return }
            do {
                try self.config.addRegions(bundleID: bundleID, regions: regions, replace: true)
                Log.info("saved \(regions.count) region(s) for \(bundleID)")
            } catch {
                self.alert("Could not save presets.json", "\(error)")
            }
        }
        picker.onClose = { [weak self] in self?.picker = nil }
        self.picker = picker
        picker.begin()
    }

    // MARK: Masks / reveal / allowlist / end share / preview

    /// Hold-to-reveal: while the hotkey is down, the frontmost app is shown unmasked.
    private func setReveal(_ on: Bool) {
        guard let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return }
        if on {
            options.revealed.insert(front)
            Log.info("reveal ON for \(front)")
        } else {
            options.revealed.removeAll()
            Log.info("reveal off")
        }
    }

    private func toggleMask(_ key: String) {
        if options.disabled.contains(key) { options.disabled.remove(key) } else { options.disabled.insert(key) }
        Log.info("mask \(key) \(options.disabled.contains(key) ? "disabled" : "enabled")")
    }

    private func toggleAllowlist() {
        options.allowlistMode.toggle()
        Log.info("allowlist mode \(options.allowlistMode ? "ON" : "off") (\(config.config.allowlist))")
        if options.allowlistMode && config.config.allowlist.isEmpty {
            alerts.show(title: "Allowlist mode is on, but the allowlist is empty", detail: "Everything is masked. Add bundle IDs to \"allowlist\" in presets.json (e.g. com.apple.Keynote).",
                        primary: "OK", secondary: "Open presets", timeout: 15, onPrimary: {}, onSecondary: { NSWorkspace.shared.open(ConfigStore.fileURL) })
        }
    }

    private func togglePreview() {
        preview.toggle(sourceDisplayID: pipeline?.source.id ?? launch.source.id)
        if preview.isVisible, let img = pipeline?.lastRenderedImage { preview.update(img, status: "") }
        refreshMenu()
    }

    private func endShare(confirm: Bool) {
        guard let p = pipeline else { return }
        let go = { [weak self] in
            let wasPresenting = p.output != .proxy
            self?.meetings?.userStoppedManually()   // don't re-prompt for the same meeting
            p.endShare()
            // Back in standby: capture starts again on the next meeting prompt or "Start capturing".
            self?.alerts.show(title: wasPresenting ? "Presenting stopped" : "Share ended — sharemask is in standby",
                              detail: wasPresenting ? "The TV no longer shows anything from sharemask."
                                                    : "The “sharemask” display was removed, so your call app stopped sharing it. Start capturing again any time from the menu.",
                              primary: "OK", secondary: "Start again", timeout: 10,
                              onPrimary: {}, onSecondary: { self?.toggleProxy() })
            self?.refreshMenu()
        }
        if confirm {
            alerts.show(title: "End the share now?", detail: "This removes the “sharemask” display, which ends the share in your call app.",
                        primary: "End share", secondary: "Cancel", timeout: 30, onPrimary: go, onSecondary: {})
        } else { go() }
    }

    private func stallAlert(_ message: String) {
        Log.error("ALERT: \(message)")
        menuBar.setIcon(.error)
        alerts.show(title: "sharemask: capture stalled", detail: message + ". Viewers see black until frames resume. End the share if it doesn't recover.",
                    primary: "End share now", secondary: "Keep going", timeout: 30,
                    onPrimary: { [weak self] in self?.endShare(confirm: false) }, onSecondary: {})
    }

    /// Login item via SMAppService (macOS 13+). Registers THIS bundle's path, so do it from the
    /// installed copy (/Applications), not from build/.
    private var launchAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    private func toggleLoginItem() {
        do {
            if launchAtLogin { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
            Log.info("launch at login \(launchAtLogin ? "enabled" : "disabled") for \(Bundle.main.bundlePath)")
        } catch {
            alert("Could not change login item", "\(error.localizedDescription)\n\nmacOS may require approval under System Settings → General → Login Items.")
        }
        refreshMenu()
    }

    private func changeHotkey(_ name: String) {
        let hk = config.config.hotkeys
        let current: String? = ["panic": hk.panic, "toggle": hk.toggle, "pick": hk.pick, "reveal": hk.reveal,
                                "allowlist": hk.allowlist, "endShare": hk.endShare,
                                "lockAll": hk.lockAll, "lockApp": hk.lockApp][name] ?? nil
        let title = MenuBar.hotkeyNames.first { $0.0 == name }?.1 ?? name
        recorder.record(actionName: title, current: current) { [weak self] combo in
            guard let self = self, let combo = combo else { return }
            do {
                try self.config.setHotkey(name, combo: combo)
                Log.info("hotkey \(name) → '\(combo)'")
            } catch { self.alert("Could not save presets.json", "\(error)") }
        }
    }

    private func dumpWindows() {
        var cache: [pid_t: String?] = [:]
        let list = WindowTracker.copyOnScreenWindows(bundleCache: &cache)
        Log.info("window dump (\(list.count) windows, front to back):")
        for w in list {
            let b = w.boundsPoints
            Log.info("  win \(w.windowID) pid=\(w.pid) \(w.bundleID ?? "?") layer=\(w.layer) alpha=\(w.alpha) sharing=\(w.sharingState) bounds=(\(Int(b.minX)),\(Int(b.minY)) \(Int(b.width))x\(Int(b.height))) title=\(w.title ?? "")")
        }
        NSWorkspace.shared.activateFileViewerSelecting([Log.fileURL])
    }

    private func masksEntries() -> [MenuBar.MaskEntry] {
        var out: [MenuBar.MaskEntry] = []
        let cfg = config.config
        for (n, (bundleID, app)) in cfg.apps.sorted(by: { $0.key < $1.key }).enumerated() {
            let name = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName ?? bundleID
            let shortcut = n < 9 ? "   ⌃⌥\(n + 1)" : ""
            out.append(.init(title: "\(n + 1). \(name)\(shortcut)", key: bundleID, enabled: !options.disabled.contains(bundleID)))
            for r in app.regions {
                let key = "\(bundleID)/\(r.name)"
                out.append(.init(title: r.name, key: key, enabled: !options.disabled.contains(key) && !options.disabled.contains(bundleID)))
            }
        }
        for rule in cfg.rules {
            out.append(.init(title: "Rule: \(rule.name)", key: "rule:\(rule.name)", enabled: !options.disabled.contains("rule:\(rule.name)")))
        }
        if cfg.maskNotifications {
            out.append(.init(title: "Notification banners", key: RegionResolver.notificationCenterBundleID,
                             enabled: !options.disabled.contains(RegionResolver.notificationCenterBundleID)))
        }
        return out
    }

    private func togglePointerGuard() { pointerGuardEnabled.toggle(); updatePointerGuard(); refreshMenu() }
    private func toggleHUD() { hudEnabled.toggle(); updateHUD(); refreshMenu() }

    private func updatePointerGuard() {
        guard let g = pointerGuard else { return }
        pointerGuardEnabled ? g.enable() : g.disable()
    }

    private func updateHUD() {
        guard hudEnabled, let p = pipeline else { hud.hide(); return }
        hud.show(on: pipeline?.source.id ?? launch.source.id)
        if p.panic { hud.set(.panic) }
        else if !p.state.isRunning { hud.set(.stopped) }
        else if !p.regionsEnabled { hud.set(.regionsOff) }
        else { hud.set(.safe) }
    }

    /// Running GUI apps (for "Pick regions for app") and apps present in presets.json.
    private func refreshAppMenus() {
        let me = Bundle.main.bundleIdentifier
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil && $0.bundleIdentifier != me && !$0.isTerminated }
            .map { MenuBar.RunningApp(name: $0.localizedName ?? $0.bundleIdentifier!, pid: $0.processIdentifier, bundleID: $0.bundleIdentifier!) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let configured = config.config.apps.map { (bundleID, app) -> MenuBar.ConfiguredApp in
            let proc = running.first { $0.bundleID == bundleID }
            let name = proc?.name ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
                .flatMap { Bundle(url: $0)?.infoDictionary?["CFBundleName"] as? String } ?? bundleID
            return MenuBar.ConfiguredApp(name: name, bundleID: bundleID, regionCount: app.regions.count, pid: proc?.pid)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        menuBar.updateApps(running: running, configured: configured)
        menuBar.updateMasks(masksEntries(), revealHotkey: config.config.hotkeys.reveal)
        menuBar.updateHotkeys(config.config.hotkeys)
    }

    // MARK: Menu refresh

    private func refreshMenu() {
        guard let menuBar = menuBar else { return }
        var status = "Proxy display: not created"
        var latency = ""
        var warning: String? = config.lastError
        var running = false, panic = false, regions = true
        permissionMissing = false

        if let err = launch.error {
            status = "Error"
            warning = err
            menuBar.setIcon(.error)
        } else if let p = pipeline {
            running = p.state.isRunning
            panic = p.panic
            regions = p.regionsEnabled
            let out = p.presenter?.outputPixelSize ?? .zero
            switch p.state {
            case .idle, .stopped: status = "Stopped — no proxy display"; menuBar.setIcon(.idle)
            case .starting: status = "Starting proxy display…"; menuBar.setIcon(.idle)
            case .waitingForWatcher: status = "Standby — \(meetings?.statusText ?? "no meeting")"; menuBar.setIcon(.idle)
            case .running:
                status = "Ready — share the “sharemask” display (\(Int(out.width))×\(Int(out.height)))"
                menuBar.setIcon(panic ? .panic : .active)
                latency = "Latency: \(p.clock.summary())"
            case .error(let e):
                status = "Error"; warning = e; menuBar.setIcon(.error)
                permissionMissing = e.contains("permission")
            }
            if !vdSafe(p) {
                warning = (warning.map { $0 + " · " } ?? "") + "virtual display is main or mirrored — un-mirror it in System Settings → Displays"
                menuBar.setIcon(.error)
            }
            if p.virtualDisplayModeChanged {
                warning = (warning.map { $0 + " · " } ?? "") + "virtual display mode was changed; teardown requires relaunch"
            }
            if p.panic && p.state.isRunning { status = "PANIC — whole feed redacted" }
            if options.allowlistMode && p.state.isRunning { status += " · ALLOWLIST" }
            if !options.revealed.isEmpty { status += " · REVEALING \(options.revealed.joined(separator: ","))" }
            if p.state.isRunning, let m = meetings { latency += "\n" + m.statusText }
        }

        menuBar.updateAppLock(appLockModel())
        menuBar.updatePresent(AppDelegate.externalScreens(), active: pipeline?.output ?? .proxy)
        menuBar.updateScreens(AppDelegate.shareableScreens(), selected: pipeline?.source.id ?? CGMainDisplayID())
        menuBar.updateVersion(current: UpdateChecker.currentVersion, status: updates.status,
                              checksEnabled: updates.enabled, homebrew: UpdateChecker.installedWithHomebrew)
        menuBar.update(status: status, latency: latency, warning: warning, running: running, panic: panic,
                       regionsEnabled: regions, pointerGuard: pointerGuardEnabled, hud: hudEnabled,
                       hotkeys: config.config.hotkeys, needsPermission: permissionMissing,
                       needsRelaunch: pipeline?.needsRelaunch ?? false, allowlistMode: options.allowlistMode,
                       previewShown: preview.isVisible, launchAtLogin: launchAtLogin,
                       strayCount: strayCount, displayExists: pipeline?.virtualDisplay != nil)
    }

    /// Quit and start a fresh instance (needed after Screen Recording is granted to a running app).
    private func relaunch() {
        quitAllowed = true
        let url = Bundle.main.bundleURL
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; /usr/bin/open -n \"\(url.path)\""]
        try? task.run()
        NSApp.terminate(nil)
    }

    private func vdSafe(_ p: Pipeline) -> Bool { p.virtualDisplay?.isSafeToPresent ?? true }

    // MARK: App lock

    private func syncLockState() {
        pipeline?.options = effectiveOptions
        refreshMenu()
    }

    /// If App lock wants the keep-alive agent and this instance wasn't started by it, start the
    /// agent's instance and exit (the new one waits for us to go). Returns true when exiting.
    private func handOverToKeepAliveIfNeeded() -> Bool {
        let want = locker.isActive && locker.config.keepAlive && !CommandLine.arguments.contains("--no-handover")   // dev/test only
        let exe = Bundle.main.executablePath
        if want && !KeepAlive.runningUnderAgent {
            if KeepAlive.installedExecutable != exe || !KeepAlive.isLoaded { KeepAlive.install() } else { KeepAlive.kickstart() }
            Log.info("handing over to the keep-alive agent")
            quitAllowed = true
            DispatchQueue.main.async { exit(0) }
            return true
        }
        if !want && FileManager.default.fileExists(atPath: KeepAlive.plistURL.path) {
            KeepAlive.uninstall(reopen: KeepAlive.runningUnderAgent)
            if KeepAlive.runningUnderAgent { quitAllowed = true; DispatchQueue.main.async { exit(0) }; return true }
        }
        return false
    }

    private func appLockModel() -> MenuBar.AppLockModel {
        let c = locker.config
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil && !AppLocker.unlockable.contains($0.bundleIdentifier!) }
        var ids = c.apps
        for r in running where !ids.contains(r.bundleIdentifier!) { ids.append(r.bundleIdentifier!) }
        let unlockedNow = Set(locker.unlockedApps)
        let apps = ids.map { b -> (bundleID: String, name: String, locked: Bool, unlockedNow: Bool) in
            let name = running.first { $0.bundleIdentifier == b }?.localizedName
                ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: b).flatMap { Bundle(url: $0)?.infoDictionary?["CFBundleName"] as? String } ?? b
            return (b, name, c.apps.contains(b), unlockedNow.contains(b))
        }.sorted { ($0.locked ? 0 : 1, $0.name.lowercased()) < ($1.locked ? 0 : 1, $1.name.lowercased()) }
        return .init(enabled: c.enabled, apps: apps, relockMinutes: c.relockMinutes, relockOnSleep: c.relockOnSleep,
                     guardQuit: c.guardQuit, keepAlive: c.keepAlive, hasPassword: c.passwordHash != nil)
    }

    /// Every change except turning App lock ON and "lock all" needs authentication while active.
    private func appLockCommand(_ c: String, _ arg: String?) {
        let change: (@escaping () -> Void) -> Void = { [weak self] action in
            self?.locker.authorize("settings", title: "Change App lock settings", detail: "Confirm it's you.", then: action)
        }
        switch c {
        case "lockAll": locker.lockAll(reason: "menu")
        case "lockApp":
            // Menu clicks make sharemask frontmost; lock the app that was in front before.
            if let prev = previousFrontApp, prev.bundleIdentifier != Bundle.main.bundleIdentifier { prev.activate(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.locker.lockFrontmost() } }
        case "toggle":
            if locker.config.enabled {
                change { [weak self] in self?.locker.update { $0.enabled = false }; self?.afterKeepAliveSettingChange() }
            } else {
                locker.update { $0.enabled = true }
                if locker.config.apps.isEmpty {
                    alerts.show(title: "App lock is on", detail: "Tick the apps to lock under App lock ▸ Apps to lock.",
                                primary: "OK", secondary: "Later", timeout: 8, onPrimary: {}, onSecondary: {})
                }
                afterKeepAliveSettingChange()
            }
        case "app":
            guard let b = arg else { return }
            if locker.config.apps.contains(b) {
                change { [weak self] in self?.locker.update { $0.apps.removeAll { $0 == b } } }
            } else {
                // Adding a lock never needs auth (it only makes things stricter).
                locker.update { $0.apps.append(b); if !$0.enabled { $0.enabled = true } }
                afterKeepAliveSettingChange()
            }
        case "relock":
            let m = Int(arg ?? "5") ?? 5
            if m < locker.config.relockMinutes || !locker.isActive { locker.update { $0.relockMinutes = m } }
            else { change { [weak self] in self?.locker.update { $0.relockMinutes = m } } }
        case "sleep":
            if !locker.config.relockOnSleep { locker.update { $0.relockOnSleep = true } }
            else { change { [weak self] in self?.locker.update { $0.relockOnSleep = false } } }
        case "guardQuit":
            if !locker.config.guardQuit { locker.update { $0.guardQuit = true } }
            else { change { [weak self] in self?.locker.update { $0.guardQuit = false } } }
        case "keepAlive":
            if !locker.config.keepAlive { locker.update { $0.keepAlive = true }; afterKeepAliveSettingChange() }
            else { change { [weak self] in self?.locker.update { $0.keepAlive = false }; self?.afterKeepAliveSettingChange() } }
        case "password": change { [weak self] in self?.askNewPassword() }
        case "removePassword": change { [weak self] in self?.locker.update { $0.passwordHash = nil } }
        default: break
        }
    }

    private func afterKeepAliveSettingChange() {
        let want = locker.isActive && locker.config.keepAlive
        let installed = FileManager.default.fileExists(atPath: KeepAlive.plistURL.path)
        guard want != installed || (want && !KeepAlive.runningUnderAgent) else { return }
        quitAllowed = true
        _ = handOverToKeepAliveIfNeeded()
        quitAllowed = false
    }

    private func askNewPassword() {
        let a = NSAlert()
        a.messageText = "Set a sharemask password"
        a.informativeText = "Used on lock cards instead of Touch ID (your Mac login password keeps working too). At least 4 characters."
        let f1 = NSSecureTextField(frame: NSRect(x: 0, y: 30, width: 240, height: 24)); f1.placeholderString = "New password"
        let f2 = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24)); f2.placeholderString = "Repeat"
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 54)); box.addSubview(f1); box.addSubview(f2)
        a.accessoryView = box
        a.addButton(withTitle: "Set"); a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = f1
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        guard f1.stringValue.count >= 4, f1.stringValue == f2.stringValue else {
            alert("Password not set", "The two entries must match and be at least 4 characters.")
            return
        }
        setLockPassword(f1.stringValue)
    }

    private func setLockPassword(_ pw: String) {
        locker.update { $0.passwordHash = AppLockStore.hash(pw) }
    }

    // MARK: Which screen to share

    /// Physical screens (sharemask's own proxy excluded), main first.
    static func realScreens() -> [(id: CGDirectDisplayID, name: String)] {
        let ids = DisplayLayout.realDisplays(excluding: nil).sorted { CGDisplayIsMain($0) > CGDisplayIsMain($1) }
        return ids.map { id in
            let name = NSScreen.screens.first { $0.displayID == id }?.localizedName
                ?? (CGDisplayIsBuiltin(id) != 0 ? "Built-in display" : (CGDisplayIsInMirrorSet(id) != 0 ? "External display (mirroring)" : "External display"))
            return (id, name)
        }
    }

    /// AirPlay receivers show up as screens named "<device> (AirPlay)". They're presentation
    /// targets, never a screen you'd mirror into a call.
    static func isAirPlay(_ id: CGDirectDisplayID) -> Bool {
        (NSScreen.screens.first { $0.displayID == id }?.localizedName ?? "").range(of: "AirPlay", options: .caseInsensitive) != nil
    }
    static var airPlayConnected: Bool { DisplayLayout.realDisplays(excluding: nil).contains(where: isAirPlay) }

    /// Screens offered as "the screen to share": real screens minus AirPlay receivers.
    static func shareableScreens() -> [(id: CGDirectDisplayID, name: String)] {
        realScreens().filter { !isAirPlay($0.id) }
    }

    /// Display IDs change across reconnects; remember the screen by vendor/model/serial.
    private static func screenKey(_ id: CGDirectDisplayID) -> String {
        "\(CGDisplayVendorNumber(id)):\(CGDisplayModelNumber(id)):\(CGDisplaySerialNumber(id))"
    }

    private func savedSource() -> SourceDisplay? {
        guard let key = UserDefaults.standard.string(forKey: "sourceScreen"),
              let id = AppDelegate.shareableScreens().first(where: { AppDelegate.screenKey($0.id) == key })?.id else { return nil }
        return SourceDisplay.current(id: id)
    }

    private func chooseScreen(_ id: CGDirectDisplayID) {
        UserDefaults.standard.set(AppDelegate.screenKey(id), forKey: "sourceScreen")
        pipeline?.setSource(id)
        refreshMenu()
    }

    // MARK: Presenting to a TV / projector (HDMI, AirPlay, Sidecar)

    /// Physical screens other than the built-in one (and other than sharemask's proxy).
    /// Present targets: real screens other than the built-in one. (With the lid closed and only an
    /// external connected there is nothing to present to: that screen is the one being mirrored.)
    static func externalScreens() -> [(id: CGDirectDisplayID, name: String)] {
        let all = realScreens()
        guard all.count > 1 else { return [] }
        return all.filter { CGDisplayIsBuiltin($0.id) == 0 }
    }

    private func present(tv: CGDirectDisplayID, mirror: Bool) {
        guard let p = pipeline else { return }
        UserDefaults.standard.set(mirror ? "mirror" : "extend", forKey: "presentMode")
        Log.info("present to \(tv): \(mirror ? "masked mirror" : "masked extend")")
        p.setOutput(mirror ? .mirror(tv) : .overlay(tv))
        if p.state == .stopped || p.state == .idle { p.start() }
        refreshMenu()
    }

    private func stopPresenting() {
        guard let p = pipeline, p.output != .proxy else { return }
        Log.info("stop presenting")
        p.setOutput(.proxy)
        refreshMenu()
    }

    /// A new external screen appeared → offer to present to it. A presented screen vanished → stop.
    private func screensChanged() {
        let externals = AppDelegate.externalScreens()
        if let p = pipeline, let tv = p.output.tv, !externals.contains(where: { $0.id == tv }) {
            Log.warn("presentation screen \(tv) disconnected")
            stopPresenting()
        }
        let keys = Set(externals.map { AppDelegate.screenKey($0.id) })
        let fresh = externals.filter { !knownExternals.contains(AppDelegate.screenKey($0.id)) }
        knownExternals = keys
        refreshMenu()
        guard let tv = fresh.first, pipeline?.output == .proxy else { return }
        offerPresent(to: tv)
    }

    private func offerPresent(to tv: (id: CGDirectDisplayID, name: String)) {
        let mirrored = Mirroring.isMirrored(tv.id)
        let last = UserDefaults.standard.string(forKey: "presentMode") == "mirror" ? 1 : 0
        Log.info("external screen connected: \(tv.name) (\(tv.id)) mirrored=\(mirrored)")
        alerts.show(title: "\(tv.name) connected — present with masks?",
                    detail: mirrored ? "It's mirroring right now; sharemask will switch it to a separate display and back when you stop."
                                     : "Extend: drag windows onto it, masked parts come out pixellated. Mirror: it shows your screen, masked.",
                    primary: "Present", secondary: "Not now", timeout: 60,
                    choices: ["Masked extend — drag windows onto it", "Masked mirror — it shows your screen"], selected: last,
                    onChoice: { [weak self] i in self?.pendingPresentMirror = (i == 1) },
                    onPrimary: { [weak self] in self?.present(tv: tv.id, mirror: self?.pendingPresentMirror ?? (last == 1)) },
                    onSecondary: {})
    }
    private var pendingPresentMirror: Bool?

    // MARK: Session keys (simple ⌃⌥ combos, only while capturing/presenting)

    private func updateSessionKeys() {
        let want = pipeline?.state.isRunning ?? false
        guard want != sessionKeysOn else { return }
        sessionKeysOn = want
        if want {
            let main = DispatchQueue.main
            hotkeys.set(.sPanic, combo: "ctrl+alt+B") { [weak self] in main.async { self?.togglePanic() } }
            hotkeys.set(.sToggle, combo: "ctrl+alt+M") { [weak self] in main.async { self?.toggleRegions() } }
            hotkeys.set(.sReveal, combo: "ctrl+alt+R",
                        handler: { [weak self] in main.async { self?.setReveal(true) } },
                        onRelease: { [weak self] in main.async { self?.setReveal(false) } })
            hotkeys.set(.sAllowlist, combo: "ctrl+alt+A") { [weak self] in main.async { self?.toggleAllowlist() } }
            hotkeys.set(.sEnd, combo: "ctrl+alt+X") { [weak self] in main.async { self?.endSessionKey() } }
            hotkeys.set(.sAllOn, combo: "ctrl+alt+0") { [weak self] in main.async { self?.reenableAllMasks() } }
            hotkeys.set(.sKeys, combo: "ctrl+alt+K") { [weak self] in main.async { self?.keysPanel.show(on: self?.launch.source.id ?? CGMainDisplayID()) } }
            let numbered: [Hotkeys.Action] = [.sMask1, .sMask2, .sMask3, .sMask4, .sMask5, .sMask6, .sMask7, .sMask8, .sMask9]
            for (i, a) in numbered.enumerated() {
                hotkeys.set(a, combo: "ctrl+alt+\(i + 1)") { [weak self] in main.async { self?.toggleNumberedMask(i) } }
            }
            Log.info("session keys on (⌃⌥B/M/R/A/X/0-9/K)")
            if !shownKeysThisLaunch {
                shownKeysThisLaunch = true
                keysPanel.show(on: launch.source.id)
            }
        } else {
            Hotkeys.Action.session.forEach { hotkeys.unregister($0) }
            Log.info("session keys off")
        }
    }

    /// Apps in the order shown (numbered) in the Masks menu.
    private var numberedApps: [String] { config.config.apps.keys.sorted() }

    private func toggleNumberedMask(_ i: Int) {
        let apps = numberedApps
        guard i < apps.count else { Log.info("⌃⌥\(i + 1): no app #\(i + 1)"); return }
        toggleMask(apps[i])
    }

    private func reenableAllMasks() {
        options.disabled.removeAll()
        options.revealed.removeAll()
        Log.info("all masks re-enabled")
    }

    private func endSessionKey() {
        if pipeline?.output != .proxy { stopPresenting() } else { endShare(confirm: false) }
    }

    // MARK: Test hooks (development only; flags never set in normal use)

    private func runTestHooks() {
        let args = CommandLine.arguments
        func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        if let mode = value("--present") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let tv = AppDelegate.externalScreens().first else { Log.error("test: no external screen"); return }
                self?.present(tv: tv.id, mirror: mode == "mirror")
            }
        }
        if let dir = value("--snapshot-screen") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in self?.snapshotOutputScreen(to: dir) }
        }
        // --script "3:start,8:end,12:start,16:end" — timed actions for reproducing bug reports.
        if let script = value("--script") ?? ProcessInfo.processInfo.environment["SHAREMASK_TEST_SCRIPT"] {
            for step in script.split(separator: ",") {
                let parts = step.split(separator: ":")
                guard parts.count == 2, let t = Double(parts[0]) else { continue }
                let action = String(parts[1])
                DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in self?.scriptAction(action) }
            }
        }
        if args.contains("--selftest-keys") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.selftestKeys() }
        }
    }

    /// App used by App lock tests (Activity Monitor: opens straight to a window and stays in the
    /// Dock when its window is closed — like WhatsApp).
    static let testAppID = "com.apple.ActivityMonitor"
    static let testAppPath = "/System/Applications/Utilities/Activity Monitor.app"

    private func scriptAction(_ action: String) {
        guard let p = pipeline else { return }
        Log.info("script: \(action)")
        switch action {
        case "start": toggleProxy()                       // same as the menu's Start capturing
        case "stop": toggleProxy()
        case "end": endShare(confirm: false)              // same as End share now / ⌃⌥X
        case "present-extend", "present-mirror":
            if let tv = AppDelegate.externalScreens().first { present(tv: tv.id, mirror: action == "present-mirror") }
        case "stop-present": stopPresenting()
        case "lock-setup":       // test: throwaway password, lock TextEdit, App lock on
            setLockPassword("test1234")
            locker.update { $0.enabled = true; $0.apps = [AppDelegate.testAppID]; $0.relockMinutes = 60; $0.keepAlive = false }
        case "lock-setup-keepalive":
            setLockPassword("test1234")
            locker.update { $0.enabled = true; $0.apps = [AppDelegate.testAppID]; $0.relockMinutes = 0; $0.keepAlive = true }
            afterKeepAliveSettingChange()
        case "lock-teardown":
            locker.update { $0 = AppLockConfig() }
            afterKeepAliveSettingChange()
            if CommandLine.arguments.contains("--lock-test-store") { AppLockStore.deleteTestEntry() }
        case "open-textedit": NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: AppDelegate.testAppPath), configuration: .init())
        case "wrong-password": locker.card.submitForTesting("nope")
        case "minimize", "close-windows":
            guard let te = NSRunningApplication.runningApplications(withBundleIdentifier: AppDelegate.testAppID).first else { break }
            var v: CFTypeRef?
            AXUIElementCopyAttributeValue(AXUIElementCreateApplication(te.processIdentifier), kAXWindowsAttribute as CFString, &v)
            for w in (v as? [AXUIElement]) ?? [] {
                if action == "minimize" {
                    AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
                } else {
                    var btn: CFTypeRef?
                    if AXUIElementCopyAttributeValue(w, kAXCloseButtonAttribute as CFString, &btn) == .success, let b = btn {
                        AXUIElementPerformAction(b as! AXUIElement, kAXPressAction as CFString)
                    }
                }
            }
        case "quit-textedit": NSRunningApplication.runningApplications(withBundleIdentifier: AppDelegate.testAppID).first?.terminate()
        case "lock-app":
            NSRunningApplication.runningApplications(withBundleIdentifier: AppDelegate.testAppID).first?.activate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.locker.lockFrontmost() }
        case "password": locker.card.submitForTesting("test1234")
        case "lockall": locker.lockAll(reason: "script")
        case "quit": NSApp.terminate(nil)
        case "source-tv":
            if let tv = AppDelegate.realScreens().first(where: { CGDisplayIsBuiltin($0.id) == 0 }) { chooseScreen(tv.id) }
        default: break
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            Log.info("script screens: all=\(AppDelegate.realScreens().map { $0.name }) shareable=\(AppDelegate.shareableScreens().map { $0.name }) airplay=\(AppDelegate.airPlayConnected) ignoreWatcher=\(p.output != .proxy || p.recentlyReconfigured || AppDelegate.airPlayConnected)")
            let te = NSRunningApplication.runningApplications(withBundleIdentifier: AppDelegate.testAppID).first
            var wins = -1
            if let te = te { var v: CFTypeRef?; AXUIElementCopyAttributeValue(AXUIElementCreateApplication(te.processIdentifier), kAXWindowsAttribute as CFString, &v); wins = (v as? [AXUIElement])?.count ?? 0 }
            Log.info("script textedit windows (AX, incl. minimized): \(wins)")
            Log.info("script lock: active=\(self.locker.isActive) apps=\(self.locker.config.apps) unlocked=\(self.locker.unlockedApps) card=\(self.locker.card.subject ?? "none") textedit=\(te.map { $0.isHidden ? "hidden" : "visible" } ?? "not running") agent=\(KeepAlive.runningUnderAgent)")
            Log.info("script state after \(action): state=\(p.state) output=\(p.output) source=\(p.source.id) proxy=\(p.virtualDisplay.map { "\($0.displayID)" } ?? "none") presenter=\(p.presenter != nil) saved=\(UserDefaults.standard.string(forKey: "sourceScreen") ?? "none")")
        }
    }

    /// Screenshot of the presentation screen as the room sees it (our windows included).
    private func snapshotOutputScreen(to dir: String) {
        guard let tv = pipeline?.output.tv else { Log.error("test: not presenting"); return }
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let d = content.displays.first(where: { $0.displayID == tv }) else { return }
                let cfg = SCStreamConfiguration()
                cfg.width = d.width; cfg.height = d.height; cfg.showsCursor = false
                let img = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: d, excludingWindows: []), configuration: cfg)
                let url = URL(fileURLWithPath: dir).appendingPathComponent("screen.png")
                if let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) {
                    CGImageDestinationAddImage(dest, img, nil); CGImageDestinationFinalize(dest)
                }
                Log.info("test: wrote \(url.path)")
            } catch { Log.error("test: snapshot failed \(error)") }
        }
    }

    /// Posts the session key combos as real keyboard events (needs Accessibility) and logs state.
    private func selftestKeys() {
        guard WindowEvacuator.isTrusted else { Log.error("selftest: needs Accessibility"); return }
        let src = CGEventSource(stateID: .hidSystemState)
        func press(_ key: CGKeyCode, hold: TimeInterval = 0.05, then: @escaping () -> Void) {
            let flags: CGEventFlags = [.maskControl, .maskAlternate]
            let down = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true); down?.flags = flags
            let up = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false); up?.flags = flags
            down?.post(tap: .cghidEventTap)
            DispatchQueue.main.asyncAfter(deadline: .now() + hold) {
                up?.post(tap: .cghidEventTap)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: then)
            }
        }
        let p = pipeline!
        func log(_ what: String) { Log.info("selftest \(what): panic=\(p.panic) regions=\(p.regionsEnabled) allowlist=\(options.allowlistMode) disabled=\(options.disabled.sorted()) revealed=\(options.revealed.sorted())") }
        log("start")
        press(11) { log("after ⌃⌥B"); press(11) { log("after ⌃⌥B again")
        press(46) { log("after ⌃⌥M"); press(46) { log("after ⌃⌥M again")
        press(18) { log("after ⌃⌥1"); press(29) { log("after ⌃⌥0")
        press(0) { log("after ⌃⌥A"); press(0) { log("after ⌃⌥A again")
        holdR() } } } } } } } }
        func holdR() {
            let flags: CGEventFlags = [.maskControl, .maskAlternate]
            let down = CGEvent(keyboardEventSource: src, virtualKey: 15, keyDown: true); down?.flags = flags
            let up = CGEvent(keyboardEventSource: src, virtualKey: 15, keyDown: false); up?.flags = flags
            down?.post(tap: .cghidEventTap)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                log("while holding ⌃⌥R")
                up?.post(tap: .cghidEventTap)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { log("after releasing ⌃⌥R") }
            }
        }
    }

    // MARK: Stray windows on the proxy display

    private var strayCount = 0
    private var promptedStrayIDs: Set<CGWindowID> = []

    /// Runs every second (and right after the display appears). Auto-moves stray windows home when
    /// Accessibility is granted; otherwise surfaces them in the menu and asks once per window.
    private func checkStrays() {
        guard let p = pipeline else { return }
        let strays = p.strayWindows
        if strays.count != strayCount {
            Log.info("stray windows on proxy display: \(strayCount) → \(strays.count) (display \(p.virtualDisplay.map { "\($0.displayID)" } ?? "none"), tracker \(p.tracker.latest.windows.count) windows, AX \(WindowEvacuator.isTrusted))")
        }
        strayCount = strays.count
        guard !strays.isEmpty else { return }
        let home = CGDisplayBounds(pipeline?.source.id ?? launch.source.id).insetBy(dx: 40, dy: 60)
        if WindowEvacuator.isTrusted {
            WindowEvacuator.evacuate(strays, into: home)
            return
        }
        let fresh = strays.filter { !promptedStrayIDs.contains($0.windowID) }
        guard !fresh.isEmpty, !alerts.isVisible else { return }
        fresh.forEach { promptedStrayIDs.insert($0.windowID) }
        let names = Set(strays.compactMap { w in w.bundleID.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0).first?.localizedName } })
        Log.warn("stray windows on proxy display: \(strays.map { "\($0.bundleID ?? "?")#\($0.windowID)" })")
        alerts.show(title: "\(names.sorted().joined(separator: ", ")) opened a window on the hidden sharemask display",
                    detail: "You can't see it there. Allow sharemask to move such windows back automatically (Accessibility), or remove the display now (ends a share in progress).",
                    primary: "Allow auto-move", secondary: "Remove display", timeout: 60,
                    onPrimary: { WindowEvacuator.requestTrust() },
                    onSecondary: { [weak self] in self?.bringBackStrays(forceRemove: true) })
    }

    /// Menu action. Moves windows home if allowed; otherwise removes the display (macOS then moves
    /// them home itself). Capture resumes later through the normal meeting flow / Start.
    private func bringBackStrays(forceRemove: Bool = false) {
        guard let p = pipeline else { return }
        if !forceRemove && WindowEvacuator.isTrusted {
            let n = WindowEvacuator.evacuate(p.strayWindows, into: CGDisplayBounds(pipeline?.source.id ?? launch.source.id).insetBy(dx: 40, dy: 60))
            Log.info("bring back: moved \(n) window(s)")
        } else {
            Log.info("bring back: removing proxy display so macOS returns its windows")
            if p.state.isRunning || p.state == .starting { meetings?.userStoppedManually() }
            p.tearDownDisplay()
        }
        refreshMenu()
    }

    // MARK: Alerts

    private func showFatal(_ message: String) {
        let a = NSAlert()
        a.alertStyle = .critical
        a.messageText = "sharemask cannot create its virtual display"
        a.informativeText = message + "\n\nThe private CoreGraphics virtual display API this build relies on is unavailable or failed. sharemask will stay in the menu bar but cannot start the proxy display."
        a.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}
