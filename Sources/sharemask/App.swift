import AppKit
import Carbon

@main
enum Main {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
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
    var virtualDisplay: VirtualDisplay?
    var error: String?

    static func createVirtualDisplayEarly() -> Launch {
        let source = SourceDisplay.current()
        do {
            try VirtualDisplay.checkAPI()
        } catch {
            return Launch(source: source, virtualDisplay: nil, error: "\(error)")
        }
        let spec = VirtualDisplay.Spec.forSource(pixelsWide: Int(source.geometry.pixelSize.width),
                                                 pixelsHigh: Int(source.geometry.pixelSize.height))
        do {
            let vd = try VirtualDisplay.create(spec: spec)
            Log.info("virtual display \(vd.displayID) created: \(spec.modeWidth)x\(spec.modeHeight) serial \(spec.serial)")
            return Launch(source: source, virtualDisplay: vd, error: nil)
        } catch {
            return Launch(source: source, virtualDisplay: nil, error: "\(error)")
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
            openPresets: { NSWorkspace.shared.open(ConfigStore.fileURL) },
            reloadPresets: { [weak self] in self?.config.reload() },
            togglePointerGuard: { [weak self] in self?.togglePointerGuard() },
            toggleHUD: { [weak self] in self?.toggleHUD() },
            openScreenRecordingSettings: {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
            },
            relaunch: { [weak self] in self?.relaunch() },
            quit: { NSApp.terminate(nil) }))
        menuBar.onMenuWillOpen = { [weak self] in self?.refreshMenu() }

        config.onChange = { [weak self] cfg in self?.applyConfig(cfg) }
        config.onError = { [weak self] _ in self?.refreshMenu() }
        config.start()

        if let err = launch.error {
            showFatal(err)
            refreshMenu()
            return
        }
        guard let vd = launch.virtualDisplay else { return }
        let p = Pipeline(virtualDisplay: vd, source: launch.source, tracker: tracker)
        p.config = config.config
        p.idleMode = config.config.idleMode
        if demo { p.setDemoRegions([CGRect(x: 100, y: 100, width: 400, height: 300)]) }
        p.onStateChange = { [weak self] _ in self?.refreshMenu() }
        pipeline = p
        pointerGuard = PointerGuard(virtualDisplayID: vd.displayID, sourceDisplayID: launch.source.id)
        p.start()

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refreshMenu() }
        refreshMenu()
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeys.unregisterAll()
        pipeline?.stop()
        if let vd = launch.virtualDisplay {
            do {
                let t = try vd.release()
                Log.info("virtual display released in \(Int(t * 1000)) ms")
            } catch { Log.warn("\(error)") }
        }
    }

    // MARK: Config

    private func applyConfig(_ cfg: PresetConfig) {
        pipeline?.config = cfg
        pipeline?.idleMode = cfg.idleMode
        hotkeys.set(.panic, combo: cfg.hotkeys.panic) { [weak self] in DispatchQueue.main.async { self?.togglePanic() } }
        hotkeys.set(.toggle, combo: cfg.hotkeys.toggle) { [weak self] in DispatchQueue.main.async { self?.toggleRegions() } }
        hotkeys.set(.pick, combo: cfg.hotkeys.pick) { [weak self] in DispatchQueue.main.async { self?.pickRegion() } }
        pointerGuardEnabled = cfg.pointerGuard
        hudEnabled = cfg.hud
        updatePointerGuard()
        updateHUD()
        refreshMenu()
    }

    // MARK: Actions

    private func toggleProxy() {
        guard let p = pipeline else { return }
        if p.state.isRunning || p.state == .starting || p.state == .waitingForWatcher { p.stop() } else { p.start() }
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
        guard picker == nil else { picker?.bringToFront(); return }
        let front = NSWorkspace.shared.frontmostApplication
        let bundleID = front?.bundleIdentifier ?? ""
        let picker = RegionPicker(bundleID: bundleID, pid: front?.processIdentifier ?? 0,
                                  existing: config.config.apps[bundleID]?.regions ?? [])
        picker.onSave = { [weak self] bundleID, regions, replace in
            guard let self = self else { return }
            do {
                try self.config.addRegions(bundleID: bundleID, regions: regions, replace: replace)
                Log.info("saved \(regions.count) region(s) for \(bundleID)")
            } catch {
                self.alert("Could not save presets.json", "\(error)")
            }
        }
        picker.onClose = { [weak self] in self?.picker = nil }
        self.picker = picker
        picker.begin()
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
            let out = p.presenter.outputPixelSize
            switch p.state {
            case .idle, .stopped: status = "Proxy display: created, capture stopped"; menuBar.setIcon(.idle)
            case .starting: status = "Proxy display: starting…"; menuBar.setIcon(.idle)
            case .waitingForWatcher: status = "Idle: waiting for a screen share to begin"; menuBar.setIcon(.idle)
            case .running:
                status = "Sharing-safe: share display “sharemask” (\(Int(out.width))×\(Int(out.height)))"
                menuBar.setIcon(panic ? .panic : .active)
                latency = "Latency: \(p.clock.summary())"
            case .error(let e):
                status = "Error"; warning = e; menuBar.setIcon(.error)
                permissionMissing = e.contains("permission")
            }
            if p.virtualDisplayModeChanged {
                warning = (warning.map { $0 + " · " } ?? "") + "virtual display mode was changed; teardown requires relaunch"
            }
            if p.panic && p.state.isRunning { status = "PANIC — whole feed redacted" }
        }

        menuBar.update(status: status, latency: latency, warning: warning, running: running, panic: panic,
                       regionsEnabled: regions, pointerGuard: pointerGuardEnabled, hud: hudEnabled,
                       hotkeys: config.config.hotkeys, needsPermission: permissionMissing,
                       needsRelaunch: pipeline?.needsRelaunch ?? false)
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
