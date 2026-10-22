import AppKit
import ScreenCaptureKit
import CoreImage

/// Overlay region editor. Finds the app's main window, freezes a screenshot of it (for the
/// pixellation preview), then lays a transparent editor window exactly over the live window with
/// a floating toolbar. Both windows are `sharingType = .none` so they never leak into a share, and
/// the overlay follows the target window if it moves while editing.
final class RegionPicker: NSObject {
    let bundleID: String
    let pid: pid_t
    private let existing: [PresetRegion]
    private var overlay: NSWindow?
    private var toolbar: NSPanel?
    private var editor: ShapeEditorView?
    private var targetWindowID: CGWindowID = 0
    private var trackTimer: Timer?
    private var modePopup: NSPopUpButton?
    private var toolControl: NSSegmentedControl?

    /// (bundleID, all regions to store — replaces the app's list)
    var onSave: ((String, [ConfigStore.NewRegion]) -> Void)?
    var onClose: (() -> Void)?

    private var appName: String { NSRunningApplication(processIdentifier: pid)?.localizedName ?? bundleID }

    init(bundleID: String, pid: pid_t, existing: [PresetRegion]) {
        self.bundleID = bundleID
        self.pid = pid
        self.existing = existing
    }

    func begin() {
        guard !bundleID.isEmpty, pid > 0, bundleID != Bundle.main.bundleIdentifier else {
            fail("Bring the app you want to mask to the front and press the pick hotkey, or use “Pick regions for app” in the menu.")
            return
        }
        Log.info("picker: opening for \(bundleID) (pid \(pid))")
        Task { @MainActor in
            do {
                let (win, image) = try await snapshotMainWindow()
                show(window: win, image: image)
            } catch {
                fail("Could not capture a window of \(appName): \(error.localizedDescription)")
            }
        }
    }

    func bringToFront() {
        NSApp.activate(ignoringOtherApps: true)
        overlay?.makeKeyAndOrderFront(nil)
        toolbar?.orderFrontRegardless()
    }

    // MARK: Capture

    private func snapshotMainWindow() async throws -> (SCWindow, CGImage?) {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let candidates = content.windows.filter {
            $0.owningApplication?.processID == pid && $0.isOnScreen && $0.windowLayer == 0
                && $0.frame.width >= 50 && $0.frame.height >= 50
        }
        guard let win = candidates.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else {
            throw NSError(domain: "sharemask", code: 1, userInfo: [NSLocalizedDescriptionKey: "it has no visible window on this Space (unhide or un-minimise it first)"])
        }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let filter = SCContentFilter(desktopIndependentWindow: win)
        let cfg = SCStreamConfiguration()
        cfg.width = Int(win.frame.width * scale)
        cfg.height = Int(win.frame.height * scale)
        cfg.showsCursor = false
        cfg.captureResolution = .best
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
        return (win, image)
    }

    // MARK: UI

