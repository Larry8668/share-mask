import AppKit
import ScreenCaptureKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// Drag-to-define rectangles on a frozen screenshot of the frontmost app's window. The picker
/// window lives on the real display with `sharingType = .none`, so it never leaks into the feed.
final class RegionPicker: NSObject, NSWindowDelegate {
    let bundleID: String
    let pid: pid_t
    private let existing: [PresetRegion]
    private var window: NSWindow?
    private var view: PickerView?

    /// (bundleID, new regions, replaceAll)
    var onSave: ((String, [(name: String, rect: CGRect)], Bool) -> Void)?
    var onClose: (() -> Void)?

    init(bundleID: String, pid: pid_t, existing: [PresetRegion]) {
        self.bundleID = bundleID
        self.pid = pid
        self.existing = existing
    }

    func begin() {
        guard !bundleID.isEmpty, pid > 0, bundleID != Bundle.main.bundleIdentifier else {
            fail("Bring the app you want to mask to the front, then press the pick hotkey.")
            return
        }
        Task { @MainActor in
            do {
                let (image, scale) = try await snapshotFrontWindow()
                show(image: image, scale: scale)
            } catch {
                fail("Could not capture the frontmost window of \(bundleID): \(error)")
            }
        }
    }

    func bringToFront() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: Capture

    private func snapshotFrontWindow() async throws -> (CGImage, CGFloat) {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let candidates = content.windows.filter {
            $0.owningApplication?.processID == pid && $0.isOnScreen && $0.windowLayer == 0
                && $0.frame.width >= 50 && $0.frame.height >= 50
        }
        guard let win = candidates.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else {
            throw NSError(domain: "sharemask", code: 1, userInfo: [NSLocalizedDescriptionKey: "no on-screen window"])
        }
        let scale = NSScreen.screens.first(where: { $0.frame.intersects(NSRect(origin: .zero, size: $0.frame.size)) })?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor ?? 2
        let filter = SCContentFilter(desktopIndependentWindow: win)
        let cfg = SCStreamConfiguration()
        cfg.width = Int(win.frame.width * scale)
        cfg.height = Int(win.frame.height * scale)
        cfg.showsCursor = false
        cfg.captureResolution = .best
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
        return (image, scale)
    }

    // MARK: UI

    @MainActor
    private func show(image: CGImage, scale: CGFloat) {
        let pointSize = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let avail = screen.visibleFrame.insetBy(dx: 40, dy: 60)
        let fit = min(1, min(avail.width / pointSize.width, (avail.height - 44) / pointSize.height))
        let viewSize = NSSize(width: floor(pointSize.width * fit), height: floor(pointSize.height * fit))

        let v = PickerView(image: image, existing: existing.map { $0.rect })
        v.frame = NSRect(origin: .zero, size: viewSize)

        let toolbar = NSView(frame: NSRect(x: 0, y: 0, width: viewSize.width, height: 44))
        let hint = NSTextField(labelWithString: "Drag to add a region · ⌫ undo · ⎋ cancel · ⏎ save    (\(bundleID))")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.frame = NSRect(x: 12, y: 14, width: viewSize.width - 320, height: 18)
        hint.lineBreakMode = .byTruncatingTail
        let clear = NSButton(title: "Replace existing", target: self, action: #selector(saveReplace))
        let save = NSButton(title: "Save", target: self, action: #selector(saveAppend))
        save.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        var x = viewSize.width - 12
        for b in [save, cancel, clear] {
            b.sizeToFit()
            x -= b.frame.width
            b.frame.origin = NSPoint(x: x, y: 8)
            x -= 8
            toolbar.addSubview(b)
        }
        toolbar.addSubview(hint)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: viewSize.width, height: viewSize.height + 44))
        v.frame.origin = NSPoint(x: 0, y: 44)
        container.addSubview(v)
        container.addSubview(toolbar)

        let w = NSWindow(contentRect: container.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "sharemask — pick regions for \(bundleID)"
        w.contentView = container
        w.sharingType = .none          // never visible to screen capture
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.level = .floating
        w.center()
        window = w
        view = v
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        w.makeFirstResponder(v)
    }

    @objc private func saveAppend() { finish(replace: false) }
    @objc private func saveReplace() { finish(replace: true) }
    @objc private func cancel() { close() }

    private func finish(replace: Bool) {
        guard let v = view else { return }
        let base = replace ? 0 : existing.count
        let regions = v.newRects.enumerated().map { (name: "region \(base + $0.offset + 1)", rect: $0.element) }
        if !regions.isEmpty || replace { onSave?(bundleID, regions, replace) }
        close()
    }

    private func close() {
        window?.orderOut(nil)
        window = nil
        onClose?()
    }

    func windowWillClose(_ notification: Notification) { if window != nil { window = nil; onClose?() } }

    private func fail(_ message: String) {
        let a = NSAlert()
        a.messageText = "Region picker"
        a.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
        onClose?()
    }
}

/// Draws the frozen screenshot; rects are kept normalised to the image so the view can be scaled.
final class PickerView: NSView {
    private let image: NSImage
    private let pixellated: NSImage
    private let existing: [CGRect]
    private(set) var newRects: [CGRect] = []
    private var dragStart: NSPoint?
    private var dragCurrent: NSPoint?

