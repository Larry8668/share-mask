import AppKit
import Carbon

/// "Press the new shortcut" panel. Captures one key combination (must include ⌘ or ⌃ so plain
/// typing can't be hijacked) and hands back the presets.json string form, e.g. "cmd+shift+ctrl+B".
final class HotkeyRecorder {
    private var panel: NSPanel?
    private var monitor: Any?
    private var label: NSTextField?
    private var onDone: ((String?) -> Void)?

    func record(actionName: String, current: String?, onDone: @escaping (String?) -> Void) {
        close()
        self.onDone = onDone
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 120),
                        styleMask: [.titled, .closable], backing: .buffered, defer: false)
        p.title = "Shortcut for \(actionName)"
        p.sharingType = .none
        p.level = .floating
        p.isReleasedWhenClosed = false
        let v = NSView(frame: p.contentView!.bounds)
        let hint = NSTextField(labelWithString: "Press the new shortcut (must include ⌘ or ⌃). Esc cancels, ⌫ clears.")
        hint.font = .systemFont(ofSize: 12)
        hint.frame = NSRect(x: 16, y: 80, width: 348, height: 20)
        let l = NSTextField(labelWithString: current.map { Hotkeys.pretty($0) } ?? "—")
        l.font = .monospacedSystemFont(ofSize: 22, weight: .semibold)
        l.alignment = .center
        l.frame = NSRect(x: 16, y: 30, width: 348, height: 36)
        v.addSubview(hint); v.addSubview(l)
        p.contentView = v
        p.center()
        label = l
        panel = p
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            self?.handle(e)
            return nil
        }
    }

    private func handle(_ e: NSEvent) {
        if e.keyCode == 0x35 { finish(nil, cancelled: true); return }          // esc
        if e.keyCode == 0x33 && e.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty { finish("", cancelled: false); return }
        guard let name = Hotkeys.keyCodes.first(where: { $0.value == UInt32(e.keyCode) })?.key else {
            NSSound.beep(); return
        }
        let f = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var parts: [String] = []
        if f.contains(.command) { parts.append("cmd") }
        if f.contains(.shift) { parts.append("shift") }
        if f.contains(.control) { parts.append("ctrl") }
        if f.contains(.option) { parts.append("alt") }
        guard f.contains(.command) || f.contains(.control) else {
            label?.stringValue = "needs ⌘ or ⌃"; NSSound.beep(); return
        }
        parts.append(name.count == 1 ? name.uppercased() : name)
        finish(parts.joined(separator: "+"), cancelled: false)
    }

    private func finish(_ combo: String?, cancelled: Bool) {
        let cb = onDone
        close()
        if !cancelled { cb?(combo) }
    }

    func close() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        panel?.orderOut(nil); panel = nil; onDone = nil
    }
}
