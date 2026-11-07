import AppKit
import CoreImage
import Metal
import QuartzCore

/// "What others see": a window on the real display showing the masked output at full frame rate
/// (drawn with Metal from the same frames as the share).
///
/// It's capturable on purpose: screen recorders and screenshot tools can pick it under "Select
/// window" to record the masked screen without sharing it. sharemask's own capture leaves out its
/// windows, so it never shows up inside itself. It shows the masked picture only, so it's no leak
/// if a call shares the real screen. Recorders keep capturing a window while other windows cover
/// it, so with "Keep on top" off it can sit behind your work while you record it.
final class PreviewWindow: NSObject, FrameSink, NSWindowDelegate {
    private var window: NSWindow?
    private let layer = CAMetalLayer()
    private let label = NSTextField(labelWithString: "")
    private let pin = NSButton(checkboxWithTitle: "Keep on top", target: nil, action: nil)
    private let lock = NSLock()
    private var drawableSize = CGSize.zero
    private var device: MTLDevice?
    private var queue: MTLCommandQueue?
    private var context: CIContext?
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let pinKey = "previewKeepOnTop"
    /// Asked for a fresh frame when the window is resized (a static screen sends none).
    var onNeedsFrame: (() -> Void)?
    /// Set from the main thread when shown/hidden; read on the render queue.
    private var visible = false
    var isVisible: Bool { window?.isVisible ?? false }

    func toggle(sourceDisplayID: CGDirectDisplayID, device: MTLDevice, context: CIContext) {
        if isVisible { hide() } else { show(sourceDisplayID: sourceDisplayID, device: device, context: context) }
    }

    func show(sourceDisplayID: CGDirectDisplayID, device: MTLDevice, context: CIContext) {
        lock.lock()
        if self.device !== device { self.device = device; queue = device.makeCommandQueue(); layer.device = device }
        self.context = context
        lock.unlock()
        if window == nil { build(sourceDisplayID: sourceDisplayID) }
        window?.orderFrontRegardless()
        updateDrawableSize()
        lock.lock(); visible = true; lock.unlock()
        onNeedsFrame?()
    }

    func hide() {
        lock.lock(); visible = false; lock.unlock()
        window?.orderOut(nil)
    }

    private func build(sourceDisplayID: CGDirectDisplayID) {
        let b = CGDisplayBounds(sourceDisplayID)
        let aspect = b.width > 0 ? b.width / b.height : 16.0 / 10
        let videoW: CGFloat = 480, strip: CGFloat = 24
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: videoW, height: videoW / aspect + strip),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "What others see"
        w.sharingType = .readOnly   // recordable (see the type's comment)
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.fullScreenAuxiliary]
        w.hidesOnDeactivate = false
        w.delegate = self
        w.contentMinSize = NSSize(width: 240, height: 240 / aspect + strip)

        let content = NSView(frame: w.contentView!.bounds)
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.black.cgColor
        let video = NSView(frame: NSRect(x: 0, y: strip, width: content.bounds.width, height: content.bounds.height - strip))
        video.autoresizingMask = [.width, .height]
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = false
        layer.isOpaque = true
        layer.colorspace = colorSpace
        layer.backgroundColor = NSColor.black.cgColor
        layer.contentsGravity = .resizeAspect
        video.wantsLayer = true
        video.layer = layer
        video.layerContentsRedrawPolicy = .never
        content.addSubview(video)

        label.frame = NSRect(x: 8, y: 4, width: content.bounds.width - 130, height: 16)
        label.autoresizingMask = [.width]
        label.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        label.textColor = .secondaryLabelColor
        content.addSubview(label)
        pin.target = self; pin.action = #selector(pinChanged)
        pin.controlSize = .small; pin.font = .systemFont(ofSize: 10)
        pin.sizeToFit()
        pin.frame.origin = NSPoint(x: content.bounds.width - pin.frame.width - 8, y: 3)
        pin.autoresizingMask = [.minXMargin]
        pin.toolTip = "Off: the window can go behind your other windows. A screen recorder pointed at it keeps recording."
        let onTop = UserDefaults.standard.object(forKey: PreviewWindow.pinKey) as? Bool ?? true
        pin.state = onTop ? .on : .off
        content.addSubview(pin)
        w.contentView = content
        w.level = onTop ? .floating : .normal

        let primaryH = CGDisplayBounds(CGMainDisplayID()).height
        w.setFrameOrigin(NSPoint(x: b.maxX - w.frame.width - 20, y: primaryH - b.maxY + 60))
        w.setFrameAutosaveName("WhatOthersSee")
        window = w
    }

    @objc private func pinChanged() {
        let on = pin.state == .on
        UserDefaults.standard.set(on, forKey: PreviewWindow.pinKey)
        window?.level = on ? .floating : .normal
    }

    func windowDidResize(_ notification: Notification) { updateDrawableSize(); onNeedsFrame?() }
    func windowDidChangeBackingProperties(_ notification: Notification) { updateDrawableSize(); onNeedsFrame?() }
    func windowWillClose(_ notification: Notification) { lock.lock(); visible = false; lock.unlock() }

    private func updateDrawableSize() {
        guard let w = window, let v = layer.delegate as? NSView ?? w.contentView?.subviews.first else { return }
        let scale = w.backingScaleFactor
        let size = CGSize(width: max(1, v.bounds.width * scale), height: max(1, v.bounds.height * scale))
        lock.lock()
        layer.contentsScale = scale
        layer.drawableSize = size
        drawableSize = size
        lock.unlock()
    }

    /// Render queue. Scales the masked frame to fit (letterboxed on black).
    func present(_ image: CIImage, completion: ((Double) -> Void)?) {
        lock.lock()
        let target = drawableSize, on = visible, ctx = context, q = queue
        lock.unlock()
        guard on, target.width > 1, let ctx = ctx, let q = q,
              let drawable = layer.nextDrawable(), let cb = q.makeCommandBuffer() else { return }
        let bounds = CGRect(origin: .zero, size: target)
        let ext = image.extent
        let s = min(target.width / ext.width, target.height / ext.height)
        let tx = (target.width - ext.width * s) / 2 - ext.minX * s
        let ty = (target.height - ext.height * s) / 2 - ext.minY * s
        let out = image.transformed(by: CGAffineTransform(a: s, b: 0, c: 0, d: s, tx: tx, ty: ty))
            .composited(over: CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: bounds))
        ctx.render(out, to: drawable.texture, commandBuffer: cb, bounds: bounds, colorSpace: colorSpace)
        cb.present(drawable)
        cb.commit()
        lock.lock(); framesDrawn += 1; lock.unlock()
    }

    /// Test hook: frames drawn so far, the window's number and size.
    private var framesDrawn = 0
    func debugState() -> String {
        lock.lock(); let n = framesDrawn; let d = drawableSize; lock.unlock()
        return "frames=\(n) drawable=\(Int(d.width))x\(Int(d.height)) window=\(window?.windowNumber ?? 0) visible=\(isVisible) level=\(window?.level.rawValue ?? -1) sharing=\(window.map { "\($0.sharingType.rawValue)" } ?? "-")"
    }
    func setSizeForTesting(_ size: NSSize) { window?.setContentSize(size) }
    func setPinForTesting(_ on: Bool) { pin.state = on ? .on : .off; pinChanged() }

    func setStatus(_ status: String) { label.stringValue = status }
}
