import AppKit
import ScreenCaptureKit

/// macOS's own share picker (Safari, and Firefox-based browsers on recent macOS) picks a screen by
/// clicking on it — impossible for the invisible "sharemask" screen. But the picker draws a
/// "Share <screen name>" button on every screen, ours included, and Accessibility can press it
/// without moving the pointer (a synthesised click on the screen itself is ignored).
enum SharePickerAssist {
    /// The picker's "Share <screen name>" button in the strip it draws at the top of `id`, if the
    /// picker is open. Found by hit-testing: its windows aren't in Control Centre's window list.
    static func shareButton(on id: CGDirectDisplayID) -> AXUIElement? {
        let b = CGDisplayBounds(id)
        guard b.width > 0 else { return nil }
        let sys = AXUIElementCreateSystemWide()
        // The controls sit right-aligned in the top ~60 pt; scan from the right edge inwards.
        for y in stride(from: b.minY + 12, to: b.minY + 64, by: 8) {
            for x in stride(from: b.maxX - 8, to: b.maxX - min(b.width, 900), by: -20) {
                var el: AXUIElement?
                guard AXUIElementCopyElementAtPosition(sys, Float(x), Float(y), &el) == .success, let e = el else { continue }
                var role: CFTypeRef?, desc: CFTypeRef?
                AXUIElementCopyAttributeValue(e, kAXRoleAttribute as CFString, &role)
                AXUIElementCopyAttributeValue(e, kAXDescriptionAttribute as CFString, &desc)
                guard (role as? String) == kAXButtonRole as String, let d = desc as? String,
                      d.localizedCaseInsensitiveContains("sharemask") else { continue }
                var pid: pid_t = 0
                AXUIElementGetPid(e, &pid)
                guard NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.apple.controlcenter" else { continue }
                return e
            }
        }
        return nil
    }

    /// Whether macOS's share picker is open and offering screens, judged from its windows on the
    /// sharemask screen (Control Centre draws "SharedContentPicker…" windows on every display).
    static func pickerShowing(on id: CGDirectDisplayID, windows: [TrackedWindow]) -> Bool {
        let b = CGDisplayBounds(id)
        return windows.contains {
            $0.bundleID == "com.apple.controlcenter" && ($0.title ?? "").hasPrefix("SharedContentPickerDisplayControls")
                && b.intersects($0.boundsPoints)
        }
    }

    /// Where apps that number screens ("Screen 1", "Screen 2"…: Chrome, Firefox's own list, Zoom)
    /// most likely put the sharemask screen: they follow the system's display order.
    static func listedNumber(of id: CGDirectDisplayID) -> Int? {
        var n: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &n) == .success, n > 1 else { return nil }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(n))
        guard CGGetActiveDisplayList(n, &ids, &n) == .success else { return nil }
        return ids.prefix(Int(n)).firstIndex(of: id).map { $0 + 1 }
    }

    /// Presses the picker's "Share sharemask" button. Returns false if the picker isn't showing it.
    @discardableResult
    static func pressShareButton(on id: CGDirectDisplayID) -> Bool {
        guard let button = shareButton(on: id) else { Log.info("share picker assist: no picker button on screen \(id)"); return false }
        let r = AXUIElementPerformAction(button, kAXPressAction as CFString)
        Log.info("share picker assist: pressed \"Share sharemask\" (\(r == .success ? "ok" : "AX error \(r.rawValue)"))")
        return r == .success
    }
}

/// Test harness: opens macOS's share picker from sharemask itself and logs what was chosen.
final class SharePickerProbe: NSObject, SCContentSharingPickerObserver {
    static let shared = SharePickerProbe()

    func present() {
        let p = SCContentSharingPicker.shared
        p.add(self)
        p.isActive = true
        p.present(using: .display)
        Log.info("picker probe: macOS share picker presented (display mode)")
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Log.info("picker probe: cancelled")
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        var ids: [CGDirectDisplayID] = []
        if #available(macOS 15.2, *) { ids = filter.includedDisplays.map { $0.displayID } }
        Log.info("picker probe: chose displays \(ids) rect \(filter.contentRect) (main: \(CGMainDisplayID()))")
        DispatchQueue.main.async { picker.isActive = false; picker.remove(self) }
    }

    func contentSharingPickerStartDidFailWithError(_ error: Error) {
        Log.info("picker probe: failed \(error)")
    }
}
