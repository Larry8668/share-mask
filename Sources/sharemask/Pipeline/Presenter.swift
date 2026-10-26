import AppKit
import CoreImage
import Metal
import QuartzCore

protocol FrameSink: AnyObject {
    func present(_ image: CIImage, completion: ((Double) -> Void)?)
}

/// Fullscreen borderless window on the virtual display backed by a CAMetalLayer. This window is
/// THE thing the user shares, so it must be capturable (`sharingType = .readOnly`).
///
/// The window is created on the main thread; `present` may be called from any thread (the layer
/// and Metal objects are thread-safe for this use) once `isReady`.
final class Presenter: FrameSink {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let context: CIContext
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private(set) var window: NSWindow?
    private let layer = CAMetalLayer()
    private let lock = NSLock()
    private var drawableSize = CGSize.zero
    private var screenObserver: NSObjectProtocol?
    private var attachRetries = 0
    let virtualDisplayID: CGDirectDisplayID
    private var black: CIImage { CIImage(color: CIColor(red: 0, green: 0, blue: 0)) }

    var isReady: Bool { lock.lock(); defer { lock.unlock() }; return window != nil && drawableSize.width > 0 }

    init(device: MTLDevice, context: CIContext, virtualDisplayID: CGDirectDisplayID) {
        self.device = device
        self.context = context
        self.virtualDisplayID = virtualDisplayID
        commandQueue = device.makeCommandQueue()!
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        // Core Image renders with compute + render passes; it needs a writable (non framebuffer-only) texture.
        layer.framebufferOnly = false
        layer.presentsWithTransaction = false
        layer.displaySyncEnabled = true
        layer.maximumDrawableCount = 3
        layer.colorspace = colorSpace
        layer.isOpaque = true
        layer.backgroundColor = NSColor.black.cgColor
    }

    /// Finds the virtual display's NSScreen (it may not be listed immediately after creation) and
    /// builds the window. Safe to call repeatedly; main thread only.

    func attachToScreen() -> Bool {
        if window != nil { return true }
        guard CGDisplayIsMain(virtualDisplayID) == 0, CGDisplayIsInMirrorSet(virtualDisplayID) == 0 else {
            // Right after creation the display briefly sits at (0,0) while macOS arranges it, which
            // reads as "main". Retry for a few seconds instead of giving up (giving up left the
            // proxy uncovered: its empty desktop was shared and windows landed on it).
            attachRetries += 1
            if attachRetries <= 40 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in _ = self?.attachToScreen() }
            } else {
                Log.error("refusing to present: virtual display \(virtualDisplayID) is still main or mirrored after 4 s (would cover the real screen)")
            }
            return false
        }
        guard let screen = NSScreen.screens.first(where: { $0.displayID == virtualDisplayID }) else {
            if screenObserver == nil {
                screenObserver = NotificationCenter.default.addObserver(
                    forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
                ) { [weak self] _ in _ = self?.attachToScreen() }
            }
            return false
        }
        let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
        w.level = .screenSaver
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        w.ignoresMouseEvents = true
        w.hidesOnDeactivate = false
        w.isOpaque = true
        w.backgroundColor = .black
        w.hasShadow = false
        w.isReleasedWhenClosed = false
        w.sharingType = .readOnly          // MUST be capturable: this is the shared surface
        w.title = "sharemask proxy display"
        w.isExcludedFromWindowsMenu = true
        w.animationBehavior = .none

        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        view.layer = layer
        view.layerContentsRedrawPolicy = .never
        w.contentView = view
        w.setFrame(screen.frame, display: true)
        w.orderFrontRegardless()
        window = w
        updateGeometry(screen: screen)
        Log.info("presenter attached to screen \(virtualDisplayID): \(Int(screen.frame.width))x\(Int(screen.frame.height)) pt @\(screen.backingScaleFactor)x")

        if screenObserver == nil {
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
            ) { [weak self] _ in self?.screenParametersChanged() }
        }
        return true
    }


    private func screenParametersChanged() {
        guard let w = window else { _ = attachToScreen(); return }
        guard let screen = NSScreen.screens.first(where: { $0.displayID == virtualDisplayID }) else {
            Log.warn("virtual display screen disappeared")
            return
        }
        if CGDisplayIsMain(virtualDisplayID) != 0 || CGDisplayIsInMirrorSet(virtualDisplayID) != 0 {
            Log.error("virtual display became main/mirrored; hiding presenter")
            w.orderOut(nil); window = nil
            return
        }
        if w.frame != screen.frame { w.setFrame(screen.frame, display: true) }
        updateGeometry(screen: screen)
        w.orderFrontRegardless()
    }


    private func updateGeometry(screen: NSScreen) {
        let scale = screen.backingScaleFactor
        let size = CGSize(width: screen.frame.width * scale, height: screen.frame.height * scale)
        lock.lock()
        layer.contentsScale = scale
        layer.frame = CGRect(origin: .zero, size: screen.frame.size)
        layer.drawableSize = size
        drawableSize = size
        lock.unlock()
    }


    func close() {
        if let o = screenObserver { NotificationCenter.default.removeObserver(o); screenObserver = nil }
        window?.orderOut(nil)
        window = nil
    }

    /// Current output size in pixels (what the viewer receives).
    var outputPixelSize: CGSize { lock.lock(); defer { lock.unlock() }; return drawableSize }

    /// Renders `image` scaled-to-fit (letterboxed on black) into the next drawable. `completion`
    /// receives GPU time in seconds when the command buffer finishes.
    func present(_ image: CIImage, completion: ((Double) -> Void)?) {
        lock.lock()
        let target = drawableSize
        lock.unlock()
        guard target.width > 0, let drawable = layer.nextDrawable(),
              let cb = commandQueue.makeCommandBuffer() else { return }
        let bounds = CGRect(origin: .zero, size: target)
        var out = image
        let ext = image.extent
        if ext.size != target {
            let s = min(target.width / ext.width, target.height / ext.height)
            let tx = (target.width - ext.width * s) / 2 - ext.minX * s
            let ty = (target.height - ext.height * s) / 2 - ext.minY * s
            out = image.transformed(by: CGAffineTransform(a: s, b: 0, c: 0, d: s, tx: tx, ty: ty))
                .composited(over: black.cropped(to: bounds))
        }
        context.render(out, to: drawable.texture, commandBuffer: cb, bounds: bounds, colorSpace: colorSpace)
        cb.present(drawable)
        if let completion = completion {
            cb.addCompletedHandler { buf in completion(buf.gpuEndTime - buf.gpuStartTime) }
        }
        cb.commit()
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}
