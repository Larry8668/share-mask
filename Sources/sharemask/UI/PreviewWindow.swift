import AppKit
import CoreImage
import Metal
import QuartzCore

/// "What others see": a window on the real display showing the masked output (drawn with Metal
/// from the same frames as the share). Its bottom bar has:
/// - **Show**: the entire screen, or only one app (everything else hidden). Applies to the share too.
/// - **Hide the rest with**: Blur or Black.
/// - **Preview / Full quality**: Preview draws about 10 frames a second and can't be captured.
///   Full quality draws every frame and can be picked by recorders, screenshot tools and calls
///   under "Select window". It costs more: its own redraws make macOS deliver a new frame each
///   time, about a quarter of a CPU core while it's on. sharemask's own capture leaves out its
///   windows, so it never shows up inside itself.
/// - **Follow me / Stay here**: on every desktop and above everything, or a normal window on one
///   desktop. Recorders keep capturing a window while other windows cover it.
final class PreviewWindow: NSObject, FrameSink, NSWindowDelegate, NSMenuDelegate {
    private var window: NSWindow?
    private let layer = CAMetalLayer()
    private let label = NSTextField(labelWithString: "")
    private let showPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let stylePicker = NSSegmentedControl(labels: ["Blur", "Black"], trackingMode: .selectOne, target: nil, action: nil)
    private let qualityPicker = NSSegmentedControl(labels: ["Preview", "Full quality"], trackingMode: .selectOne, target: nil, action: nil)
    private let placePicker = NSSegmentedControl(labels: ["Follow me", "Stay here"], trackingMode: .selectOne, target: nil, action: nil)
    private let lock = NSLock()
    private var drawableSize = CGSize.zero
    private var device: MTLDevice?
    private var queue: MTLCommandQueue?
    private var context: CIContext?
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let followKey = "previewFollow"
    static let barHeight: CGFloat = 60

    /// Asked for a fresh frame when the window is resized (a static screen sends none).
    var onNeedsFrame: (() -> Void)?
    /// "Show": nil = entire screen, else a bundle ID.
    var onShowOnly: ((String?) -> Void)?
    /// "Hide the rest with": "blur" or "black".
    var onHiddenStyle: ((String) -> Void)?

    // Read on the render queue (under `lock`).
    private var visible = false
    private var fullQuality = false
    private var lastDrawn: TimeInterval = 0
    private var framesDrawn = 0
    private var showOnly: String?
    private var hiddenStyle = "blur"

    var isVisible: Bool { window?.isVisible ?? false }
    var isFullQuality: Bool { lock.lock(); defer { lock.unlock() }; return fullQuality }

    func toggle(sourceDisplayID: CGDirectDisplayID, device: MTLDevice, context: CIContext) {
        if isVisible { hide() } else { show(sourceDisplayID: sourceDisplayID, device: device, context: context) }
    }

    func show(sourceDisplayID: CGDirectDisplayID, device: MTLDevice, context: CIContext) {
        lock.lock()
        if self.device !== device { self.device = device; queue = device.makeCommandQueue(); layer.device = device }
        self.context = context
        lock.unlock()
        if window == nil { build(sourceDisplayID: sourceDisplayID) }
        setFullQuality(false)   // always opens in Preview: the costly mode is never left on by accident
        window?.orderFrontRegardless()
        updateDrawableSize()
        lock.lock(); visible = true; lock.unlock()
        onNeedsFrame?()
    }

    func hide() {
        lock.lock(); visible = false; lock.unlock()
        window?.orderOut(nil)
    }

    /// Keeps the bar in step with choices made elsewhere (the app window).
    func sync(showOnly: String?, hiddenStyle: String) {
        lock.lock(); self.showOnly = showOnly; self.hiddenStyle = hiddenStyle; lock.unlock()
        guard window != nil else { return }
        rebuildShowMenu()
        stylePicker.selectedSegment = hiddenStyle == "black" ? 1 : 0
        stylePicker.isEnabled = showOnly != nil
    }

    private func build(sourceDisplayID: CGDirectDisplayID) {
        let b = CGDisplayBounds(sourceDisplayID)
        let aspect = b.width > 0 ? b.width / b.height : 16.0 / 10
        let videoW: CGFloat = 520, bar = PreviewWindow.barHeight
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: videoW, height: videoW / aspect + bar),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "What others see"
        w.isReleasedWhenClosed = false
        w.hidesOnDeactivate = false
        w.delegate = self
        w.contentMinSize = NSSize(width: 440, height: 440 / aspect + bar)

