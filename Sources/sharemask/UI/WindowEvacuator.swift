import AppKit
import ApplicationServices

/// Moves other apps' windows off the proxy display and back onto the real one.
///
/// Why this is needed: macOS treats the proxy as a real screen. Apps can open windows on it, and
/// macOS restores windows onto it when it reappears (it remembers windows per display identity).
/// Those windows are hidden behind the black presenter, and a hidden modal alert can block an app
/// (a Finder error dialog there once stopped the Mac from shutting down).
///
/// Moving another app's window requires Accessibility permission (optional). Without it the only
/// way to get a window back is to remove the display, which macOS answers by moving windows home.
enum WindowEvacuator {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that leads to Privacy & Security → Accessibility.
    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Moves each window (matched by its CG bounds) into `target` (CG global coords, top-left).
    /// Returns the number of windows moved.
    @discardableResult
    static func evacuate(_ windows: [TrackedWindow], into target: CGRect) -> Int {
        guard isTrusted, !windows.isEmpty else { return 0 }
        var moved = 0
        for (pid, group) in Dictionary(grouping: windows, by: { $0.pid }) {
            let app = AXUIElementCreateApplication(pid)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
                  let axWindows = value as? [AXUIElement] else { continue }
            for w in group {
                guard let ax = axWindows.first(where: { frame(of: $0).map { close($0, w.boundsPoints) } ?? false }) else { continue }
                // Keep the size, centre it on the real display (clamped so the title bar is reachable).
                let size = w.boundsPoints.size
                var origin = CGPoint(x: target.midX - size.width / 2, y: target.midY - size.height / 2)
                origin.x = max(target.minX, min(origin.x, target.maxX - min(size.width, target.width)))
                origin.y = max(target.minY, min(origin.y, target.maxY - min(size.height, target.height)))
                var p = origin
                if let v = AXValueCreate(.cgPoint, &p),
                   AXUIElementSetAttributeValue(ax, kAXPositionAttribute as CFString, v) == .success {
                    moved += 1
                    Log.info("evacuated window \(w.windowID) of \(w.bundleID ?? "pid \(pid)") to \(Int(origin.x)),\(Int(origin.y))")
                }
            }
        }
        return moved
    }

    private static func frame(of ax: AXUIElement) -> CGRect? {
        var pos: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, kAXPositionAttribute as CFString, &pos) == .success,
              AXUIElementCopyAttributeValue(ax, kAXSizeAttribute as CFString, &size) == .success else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        AXValueGetValue(pos as! AXValue, .cgPoint, &p)
        AXValueGetValue(size as! AXValue, .cgSize, &s)
        return CGRect(origin: p, size: s)
    }

    private static func close(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 3 && abs(a.minY - b.minY) < 3 && abs(a.width - b.width) < 3 && abs(a.height - b.height) < 3
    }
}