    @MainActor
    private func show(window win: SCWindow, image: CGImage?) {
        targetWindowID = win.windowID
        let frame = RegionPicker.appKitFrame(fromCG: win.frame)

        let pixellated: NSImage? = image.map { cg in
            let ci = CIImage(cgImage: cg)
            let out = Redactor.pixellate(ci, rect: ci.extent, scale: 24)
            let ctx = CIContext(options: [.cacheIntermediates: false])
            return ctx.createCGImage(out, from: ci.extent).map { NSImage(cgImage: $0, size: .zero) } ?? NSImage(cgImage: cg, size: .zero)
        }

        let ed = ShapeEditorView(pixellated: pixellated)
        ed.shapes = existing.map { r in
            let mode: String
            switch r.mode { case .pixellate: mode = "pixellate"; case .blur: mode = "blur"; case .solid: mode = "solid" }
            return EditableShape(kind: r.shape == .ellipse ? .ellipse : .rect, rect: r.rect, mode: mode, name: r.name)
        }
        ed.onCommit = { [weak self] in self?.save() }
        ed.onCancel = { [weak self] in self?.cancel() }
        ed.onSelectionChange = { [weak self] in self?.syncToolbar() }
        editor = ed

        let w = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.level = .floating
        w.sharingType = .none
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        w.ignoresMouseEvents = false
        w.acceptsMouseMovedEvents = true
        ed.frame = NSRect(origin: .zero, size: frame.size)
        ed.autoresizingMask = [.width, .height]
        w.contentView = ed
        overlay = w

        buildToolbar(above: frame)
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        w.makeFirstResponder(ed)
        toolbar?.orderFrontRegardless()
        trackTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.trackTarget() }
    }

    @MainActor
    private func buildToolbar(above frame: NSRect) {
        let width: CGFloat = 760, height: CGFloat = 44
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                        styleMask: [.borderless, .nonactivatingPanel, .utilityWindow], backing: .buffered, defer: false)
        p.level = .floating
        p.sharingType = .none
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        p.isMovableByWindowBackground = true
        let bg = NSVisualEffectView(frame: p.contentView!.bounds)
        bg.material = .hudWindow; bg.state = .active; bg.wantsLayer = true; bg.layer?.cornerRadius = 10

        var x: CGFloat = 10
        func add(_ v: NSView, w: CGFloat? = nil) {
            v.sizeToFitIfPossible()
            var f = v.frame; f.origin = NSPoint(x: x, y: (height - f.height) / 2); if let w = w { f.size.width = w }
            v.frame = f; bg.addSubview(v); x = f.maxX + 8
        }
        let title = NSTextField(labelWithString: appName)
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        add(title, w: 110)

        let tools = NSSegmentedControl(labels: ["Rect", "Square", "Circle"], trackingMode: .selectOne, target: self, action: #selector(toolChanged(_:)))
        tools.selectedSegment = 0
        tools.toolTip = "Shape for new regions (drag on the window to draw)"
        toolControl = tools
        add(tools)

        let mode = NSPopUpButton(frame: .zero, pullsDown: false)
        mode.addItems(withTitles: ["Pixellate", "Blur", "Black"])
        mode.target = self; mode.action = #selector(modeChanged(_:))
        mode.toolTip = "Redaction mode (applies to the selected shape and to new ones)"
        modePopup = mode
        add(mode)

        let templates = NSPopUpButton(frame: .zero, pullsDown: true)
        templates.addItems(withTitles: ["Templates", "Left sidebar (30%)", "Right sidebar (30%)", "Top bar (10%)", "Whole window", "Centre circle"])
        templates.target = self; templates.action = #selector(templateChosen(_:))
        add(templates)

        let del = NSButton(title: "Delete", target: self, action: #selector(deleteShape)); del.bezelStyle = .rounded
        add(del)
        let clear = NSButton(title: "Clear", target: self, action: #selector(clearShapes)); clear.bezelStyle = .rounded
        add(clear)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel)); cancel.bezelStyle = .rounded
        add(cancel)
        let save = NSButton(title: "Save", target: self, action: #selector(save)); save.bezelStyle = .rounded
        save.keyEquivalent = "\r"
        add(save)
        p.setContentSize(NSSize(width: x + 2, height: height))
        bg.frame = p.contentView!.bounds
        p.contentView = bg
        positionToolbar(p, above: frame)
        toolbar = p
    }

    private func positionToolbar(_ p: NSPanel, above frame: NSRect) {
        let screen = overlay?.screen ?? NSScreen.main ?? NSScreen.screens[0]
        var origin = NSPoint(x: frame.midX - p.frame.width / 2, y: frame.maxY + 8)
        if origin.y + p.frame.height > screen.visibleFrame.maxY { origin.y = frame.maxY - p.frame.height - 8 }
        origin.x = min(max(screen.visibleFrame.minX + 8, origin.x), screen.visibleFrame.maxX - p.frame.width - 8)
        p.setFrameOrigin(origin)
    }

    /// Keeps the overlay glued to the target window while the user edits.
    private func trackTarget() {
        guard let overlay = overlay else { return }
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], targetWindowID) as? [[String: Any]],
              let info = list.first, let b = info[kCGWindowBounds as String] as? NSDictionary,
              let cg = CGRect(dictionaryRepresentation: b as CFDictionary), cg.width > 0 else {
            Log.info("picker: target window vanished, cancelling")
            cancel()
            return
        }
        let frame = RegionPicker.appKitFrame(fromCG: cg)
        if overlay.frame != frame {
            overlay.setFrame(frame, display: true)
            if let t = toolbar { positionToolbar(t, above: frame) }
        }
    }

    static func appKitFrame(fromCG cg: CGRect) -> NSRect {
        let primaryH = CGDisplayBounds(CGMainDisplayID()).height
        return NSRect(x: cg.minX, y: primaryH - cg.maxY, width: cg.width, height: cg.height)
    }

    // MARK: Toolbar actions

    private func syncToolbar() {
        guard let ed = editor, let s = ed.selected, s < ed.shapes.count else { return }
        modePopup?.selectItem(at: ["pixellate", "blur", "solid"].firstIndex(of: ed.shapes[s].mode) ?? 0)
    }

    @objc private func toolChanged(_ sender: NSSegmentedControl) {
        editor?.tool = [.rect, .square, .ellipse][sender.selectedSegment]
        overlay?.makeFirstResponder(editor)
    }

    @objc private func modeChanged(_ sender: NSPopUpButton) {
        let mode = ["pixellate", "blur", "solid"][max(0, sender.indexOfSelectedItem)]
        editor?.defaultMode = mode
        if let ed = editor, let s = ed.selected, s < ed.shapes.count { ed.shapes[s].mode = mode }
        overlay?.makeFirstResponder(editor)
    }

    @objc private func templateChosen(_ sender: NSPopUpButton) {
        guard let ed = editor else { return }
        switch sender.indexOfSelectedItem {
        case 1: ed.addTemplate(CGRect(x: 0, y: 0, width: 0.3, height: 1), kind: .rect, name: "left sidebar")
        case 2: ed.addTemplate(CGRect(x: 0.7, y: 0, width: 0.3, height: 1), kind: .rect, name: "right sidebar")
        case 3: ed.addTemplate(CGRect(x: 0, y: 0, width: 1, height: 0.1), kind: .rect, name: "top bar")
        case 4: ed.addTemplate(CGRect(x: 0, y: 0, width: 1, height: 1), kind: .rect, name: "whole window")
        case 5: ed.addTemplate(CGRect(x: 0.35, y: 0.3, width: 0.3, height: 0.4), kind: .ellipse, name: "circle")
        default: break
        }
        sender.selectItem(at: 0)
        overlay?.makeFirstResponder(ed)
    }

    @objc private func deleteShape() { editor?.deleteSelected(); overlay?.makeFirstResponder(editor) }
    @objc private func clearShapes() { editor?.shapes = []; editor?.selected = nil }

    @objc private func save() {
        guard let ed = editor else { return }
        let regions = ed.shapes.enumerated().map { i, s in
            ConfigStore.NewRegion(name: s.name.isEmpty ? "region \(i + 1)" : s.name, rect: s.rect, mode: s.mode, shape: s.presetShape)
        }
        Log.info("picker: saving \(regions.count) region(s) for \(bundleID)")
        onSave?(bundleID, regions)
        close()
    }

    @objc private func cancel() { Log.info("picker: cancelled"); close() }

    private func close() {
        trackTimer?.invalidate(); trackTimer = nil
        overlay?.orderOut(nil); overlay = nil
        toolbar?.orderOut(nil); toolbar = nil
        editor = nil
        onClose?()
    }

    private func fail(_ message: String) {
        Log.warn("picker: \(message)")
        let a = NSAlert()
        a.messageText = "Region editor"
        a.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
        onClose?()
    }
}

private extension NSView {
    func sizeToFitIfPossible() {
        if let c = self as? NSControl { c.sizeToFit() }
    }
}
