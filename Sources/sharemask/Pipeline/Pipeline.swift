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
        /// Idle mode: capture paused because no process is recording the screen.
        case waitingForWatcher
        case error(String)
        var isRunning: Bool { self == .running }
    }

    let virtualDisplay: VirtualDisplay
    let tracker: WindowTracker
    let clock = FrameClock()
    let redactor: Redactor
    let presenter: Presenter
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
    private var lastFrame: CVPixelBuffer?
    private var lastPTS = CMTime.zero
    private var lastRegions: [PixelRegion] = []
    private var rendering = false
    private var pending: (CVPixelBuffer, CMTime)?
    private let renderQueue = DispatchQueue(label: "sharemask.render", qos: .userInteractive)
    private var rerenderTimer: DispatchSourceTimer?
    private var restartAttempts = 0
    private var idleTimer: DispatchSourceTimer?
    /// Idle mode (optional, off by default): only capture while some process has a screen-capture
    /// session open (Zoom/Meet/...), detected with the private CGSIsScreenWatcherPresent(). Our own
    /// stream counts as a watcher, so the check is made with capture paused: at start, and then
    /// every `idleCheckInterval` seconds (a ~0.5 s freeze of the proxy feed each time).
    var idleMode = false { didSet { if idleMode != oldValue { DispatchQueue.main.async { self.idleModeChanged() } } } }
    var idleCheckInterval: TimeInterval = 120
    static var idleModeSupported: Bool { SMScreenWatcherAPIAvailable() }
    private var reconfigToken: CGDisplayReconfigurationCallBack?

    var config: PresetConfig {
        get { lock.lock(); defer { lock.unlock() }; return _config }
        set { lock.lock(); _config = newValue; lock.unlock(); requestRerender() }
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

    init(virtualDisplay: VirtualDisplay, source: SourceDisplay, tracker: WindowTracker) {
        self.virtualDisplay = virtualDisplay
        self.source = source
        self.tracker = tracker
        device = MTLCreateSystemDefaultDevice()!
        redactor = Redactor(device: device)
        presenter = Presenter(device: device, context: redactor.context, virtualDisplayID: virtualDisplay.displayID)
    }

    // MARK: Lifecycle


    func start() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard state != .running, state != .starting else { return }
        state = .starting
        _ = presenter.attachToScreen()
        tracker.start()
        installReconfigurationCallback()
        startRerenderTimer()
        if idleMode, Pipeline.idleModeSupported, !SMScreenWatcherPresent() {
            enterWaitingForWatcher()
        } else {
            Task { await startCapture() }
        }
    }

    // MARK: Idle mode

    private func idleModeChanged() {
        idleTimer?.cancel(); idleTimer = nil
        switch state {
        case .waitingForWatcher where !idleMode:
            state = .starting
            Task { await startCapture() }
        case .running where idleMode:
            scheduleIdleCheck()
        default: break
        }
    }

    private func enterWaitingForWatcher() {
        state = .waitingForWatcher
        presentBlack()
        idleTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in
            guard let self = self, self.state == .waitingForWatcher else { return }
            if !self.idleMode || SMScreenWatcherPresent() {
                self.idleTimer?.cancel(); self.idleTimer = nil
                self.state = .starting
                Task { await self.startCapture() }
            }
        }
        t.resume()
        idleTimer = t
    }

    private func scheduleIdleCheck() {
        guard idleMode, Pipeline.idleModeSupported else { return }
        idleTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + idleCheckInterval)
        t.setEventHandler { [weak self] in self?.runIdleCheck() }
        t.resume()
        idleTimer = t
    }

    private func runIdleCheck() {
        guard idleMode, state == .running, let cap = capture else { return }
        capture = nil
        Task {
            await cap.stop()
            try? await Task.sleep(nanoseconds: 400_000_000)
            let watched = SMScreenWatcherPresent()
            await MainActor.run {
                guard self.state == .running else { return }
                if watched {
                    Task { await self.startCapture() }
                } else {
                    Log.info("idle mode: nobody is capturing the screen, pausing")
                    self.enterWaitingForWatcher()
                }
            }
        }
    }

    private func presentBlack() {
        let size = source.geometry.pixelSize
        let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: CGRect(origin: .zero, size: size))
        renderQueue.async { self.presenter.present(black, completion: nil) }
    }

    private func startCapture() async {
        let cap = Capture(displayID: source.id, pixelSize: source.geometry.pixelSize)
        cap.onStopped = { [weak self] error in
            guard let self = self else { return }
            DispatchQueue.main.async { self.handleStreamStopped(error) }
        }
        do {
            try await cap.start { [weak self] buffer, pts in self?.ingest(buffer, pts) }
            capture = cap
            restartAttempts = 0
            DispatchQueue.main.async { self.state = .running; self.scheduleIdleCheck() }
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
        rerenderTimer?.cancel(); rerenderTimer = nil
        idleTimer?.cancel(); idleTimer = nil
        tracker.stop()
        let cap = capture
        capture = nil
        Task { await cap?.stop() }
        lock.lock(); lastFrame = nil; pending = nil; lock.unlock()
        state = .stopped
    }

    var isError: Bool { if case .error = state { return true } else { return false } }


    private func handleStreamStopped(_ error: Error?) {
        guard state == .running else { return }
        capture = nil
        restartAttempts += 1
        let delay = min(10, pow(2.0, Double(restartAttempts - 1)))
        state = .error("capture stopped: \(error.map { "\($0)" } ?? "unknown"); retrying in \(Int(delay)) s")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self, self.capture == nil, self.isError else { return }
            self.state = .starting
            Task { await self.startCapture() }
        }
    }

    /// Source display changed size (resolution/scaling): restart capture at the new size. The
    /// virtual display is never resized (invariant 2); the presenter letterboxes instead.

    func sourceDisplayChanged() {
        let fresh = SourceDisplay.current(id: source.id)
        guard fresh != source else { return }
        Log.info("source display changed: \(fresh.geometry.pixelSize) scale \(fresh.geometry.scale)")
        source = fresh
        guard state == .running, let cap = capture else { return }
        capture = nil
        Task {
            await cap.stop()
            await startCapture()
        }
    }

    /// True if the virtual display no longer has the size we created it with (someone changed its
    /// mode in System Settings). After this, teardown requires relaunch.
    var virtualDisplayModeChanged: Bool {
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
        let image = redactor.process(buffer, regions: regions)
        presenter.present(image) { [clock] gpu in clock.recordGPU(seconds: gpu) }
        clock.recordPresented(samplePTS: pts, callbackEntry: entry)
    }

    private func currentRegions() -> [PixelRegion] {
        lock.lock()
        let cfg = _config, enabled = _regionsEnabled, demo = _demoRegions
        lock.unlock()
        guard enabled else { return [] }
        let snap = tracker.latest
        var regions = RegionResolver.resolve(presets: cfg, windows: snap.windows, display: source.geometry,
                                             frontmostBundleID: snap.frontmostBundleID, ignorePIDs: [getpid()])
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