        let content = NSView(frame: w.contentView!.bounds)
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        let video = NSView(frame: NSRect(x: 0, y: bar, width: content.bounds.width, height: content.bounds.height - bar))
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

        func small(_ c: NSControl) { c.controlSize = .small; c.font = .systemFont(ofSize: 11) }
        func caption(_ s: String) -> NSTextField {
            let t = NSTextField(labelWithString: s); t.font = .systemFont(ofSize: 11); t.textColor = .secondaryLabelColor; t.sizeToFit(); return t
        }
        // Row 1 (upper): Show [popup]   Hide the rest with [Blur|Black]
        let y1: CGFloat = 32, y2: CGFloat = 6
        var x: CGFloat = 10
        let showCap = caption("Show"); showCap.frame.origin = NSPoint(x: x, y: y1 + 3); content.addSubview(showCap); x = showCap.frame.maxX + 6
        small(showPopup)
        showPopup.menu?.delegate = self
        showPopup.target = self; showPopup.action = #selector(showChanged)
        showPopup.frame = NSRect(x: x, y: y1, width: 190, height: 22)
        showPopup.toolTip = "Show only one app to others; everything else is hidden. The app's own masks still apply."
        content.addSubview(showPopup); x = showPopup.frame.maxX + 12
        let styleCap = caption("Hide the rest with"); styleCap.frame.origin = NSPoint(x: x, y: y1 + 3); content.addSubview(styleCap); x = styleCap.frame.maxX + 6
        small(stylePicker)
        stylePicker.target = self; stylePicker.action = #selector(styleChanged)
        stylePicker.sizeToFit(); stylePicker.frame.origin = NSPoint(x: x, y: y1)
        content.addSubview(stylePicker)

        // Row 2 (lower): [Preview|Full quality]  [Follow me|Stay here]   status
        x = 10
        small(qualityPicker)
        qualityPicker.target = self; qualityPicker.action = #selector(qualityChanged)
        qualityPicker.sizeToFit(); qualityPicker.frame.origin = NSPoint(x: x, y: y2)
        qualityPicker.setToolTip("About 10 frames a second; screen recorders and calls can't pick this window.", forSegment: 0)
        qualityPicker.setToolTip("Every frame, and recorders, screenshot tools and calls can pick this window under Select window. Uses more CPU.", forSegment: 1)
        content.addSubview(qualityPicker); x = qualityPicker.frame.maxX + 10
        small(placePicker)
        placePicker.target = self; placePicker.action = #selector(placeChanged)
        placePicker.sizeToFit(); placePicker.frame.origin = NSPoint(x: x, y: y2)
        placePicker.setToolTip("On every desktop, including full-screen apps, above other windows.", forSegment: 0)
        placePicker.setToolTip("A normal window on this desktop; it can go behind other windows (a recorder still captures it).", forSegment: 1)
        content.addSubview(placePicker); x = placePicker.frame.maxX + 10
        label.frame = NSRect(x: x, y: y2 + 3, width: content.bounds.width - x - 8, height: 16)
        label.autoresizingMask = [.width]
        label.alignment = .right
        label.lineBreakMode = .byTruncatingTail
        label.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        label.textColor = .secondaryLabelColor
        content.addSubview(label)

        w.contentView = content
        let follow = UserDefaults.standard.object(forKey: PreviewWindow.followKey) as? Bool ?? true
        placePicker.selectedSegment = follow ? 0 : 1
        applyPlace(follow, window: w)
        window = w
        rebuildShowMenu()
        lock.lock(); let style = hiddenStyle, only = showOnly; lock.unlock()
        stylePicker.selectedSegment = style == "black" ? 1 : 0
        stylePicker.isEnabled = only != nil