    init(image: CGImage, existing: [CGRect]) {
        self.image = NSImage(cgImage: image, size: .zero)
        self.existing = existing
        self.pixellated = PickerView.pixellate(image)
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }     // top-left origin, like the preset coordinates

    private static func pixellate(_ cg: CGImage) -> NSImage {
        let ci = CIImage(cgImage: cg)
        let out = Redactor.pixellate(ci, rect: ci.extent, scale: 24)
        let ctx = CIContext(options: [.cacheIntermediates: false])
        if let img = ctx.createCGImage(out, from: ci.extent) { return NSImage(cgImage: img, size: .zero) }
        return NSImage(cgImage: cg, size: .zero)
    }

    private func toView(_ n: CGRect) -> NSRect {
        NSRect(x: n.minX * bounds.width, y: n.minY * bounds.height, width: n.width * bounds.width, height: n.height * bounds.height)
    }

    private func normalised(from a: NSPoint, to b: NSPoint) -> CGRect {
        let r = NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
        return CGRect(x: r.minX / bounds.width, y: r.minY / bounds.height,
                      width: r.width / bounds.width, height: r.height / bounds.height).clamped01
    }

    override func draw(_ dirtyRect: NSRect) {
        // NSImage.draw respects the flipped context when we ask it to.
        image.draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])

        var rects = existing + newRects
        if let a = dragStart, let b = dragCurrent { rects.append(normalised(from: a, to: b)) }
        for (i, n) in rects.enumerated() {
            let r = toView(n)
            guard r.width > 0, r.height > 0 else { continue }
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: r).addClip()
            pixellated.draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
            let isExisting = i < existing.count
            (isExisting ? NSColor.systemBlue : NSColor.systemGreen).setStroke()
            let p = NSBezierPath(rect: r.insetBy(dx: 0.5, dy: 0.5))
            p.lineWidth = isExisting ? 1 : 2
            if isExisting { p.setLineDash([4, 3], count: 2, phase: 0) }
            p.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = convert(event.locationInWindow, from: nil)
        dragCurrent = dragStart
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        dragCurrent = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        if let a = dragStart, let b = dragCurrent {
            let n = normalised(from: a, to: b)
            if n.width > 0.005, n.height > 0.005 { newRects.append(n) }
        }
        dragStart = nil; dragCurrent = nil
        needsDisplay = true
    }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 0x33, 0x75:   // delete / forward delete: undo last
            if !newRects.isEmpty { newRects.removeLast(); needsDisplay = true }
        default: super.keyDown(with: event)
        }
    }
}
