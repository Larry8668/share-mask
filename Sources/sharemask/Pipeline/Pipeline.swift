import AppKit
import CoreImage
import CoreMedia
import CoreVideo
import Metal
import CGSPrivate

/// Owns capture → redact → present. Single lifecycle object; all state changes on the main thread,
/// frame work on the capture queue.
final class Pipeline {
    enum State: Equatable {
        case idle, starting, running, stopped
        /// Auto mode: capture paused because no meeting/share is detected.
        case waitingForWatcher
        case error(String)
        var isRunning: Bool { self == .running }
    }

    /// The proxy display exists only while capture is wanted (on demand): outside meetings there is
    /// no hidden screen for other apps' windows to get lost on. See bringUpDisplay/tearDownDisplay.
    private(set) var virtualDisplay: VirtualDisplay?
    /// Proxy display spec, sized to the screen being shared.
    var displaySpec: VirtualDisplay.Spec {
        VirtualDisplay.Spec.forSource(pixelsWide: Int(source.geometry.pixelSize.width),
                                      pixelsHigh: Int(source.geometry.pixelSize.height))
    }
    /// Where the redacted picture goes.
    ///  - proxy: the hidden "sharemask" virtual display, shared in Zoom/Meet (default).
    ///  - mirror(tv): fullscreen on a physical TV/projector ("masked mirror": the room sees your
    ///    screen, masked).
    ///  - overlay(tv): capture the TV itself and draw only the patches on top of it ("masked
    ///    extend": you drag windows onto the TV as usual, masked parts come out pixellated).
    enum Output: Equatable {
        case proxy, mirror(CGDirectDisplayID), overlay(CGDirectDisplayID)
        var tv: CGDirectDisplayID? {
            switch self { case .proxy: return nil; case .mirror(let d), .overlay(let d): return d }
        }
    }
    private(set) var output: Output = .proxy
    /// The user's chosen laptop screen, kept while overlay mode captures the TV instead.
    private var userSource: SourceDisplay?
    /// Mirroring we switched off for a present mode; restored when it ends.
    private var unmirrored: [Mirroring.Pair] = []

    /// Screen whose stray windows / pointer must be kept off: proxy display or the mirrored TV.
    /// nil in overlay mode, where windows belong on the TV.
    var guardedDisplayID: CGDirectDisplayID? {
        switch output {
        case .proxy: return virtualDisplay?.displayID
        case .mirror(let tv): return presenter != nil ? tv : nil
        case .overlay: return nil
        }
    }