        let primaryH = CGDisplayBounds(CGMainDisplayID()).height
        w.setFrameOrigin(NSPoint(x: b.maxX - w.frame.width - 20, y: primaryH - b.maxY + 60))
        w.setFrameAutosaveName("WhatOthersSee")
    }

    // MARK: Show (entire screen / one app)

    func menuNeedsUpdate(_ menu: NSMenu) { rebuildShowMenu() }

    private func rebuildShowMenu() {
        lock.lock(); let only = showOnly; lock.unlock()
        let menu = showPopup.menu ?? NSMenu()
        menu.removeAllItems()
        let all = NSMenuItem(title: "Entire screen", action: nil, keyEquivalent: "")
        all.representedObject = nil
        menu.addItem(all)
        menu.addItem(.separator())
        let header = NSMenuItem(title: "Only this app:", action: nil, keyEquivalent: ""); header.isEnabled = false
        menu.addItem(header)
        var apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .sorted { ($0.localizedName ?? "").lowercased() < ($1.localizedName ?? "").lowercased() }
            .map { ($0.bundleIdentifier!, $0.localizedName ?? $0.bundleIdentifier!, $0.icon) }
        if let o = only, !apps.contains(where: { $0.0 == o }) { apps.insert((o, "\(o) (not running)", nil), at: 0) }
        var selected: NSMenuItem = all
        for (id, name, icon) in apps {
            let it = NSMenuItem(title: name, action: nil, keyEquivalent: "")
            it.representedObject = id
            it.image = icon.map { i in let c = i.copy() as! NSImage; c.size = NSSize(width: 16, height: 16); return c }
            menu.addItem(it)
            if id == only { selected = it }
        }
        showPopup.select(selected)
    }

    @objc private func showChanged() {
        let id = showPopup.selectedItem?.representedObject as? String
        lock.lock(); showOnly = id; lock.unlock()
        stylePicker.isEnabled = id != nil
        onShowOnly?(id)
    }

    @objc private func styleChanged() {
        let s = stylePicker.selectedSegment == 1 ? "black" : "blur"
        lock.lock(); hiddenStyle = s; lock.unlock()
        onHiddenStyle?(s)
    }

    // MARK: Quality

    @objc private func qualityChanged() { setFullQuality(qualityPicker.selectedSegment == 1) }

    private func setFullQuality(_ on: Bool) {
        lock.lock(); fullQuality = on; lock.unlock()
        qualityPicker.selectedSegment = on ? 1 : 0
        // Only capturable in Full quality: that's the mode for sharing / recording this window.
        window?.sharingType = on ? .readOnly : .none
        Log.info("what others see: \(on ? "full quality (capturable)" : "preview (not capturable)")")
        onNeedsFrame?()
    }

    // MARK: Follow me / Stay here

    @objc private func placeChanged() {
        let follow = placePicker.selectedSegment == 0
        UserDefaults.standard.set(follow, forKey: PreviewWindow.followKey)
        if let w = window { applyPlace(follow, window: w) }
    }

    private func applyPlace(_ follow: Bool, window w: NSWindow) {
        w.collectionBehavior = follow ? [.canJoinAllSpaces, .fullScreenAuxiliary] : [.managed, .fullScreenAuxiliary]
        w.level = follow ? .floating : .normal
    }

    // MARK: Drawing

    func windowDidResize(_ notification: Notification) { updateDrawableSize(); onNeedsFrame?() }
    func windowDidChangeBackingProperties(_ notification: Notification) { updateDrawableSize(); onNeedsFrame?() }
    func windowWillClose(_ notification: Notification) { lock.lock(); visible = false; lock.unlock() }

    private func updateDrawableSize() {
        guard let w = window, let v = w.contentView?.subviews.first else { return }
        let scale = w.backingScaleFactor
        let size = CGSize(width: max(1, v.bounds.width * scale), height: max(1, v.bounds.height * scale))
        lock.lock()
        layer.contentsScale = scale
        layer.drawableSize = size
        drawableSize = size
        lock.unlock()
    }

    /// Render queue. Scales the masked frame to fit (letterboxed on black). In Preview, at most
    /// about 10 frames a second.
    func present(_ image: CIImage, completion: ((Double) -> Void)?) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let target = drawableSize, on = visible, ctx = context, q = queue
        let due = fullQuality || now - lastDrawn >= 0.1
        if on && due { lastDrawn = now }
        lock.unlock()
        guard on, due, target.width > 1, let ctx = ctx, let q = q,
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

    func setStatus(_ status: String) { label.stringValue = status }

    // MARK: Test hooks

    func debugState() -> String {
        lock.lock(); let n = framesDrawn; let d = drawableSize; let fq = fullQuality; let only = showOnly; let st = hiddenStyle; lock.unlock()
        return "frames=\(n) drawable=\(Int(d.width))x\(Int(d.height)) visible=\(isVisible) full=\(fq) level=\(window?.level.rawValue ?? -1) sharing=\(window.map { "\($0.sharingType.rawValue)" } ?? "-") allSpaces=\(window?.collectionBehavior.contains(.canJoinAllSpaces) ?? false) show=\(only ?? "entire screen") style=\(st) popup=\(showPopup.titleOfSelectedItem ?? "-")"
    }
    func setSizeForTesting(_ size: NSSize) { window?.setContentSize(size) }
    func setFullQualityForTesting(_ on: Bool) { setFullQuality(on) }
    func setFollowForTesting(_ on: Bool) { placePicker.selectedSegment = on ? 0 : 1; placeChanged() }
}
