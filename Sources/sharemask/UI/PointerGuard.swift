import AppKit

/// Keeps the mouse pointer off the virtual display: if it wanders in, warp it back to the nearest
/// point on the source display. Global monitors for mouse movement don't need Accessibility.
final class PointerGuard {
    private var monitors: [Any] = []
    /// Looked up on every check: the proxy display comes and goes.
    let virtualDisplayID: () -> CGDirectDisplayID?
    let sourceDisplayID: CGDirectDisplayID

    init(virtualDisplayID: @escaping () -> CGDirectDisplayID?, sourceDisplayID: CGDirectDisplayID) {
        self.virtualDisplayID = virtualDisplayID
        self.sourceDisplayID = sourceDisplayID
    }

    var isEnabled: Bool { !monitors.isEmpty }

    func enable() {
        guard monitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in self?.check() }) {
            monitors.append(g)
        }
        if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in self?.check(); return e }) {
            monitors.append(l)
        }
    }

    func disable() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
    }

    private func check() {
        guard let id = virtualDisplayID() else { return }
        let vb = CGDisplayBounds(id)
        guard vb.width > 0 else { return }
        // NSEvent.mouseLocation is AppKit (bottom-left of primary); convert to CG (top-left).
        let loc = NSEvent.mouseLocation
        let primaryH = CGDisplayBounds(CGMainDisplayID()).height
        let cg = CGPoint(x: loc.x, y: primaryH - loc.y)
        guard vb.contains(cg) else { return }
        let sb = CGDisplayBounds(sourceDisplayID).insetBy(dx: 2, dy: 2)
        let target = CGPoint(x: min(max(cg.x, sb.minX), sb.maxX), y: min(max(cg.y, sb.minY), sb.maxY))
        CGWarpMouseCursorPosition(target)
        // Re-associate so the next delta isn't applied relative to the old position.
        CGAssociateMouseAndMouseCursorPosition(1)
    }
}
