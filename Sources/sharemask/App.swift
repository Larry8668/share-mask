import AppKit
import Carbon
import ServiceManagement

@main
enum Main {
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
    private let alerts = PromptPanel()
    private var options = ResolveOptions() { didSet { pipeline?.options = options; refreshMenu(); updateHUD() } }
    private var refreshTimer: Timer?
    private var permissionMissing = false
    private var pointerGuardEnabled = true
    private var hudEnabled = false

    init(launch: Launch, demo: Bool) {
        self.launch = launch
        self.demo = demo
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
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
            checkUpdates: { [weak self] in self?.updates.check(manual: true) },
            updateNow: { [weak self] in self?.updates.updateNow() },
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
        let p = Pipeline(displaySpec: launch.spec, source: launch.source, tracker: tracker)
        p.config = config.config
        p.captureMode = Pipeline.CaptureMode(rawValue: config.config.captureMode) ?? .ask
        let mc = MeetingCoordinator(pipeline: p)
        mc.mode = p.captureMode
        mc.calendarLookahead = config.config.calendarLookahead
        mc.onStatus = { [weak self] _ in self?.refreshMenu() }
        meetings = mc
        if demo { p.setDemoRegions([CGRect(x: 100, y: 100, width: 400, height: 300)]) }
        p.onStateChange = { [weak self] _ in self?.refreshMenu() }
        p.onStall = { [weak self] msg in self?.stallAlert(msg) }
        var snapDir = ProcessInfo.processInfo.environment["SHAREMASK_SNAPSHOT"]
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count { snapDir = CommandLine.arguments[i + 1] }
        if let dir = snapDir { p.snapshotDirectory = URL(fileURLWithPath: dir) }
        p.onPreview = { [weak self] img in
            guard let self = self, let p = self.pipeline else { return }
            self.preview.update(img, status: "\(p.panic ? "PANIC · " : "")\(self.options.allowlistMode ? "allowlist · " : "")\(p.clock.summary().fps.rounded()) fps")
        }
        pipeline = p
        pointerGuard = PointerGuard(virtualDisplayID: { [weak p] in p?.virtualDisplay?.displayID }, sourceDisplayID: launch.source.id)
        p.onDisplayChange = { [weak self] up in
            if !up { self?.promptedStrayIDs.removeAll(); self?.strayCount = 0 }
            self?.refreshMenu()
            if up { DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self?.checkStrays() } }
        }
        p.start()
        meetings?.start()

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.checkStrays(); self?.refreshMenu() }
        refreshMenu()
        if ProcessInfo.processInfo.environment["SHAREMASK_DUMP_WINDOWS"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.dumpWindows() }
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
        preview.toggle(sourceDisplayID: launch.source.id)
        if preview.isVisible, let img = pipeline?.lastRenderedImage { preview.update(img, status: "") }
        refreshMenu()
    }

    private func endShare(confirm: Bool) {
        guard let p = pipeline else { return }
        let go = { [weak self] in
            p.endShare()
            self?.alerts.show(title: "Share ended — proxy display removed", detail: "Your call app lost its source display. Relaunch sharemask to create it again.",
                              primary: "Relaunch", secondary: "Quit", timeout: 120,
                              onPrimary: { self?.relaunch() }, onSecondary: { NSApp.terminate(nil) })
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
                                "allowlist": hk.allowlist, "endShare": hk.endShare][name] ?? nil
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
        for (bundleID, app) in cfg.apps.sorted(by: { $0.key < $1.key }) {
            let name = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName ?? bundleID
            out.append(.init(title: name, key: bundleID, enabled: !options.disabled.contains(bundleID)))
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
        hud.show(on: launch.source.id)
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
        let url = Bundle.main.bundleURL
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; /usr/bin/open -n \"\(url.path)\""]
        try? task.run()
        NSApp.terminate(nil)
    }

    private func vdSafe(_ p: Pipeline) -> Bool { p.virtualDisplay?.isSafeToPresent ?? true }

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
        let home = CGDisplayBounds(launch.source.id).insetBy(dx: 40, dy: 60)
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
            let n = WindowEvacuator.evacuate(p.strayWindows, into: CGDisplayBounds(launch.source.id).insetBy(dx: 40, dy: 60))
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