    /// Switch output mode. Main thread. Restarts capture if running.
    func setOutput(_ new: Output) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard new != output else { return }
        bumpGeneration()
        let wasActive = state == .running || state == .starting
        let cap = capture
        capture = nil
        tearDownDisplay()
        if case .overlay = output, let u = userSource { source = u; userSource = nil }
        output = new
        if case .overlay(let tv) = new { userSource = source; source = SourceDisplay.current(id: tv) }
        Log.info("output → \(new)")
        Task {
            await cap?.stop()
            await MainActor.run {
                if self.captureWanted, self.state != .running, self.state != .starting {
                    if self.state == .stopped || self.state == .idle { self.start() }
                    else { self.state = .starting; Task { await self.startCapture() } }
                } else if self.captureWanted, wasActive {
                    Task { await self.startCapture() }
                } else if !self.captureWanted, self.state == .running || self.state == .starting || wasActive {
                    self.enterWaitingForMeeting()
                }
            }
        }
    }

    /// Layouts (keyed by the set of real displays) we already tried to fix this session.
    private var placementAttempted: Set<String> = []
    /// Main thread. Fired after the display is created (true) or removed (false).
    var onDisplayChange: ((Bool) -> Void)?
    let tracker: WindowTracker
    let clock = FrameClock()
    let redactor: Redactor
    private var _presenter: Presenter?
    /// Read from the render queue too, so access goes through the lock.
    var presenter: Presenter? {
        get { lock.lock(); defer { lock.unlock() }; return _presenter }
        set { lock.lock(); _presenter = newValue; lock.unlock() }
    }
    private(set) var source: SourceDisplay
    private var capture: Capture?
    private let device: MTLDevice

    /// Called on the main thread whenever `state` changes.
    var onStateChange: ((State) -> Void)?
    private(set) var state: State = .idle {
        didSet { if oldValue != state { let s = state; DispatchQueue.main.async { self.onStateChange?(s) } } }
    }

    // Shared with the frame thread.
    private let lock = NSLock()
    private var _config = PresetConfig.empty
    private var _regionsEnabled = true
    private var _demoRegions: [PixelRegion] = []
    private var _options = ResolveOptions()
    private var lastOutput: CIImage?
    private var lastFrameAt: Double = 0
    private var watchdog: DispatchSourceTimer?
    /// Main thread. Fired once per stall (no frames for `stallTimeout` while running).
    var onStall: ((String) -> Void)?
    var stallTimeout: TimeInterval = 3
    private var stalled = false
    /// Main thread. Called with the last rendered output for the preview window (~10 Hz).
    var onPreview: ((CIImage) -> Void)?
    private var lastPreviewAt: Double = 0
    /// Debug/demo: when set, the first frame ≥ 2 s after capture start is saved as raw.png + proxy.png.
    var snapshotDirectory: URL?
    private var snapshotTaken = false
    private var captureStartedAt: Double = 0
    private var lastFrame: CVPixelBuffer?
    private var lastPTS = CMTime.zero
    private var lastRegions: [PixelRegion] = []
    private var rendering = false
    private var pending: (CVPixelBuffer, CMTime)?
    private let renderQueue = DispatchQueue(label: "sharemask.render", qos: .userInteractive)
    private var rerenderTimer: DispatchSourceTimer?
    private var restartAttempts = 0
    /// Bumped whenever the capture "plan" changes (output switch, source switch, stop, end share).
    /// Delayed retries and watchdog restarts carry the generation they were scheduled in and do
    /// nothing if it changed: a retry scheduled for a TV that has since gone must not start the
    /// laptop proxy (seen in every AirPlay session of 0.1.7).
    private(set) var generation = 0
    private func bumpGeneration() { generation &+= 1 }
    /// Last time macOS reconfigured displays (TV/AirPlay connect, resolution change…). Capture
    /// briefly stalls around these; the watchdog recovers silently instead of alarming the user.
    private(set) var lastReconfigAt: Double = 0
    var recentlyReconfigured: Bool { FrameClock.hostSeconds() - lastReconfigAt < 10 }
    /// Main thread. The shared screen disappeared and sharemask fell back to the main screen.
    var onSourceLost: (() -> Void)?
    private var idleTimer: DispatchSourceTimer?

    enum CaptureMode: String { case ask, auto, always, manual }
    /// `ask` (default) / `auto`: capture only while a meeting is detected (`meetingActive`, driven
    /// by MeetingCoordinator from the microphone signal + screen-watcher checks, with or without a
    /// prompt), so macOS's recording indicator is only on during calls. `always`: capture whenever
    /// started. `manual`: same as always (the user starts/stops from the menu).
    var captureMode: CaptureMode = .ask { didSet { if captureMode != oldValue { DispatchQueue.main.async { self.gateChanged() } } } }
    /// Set by the App's meeting detection. Only consulted in `.auto`.
    var meetingActive = false { didSet { if meetingActive != oldValue { DispatchQueue.main.async { self.gateChanged() } } } }
    /// Presenting to a TV always captures; otherwise follow the meeting gate.
    private var captureWanted: Bool { output != .proxy || (captureMode != .auto && captureMode != .ask) || meetingActive }
    static var watcherAPIAvailable: Bool { SMScreenWatcherAPIAvailable() }
    private var reconfigToken: CGDisplayReconfigurationCallBack?

    var config: PresetConfig {
        get { lock.lock(); defer { lock.unlock() }; return _config }
        set { lock.lock(); _config = newValue; lock.unlock(); requestRerender() }
    }
    var options: ResolveOptions {
        get { lock.lock(); defer { lock.unlock() }; return _options }
        set { lock.lock(); _options = newValue; lock.unlock(); requestRerender() }
    }
    var regionsEnabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _regionsEnabled }
        set { lock.lock(); _regionsEnabled = newValue; lock.unlock(); requestRerender() }
    }
    var panic: Bool {
        get { redactor.panic }
        set { redactor.panic = newValue; requestRerender() }
    }
    /// M1 hard-coded demo rect (`--demo`): pixel coords, top-left origin.
    func setDemoRegions(_ rects: [CGRect]) {
        let g = source.geometry
        let regions = rects.map { r -> PixelRegion in
            PixelRegion(rect: CGRect(x: r.minX, y: g.pixelSize.height - r.maxY, width: r.width, height: r.height),
                        mode: .pixellate(scale: 24))
        }
        lock.lock(); _demoRegions = regions; lock.unlock()
    }

    init(source: SourceDisplay, tracker: WindowTracker) {
        self.source = source
        self.tracker = tracker
        device = MTLCreateSystemDefaultDevice()!
        redactor = Redactor(device: device)
    }

    // MARK: On-demand proxy display

    /// Creates the virtual display + presenter window if they don't exist. Main thread; ~0.1–0.3 s.
    @discardableResult
    func bringUpDisplay() -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        if let tv = output.tv {
            if presenter != nil { return true }
            guard DisplayLayout.realDisplays(excluding: nil).contains(tv) else {
                state = .error("The presentation screen is no longer connected")
                return false
            }
            let pairs = Mirroring.mirrorPairs(involving: tv)
            if !pairs.isEmpty {
                guard Mirroring.unmirror(pairs) else { state = .error("Could not switch the TV to a separate display"); return false }
                unmirrored = pairs
            }
            let overlay: Bool
            if case .overlay = output { overlay = true } else { overlay = false }
            let pr = Presenter(device: device, context: redactor.context, virtualDisplayID: tv, transparent: overlay)
            presenter = pr
            _ = pr.attachToScreen()
            tracker.start()
            startRerenderTimer(); startWatchdog()
            Log.info("presenting on screen \(tv) (\(overlay ? "masked extend overlay" : "masked mirror"))")
            onDisplayChange?(true)
            return true
        }
        if virtualDisplay != nil { return true }
        if source.geometry.pixelSize.width <= 0 || !DisplayLayout.realDisplays(excluding: nil).contains(source.id) {
            source = SourceDisplay.current(id: CGMainDisplayID())
            onSourceLost?()
            Log.warn("shared screen unavailable at start → using main screen")
        }
        do {
            let vd = try VirtualDisplay.create(spec: displaySpec)
            virtualDisplay = vd
            let pr = Presenter(device: device, context: redactor.context, virtualDisplayID: vd.displayID)
            presenter = pr
            _ = pr.attachToScreen()
            tracker.start()   // window geometry is only needed while there's something to mask
            startRerenderTimer(); startWatchdog()
            Log.info("proxy display \(vd.displayID) created on demand (\(displaySpec.modeWidth)x\(displaySpec.modeHeight))")
            onDisplayChange?(true)
            return true
        } catch {
            Log.error("could not create proxy display: \(error)")
            state = .error("\(error)")
            return false
        }
    }

    /// Switch which real screen is shared. Takes effect immediately: a running capture restarts on
    /// the new screen with a correctly sized proxy display. Main thread.
    func setSource(_ id: CGDirectDisplayID) {
        let fresh = SourceDisplay.current(id: id)
        guard fresh != source else { return }
        bumpGeneration()
        Log.info("source screen → \(id) (\(Int(fresh.geometry.pixelSize.width))x\(Int(fresh.geometry.pixelSize.height)))")
        source = fresh
        guard state == .running || state == .starting else { return }
        let cap = capture
        capture = nil
        tearDownDisplay()
        Task {
            await cap?.stop()
            await startCapture()
        }
    }

    /// If macOS slotted the proxy display next to (or between) real screens, move it to a corner via
    /// the helper process and bring it back up; macOS then remembers the corner. Once per layout.
    private func ensureGoodPlacement() async {
        guard output == .proxy else { return }
        let (bad, key, origin, spec): (Bool, String, CGPoint, VirtualDisplay.Spec) = await MainActor.run {
            guard let vd = self.virtualDisplay else { return (false, "", .zero, self.displaySpec) }
            let realIDs = DisplayLayout.realDisplays(excluding: vd.displayID)
            let real = realIDs.map { CGDisplayBounds($0) }
            let key = realIDs.map { "\(CGDisplayVendorNumber($0)):\(CGDisplayModelNumber($0)):\(CGDisplaySerialNumber($0))" }.sorted().joined(separator: "|")
            let ok = DisplayLayout.isWellPlaced(vd.bounds, real: real)
            if !ok { Log.warn("proxy display at \(vd.bounds) shares an edge with a real screen \(real)") }
            return (!ok, key, DisplayLayout.cornerOrigin(real: real), self.displaySpec)
        }
        guard bad, !placementAttempted.contains(key) else { return }
        placementAttempted.insert(key)
        Log.info("placing proxy display at corner \(origin) via helper (one-time for this monitor setup)")
        await MainActor.run { self.tearDownDisplay() }
        for _ in 0..<100 {
            if !(await MainActor.run { self.removalPending }) { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let placed = await Task.detached { DisplayLayout.placeWithHelper(spec: spec, origin: origin) }.value
        try? await Task.sleep(nanoseconds: 300_000_000)   // let the helper's display go away
        let ok = await MainActor.run { self.bringUpDisplay() }
        if ok, let b = await MainActor.run(body: { self.virtualDisplay?.bounds }) {
            Log.info("proxy display after placement: \(b) (helper \(placed ? "ok" : "failed"))")
        }
    }

    /// Closes the presenter and removes the virtual display (macOS moves any windows on it back to
    /// the real display). Main thread.
    func tearDownDisplay() {
        dispatchPrecondition(condition: .onQueue(.main))
        tracker.stop()
        rerenderTimer?.cancel(); rerenderTimer = nil
        watchdog?.cancel(); watchdog = nil
        if output.tv != nil, presenter != nil {
            presenter?.close()
            presenter = nil
            let pairs = unmirrored
            unmirrored = []
            // Immediate (not deferred) so it also happens when the app is quitting.
            Mirroring.restore(pairs)
            onDisplayChange?(false)
        }
        guard let vd = virtualDisplay else { return }
        presenter?.close()
        presenter = nil
        virtualDisplay = nil
        removalPending = true
        vd.releaseAsync { [weak self] t in
            self?.removalPending = false
            if let t = t { Log.info("proxy display removed in \(Int(t * 1000)) ms") }
            else { Log.error("proxy display \(vd.displayID) still listed 5 s after release") }
            self?.onDisplayChange?(false)
        }
    }

    /// True between releasing the display and the window server dropping it. A new display with
    /// the same identity is not created until this clears.
    private(set) var removalPending = false

    /// Other apps' normal windows currently sitting on the proxy display. They are invisible to the
    /// user (covered by the presenter) and can block apps (e.g. a Finder alert stops shutdown).
    var strayWindows: [TrackedWindow] {
        guard let id = guardedDisplayID else { return [] }
        let b = CGDisplayBounds(id)
        return tracker.latest.windows.filter {
            $0.pid != getpid() && $0.layer == 0 && $0.alpha > 0
                && b.contains(CGPoint(x: $0.boundsPoints.midX, y: $0.boundsPoints.midY))
        }
    }

    // MARK: Lifecycle


    func start() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard state != .running, state != .starting else { return }
        state = .starting
        installReconfigurationCallback()
        // (re-render timer and watchdog start with the display, see bringUpDisplay)
        if captureWanted {
            Task { await startCapture() }
        } else {
            enterWaitingForMeeting()
        }
    }

    // MARK: Auto capture gate

    private func gateChanged() {
        switch state {
        case .waitingForWatcher where captureWanted:
            state = .starting
            Task { await startCapture() }
        case .running where !captureWanted, .starting where !captureWanted:
            let cap = capture
            capture = nil
            Task { await cap?.stop() }
            lock.lock(); lastFrame = nil; pending = nil; lock.unlock()
            enterWaitingForMeeting()
        default: break
        }
    }

    private func enterWaitingForMeeting() {
        state = .waitingForWatcher
        tearDownDisplay()
        Log.info("auto capture: waiting for a meeting (capture off, no proxy display)")
    }

    /// Only valid while capture is OFF (our own stream would count): is any process recording the
    /// screen right now? Used by the App to start capture when a share begins without a mic.
    var someoneElseIsCapturing: Bool {
        guard capture == nil, Pipeline.watcherAPIAvailable else { return false }
        return SMScreenWatcherPresent()
    }

    /// Pauses capture for ~0.5 s to check whether another process is capturing the screen.
    /// Completion on the main thread.
    func probeOtherWatchers(_ completion: @escaping (Bool) -> Void) {
        guard state == .running, let cap = capture, Pipeline.watcherAPIAvailable else { completion(false); return }
        capture = nil
        Task {
            await cap.stop()
            try? await Task.sleep(nanoseconds: 400_000_000)
            let watched = SMScreenWatcherPresent()
            await MainActor.run {
                if self.state == .running { Task { await self.startCapture() } }
                completion(watched)
            }
        }
    }

    // MARK: Watchdog (fail closed)

    /// While capture is supposed to be running, frames must keep arriving (SCK sends at least one
    /// every second even for a static screen). If none arrive for `stallTimeout`, the proxy is shown
    /// BLACK (never a stale frame), capture is restarted, and `onStall` fires so the UI can warn.
    private func startWatchdog() {
        watchdog?.cancel()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in self?.checkStall() }
        t.resume()
        watchdog = t
    }

    private func checkStall() {
        guard state == .running, let cap = capture else { stalled = false; return }
        lock.lock(); let last = lastFrameAt; lock.unlock()
        let age = FrameClock.hostSeconds() - last
        guard last > 0, age > stallTimeout, !stalled else { return }
        stalled = true
        let quiet = recentlyReconfigured
        Log.error("watchdog: no frames for \(Int(age)) s — blacking out proxy and restarting capture\(quiet ? " (displays just changed: recovering silently)" : "")")
        presentBlack()
        capture = nil
        let gen = generation
        Task {
            await cap.stop()
            let still = await MainActor.run { gen == self.generation && self.captureWanted }
            if still { await startCapture() } else { Log.info("watchdog restart dropped (plan changed)") }
            await MainActor.run { self.stalled = false }
        }
        // macOS pauses capture for a few seconds whenever displays reconfigure; that's expected and
        // recovers on its own, so only a stall with no display change is worth an alert.
        if !quiet { onStall?("Capture stalled for \(Int(age)) s; proxy blacked out and capture restarted") }
    }

    /// Emergency stop: stop capture, black the proxy, and remove the virtual display. Meeting apps
    /// end a share whose source display disappears, so this ends the share from their side too.
    /// "Start capturing" brings a fresh display back.
    func endShare() {
        Log.error("END SHARE requested: stopping capture and removing the virtual display")
        presentBlack()
        bumpGeneration()
        if captureMode == .always || captureMode == .manual {
            stop()          // nothing would restart it anyway; Start brings it back
            return
        }
        // Back to standby (NOT .stopped: a stopped pipeline ignores the meeting gate, so meetings
        // could never start capture again without a relaunch — the 0.1.7 "proxy died" bug).
        let cap = capture
        capture = nil
        Task { await cap?.stop() }
        lock.lock(); lastFrame = nil; pending = nil; lock.unlock()
        meetingActive = false
        if output != .proxy {
            presenter?.close(); presenter = nil
            Mirroring.restore(unmirrored); unmirrored = []
            if case .overlay = output, let u = userSource { source = u; userSource = nil }
            output = .proxy
            onDisplayChange?(false)
        }
        enterWaitingForMeeting()
    }

    /// Last rendered output (for the preview window).
    var lastRenderedImage: CIImage? { lock.lock(); defer { lock.unlock() }; return lastOutput }

    private func presentBlack() {
        let size = source.geometry.pixelSize
        let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: CGRect(origin: .zero, size: size))
        renderQueue.async { self.presenter?.present(black, completion: nil) }
    }

    private func startCapture() async {
        // Wait (≤ 5 s) for a previous display with the same identity to finish going away.
        for _ in 0..<100 {
            if !(await MainActor.run { self.removalPending }) { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let ok = await MainActor.run { self.bringUpDisplay() }
        guard ok else { return }
        await ensureGoodPlacement()
        guard await MainActor.run(body: { self.virtualDisplay != nil || self.presenter != nil }) else { return }
        let cap = Capture(displayID: source.id, pixelSize: source.geometry.pixelSize)
        cap.onStopped = { [weak self] error in
            guard let self = self else { return }
            DispatchQueue.main.async { self.handleStreamStopped(error) }
        }
        do {
            try await cap.start { [weak self] buffer, pts in self?.ingest(buffer, pts) }
            capture = cap
            restartAttempts = 0
            captureStartedAt = FrameClock.hostSeconds()
            DispatchQueue.main.async { self.state = .running }
        } catch {
            DispatchQueue.main.async {
                self.state = .error("\(error)")
                if case CaptureError.permissionDenied = error { self.schedulePermissionRetry() }
            }
            Log.error("capture start failed: \(error)")
        }
    }

    /// Screen Recording was denied (or not yet granted): poll the TCC preflight and start as soon
    /// as it flips. If the grant happened while we were running, SCK keeps failing until relaunch;
    /// that is reported through `needsRelaunch`.
    private(set) var permissionAttempts = 0
    var needsRelaunch: Bool { permissionAttempts >= 2 && CGPreflightScreenCaptureAccess() }

    private func schedulePermissionRetry() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self = self, self.isError, self.capture == nil else { return }
            guard CGPreflightScreenCaptureAccess() else { self.schedulePermissionRetry(); return }
            self.permissionAttempts += 1
            if self.permissionAttempts >= 2 {
                self.state = .error("Screen Recording was granted but macOS requires a relaunch (Relaunch sharemask in the menu)")
                return
            }
            self.state = .starting
            Task { await self.startCapture() }
        }
    }


    func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard state == .running || state == .starting || state == .waitingForWatcher || isError else { return }
        bumpGeneration()
        rerenderTimer?.cancel(); rerenderTimer = nil
        idleTimer?.cancel(); idleTimer = nil
        watchdog?.cancel(); watchdog = nil
        tracker.stop()
        let cap = capture
        capture = nil
        Task { await cap?.stop() }
        lock.lock(); lastFrame = nil; pending = nil; lock.unlock()
        tearDownDisplay()
        state = .stopped
    }

    var isError: Bool { if case .error = state { return true } else { return false } }


    private func handleStreamStopped(_ error: Error?) {
        guard state == .running else { return }
        capture = nil
        // The captured screen itself is gone (TV unplugged / AirPlay ended): don't retry here; the
        // screen-change handler stops presenting or falls back to the main screen.
        if !DisplayLayout.realDisplays(excluding: nil).contains(source.id) {
            Log.warn("capture stopped because screen \(source.id) disappeared; not retrying")
            state = .starting
            return
        }
        restartAttempts += 1
        let delay = min(10, pow(2.0, Double(restartAttempts - 1)))
        let gen = generation
        state = .error("capture stopped: \(error.map { "\($0)" } ?? "unknown"); retrying in \(Int(delay)) s")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self, gen == self.generation, self.capture == nil, self.isError, self.captureWanted else {
                Log.info("capture retry dropped (plan changed)")
                return
            }
            self.state = .starting
            Task { await self.startCapture() }
        }
    }

    /// Source display changed size (resolution/scaling): restart capture at the new size. The
    /// virtual display is never resized (invariant 2); the presenter letterboxes instead.

    func sourceDisplayChanged() {
        lastReconfigAt = FrameClock.hostSeconds()
        if output == .proxy, !DisplayLayout.realDisplays(excluding: nil).contains(source.id) {
            fallBackToMainScreen()
            return
        }
        let fresh = SourceDisplay.current(id: source.id)
        guard fresh != source else { return }
        guard fresh.geometry.pixelSize.width > 0 else { return }   // mid-reconfiguration; wait
        Log.info("source display changed: \(fresh.geometry.pixelSize) scale \(fresh.geometry.scale)")
        source = fresh
        guard state == .running, let cap = capture else { return }
        capture = nil
        Task {
            await cap.stop()
            await startCapture()
        }
    }

    /// The screen being shared vanished (e.g. an AirPlay TV chosen as the source): switch to the main
    /// screen instead of capturing nothing. 0.1.7 kept the vanished screen and then failed every
    /// start with "zero dimension" until relaunch.
    private func fallBackToMainScreen() {
        let main = SourceDisplay.current(id: CGMainDisplayID())
        Log.warn("shared screen \(source.id) disappeared → falling back to main screen \(main.id)")
        bumpGeneration()
        source = main
        onSourceLost?()
        guard state == .running || state == .starting || isError else { return }
        let cap = capture
        capture = nil
        tearDownDisplay()
        Task {
            await cap?.stop()
            let want = await MainActor.run { self.captureWanted }
            if want { await startCapture() } else { await MainActor.run { self.enterWaitingForMeeting() } }
        }
    }

    /// True if the virtual display no longer has the size we created it with (someone changed its
    /// mode in System Settings). After this, teardown requires relaunch.
    var virtualDisplayModeChanged: Bool {
        guard let virtualDisplay = virtualDisplay else { return false }
        let s = virtualDisplay.currentPixelSize
        return s.width > 0 && (Int(s.width) != Int(virtualDisplay.spec.modeWidth) || Int(s.height) != Int(virtualDisplay.spec.modeHeight))
    }

    private func installReconfigurationCallback() {
        guard reconfigToken == nil else { return }
        let callback: CGDisplayReconfigurationCallBack = { _, flags, userInfo in
            guard let userInfo = userInfo, flags.contains(.setModeFlag) || flags.contains(.desktopShapeChangedFlag)
                    || flags.contains(.removeFlag) || flags.contains(.addFlag) else { return }
            let pipeline = Unmanaged<Pipeline>.fromOpaque(userInfo).takeUnretainedValue()
            DispatchQueue.main.async { pipeline.sourceDisplayChanged() }
        }
        reconfigToken = callback
        CGDisplayRegisterReconfigurationCallback(callback, Unmanaged.passUnretained(self).toOpaque())
    }

    // MARK: Frame path

    /// Capture queue. Keeps at most one pending frame: if the renderer is busy the previous
    /// pending frame is replaced (dropped), never queued.
    private func ingest(_ buffer: CVPixelBuffer, _ pts: CMTime) {
        lock.lock()
        lastFrame = buffer
        lastPTS = pts
        lastFrameAt = FrameClock.hostSeconds()
        if pending != nil { clock.recordDropped() }
        pending = (buffer, pts)
        let shouldSchedule = !rendering
        if shouldSchedule { rendering = true }
        lock.unlock()
        if shouldSchedule { renderQueue.async { self.drain() } }
    }

    private func drain() {
        while true {
            lock.lock()
            guard let (buffer, pts) = pending else { rendering = false; lock.unlock(); return }
            pending = nil
            lock.unlock()
            render(buffer, pts: pts)
        }
    }

    private func render(_ buffer: CVPixelBuffer, pts: CMTime) {
        let entry = FrameClock.hostSeconds()
        let regions = currentRegions()
        lock.lock(); lastRegions = regions; lock.unlock()
        let overlay: Bool
        if case .overlay = output { overlay = true } else { overlay = false }
        let image = redactor.process(buffer, regions: regions, patchesOnly: overlay)
        presenter?.present(image) { [clock] gpu in clock.recordGPU(seconds: gpu) }
        if let dir = snapshotDirectory, !snapshotTaken, FrameClock.hostSeconds() - captureStartedAt > 2 {
            snapshotTaken = true
            let cs = CGColorSpace(name: CGColorSpace.sRGB)!
            let raw = CIImage(cvPixelBuffer: buffer)
            try? redactor.context.writePNGRepresentation(of: raw, to: dir.appendingPathComponent("raw.png"), format: .RGBA8, colorSpace: cs)
            try? redactor.context.writePNGRepresentation(of: image, to: dir.appendingPathComponent("proxy.png"), format: .RGBA8, colorSpace: cs)
            Log.info("snapshot written to \(dir.path) (\(regions.count) regions)")
        }
        clock.recordPresented(samplePTS: pts, callbackEntry: entry)
        lock.lock()
        lastOutput = image
        let now = FrameClock.hostSeconds()
        let preview = now - lastPreviewAt > 0.1 && onPreview != nil
        if preview { lastPreviewAt = now }
        lock.unlock()
        if preview { DispatchQueue.main.async { self.onPreview?(image) } }
    }

    private func currentRegions() -> [PixelRegion] {
        lock.lock()
        let cfg = _config, enabled = _regionsEnabled, demo = _demoRegions
        lock.unlock()
        guard enabled else { return [] }
        let snap = tracker.latest
        lock.lock(); let opts = _options; lock.unlock()
        var regions = RegionResolver.resolve(presets: cfg, windows: snap.windows, display: source.geometry,
                                             frontmostBundleID: snap.frontmostBundleID, ignorePIDs: [getpid()], options: opts)
        regions.append(contentsOf: demo)
        return regions
    }

    /// Re-present the last frame (panic/toggle/config changed, or window geometry moved while the
    /// screen content itself is static so SCK isn't delivering frames).
    func requestRerender() {
        lock.lock()
        guard let frame = lastFrame else { lock.unlock(); return }
        let pts = lastPTS
        lock.unlock()
        ingest(frame, pts)
    }

    private func startRerenderTimer() {
        rerenderTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: renderQueue)
        t.schedule(deadline: .now() + 0.1, repeating: 0.1)
        t.setEventHandler { [weak self] in
            guard let self = self else { return }
            let fresh = self.currentRegions()
            self.lock.lock(); let changed = fresh != self.lastRegions; self.lock.unlock()
            if changed { self.requestRerender() }
        }
        t.resume()
        rerenderTimer = t
    }
}
