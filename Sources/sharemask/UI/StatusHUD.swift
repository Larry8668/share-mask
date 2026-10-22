import AppKit

/// Tiny click-through panel in the bottom-right of the real display. `sharingType = .none` so it
/// never appears in the capture (and `RegionResolver` ignores our PID, so it never occludes).
final class StatusHUD {
    enum Mode { case safe, panic, regionsOff, stopped }

    private var panel: NSPanel?
    private let label = NSTextField(labelWithString: "")

    func show(on displayID: CGDirectDisplayID) {
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 150, height: 26),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.level = .statusBar
            p.sharingType = .none
            p.ignoresMouseEvents = true
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            p.hidesOnDeactivate = false
            let bg = NSVisualEffectView(frame: p.contentView!.bounds)
            bg.material = .hudWindow
            bg.state = .active
            bg.wantsLayer = true
            bg.layer?.cornerRadius = 8
            bg.autoresizingMask = [.width, .height]
            label.frame = bg.bounds.insetBy(dx: 10, dy: 5)
            label.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
            label.alignment = .center
            label.autoresizingMask = [.width, .height]
            bg.addSubview(label)
            p.contentView = bg
            panel = p
        }
        let bounds = CGDisplayBounds(displayID)
        // CG → AppKit coordinates (flip y against the primary display height).
        let primaryH = CGDisplayBounds(CGMainDisplayID()).height
        let x = bounds.maxX - 150 - 16
        let y = primaryH - bounds.maxY + 16
        panel?.setFrameOrigin(NSPoint(x: x, y: y))
        panel?.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }

    func set(_ mode: Mode) {
        switch mode {
        case .safe: label.stringValue = "● sharing-safe"; label.textColor = .systemGreen
        case .panic: label.stringValue = "PANIC"; label.textColor = .systemRed
        case .regionsOff: label.stringValue = "○ regions off"; label.textColor = .systemOrange
        case .stopped: label.stringValue = "■ stopped"; label.textColor = .secondaryLabelColor
        }
    }
}
