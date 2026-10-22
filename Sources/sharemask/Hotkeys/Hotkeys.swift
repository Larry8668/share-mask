import Carbon
import AppKit

/// Global hotkeys via Carbon `RegisterEventHotKey` (works when any app is frontmost, no
/// Accessibility permission required). Strings look like "cmd+shift+ctrl+B".
final class Hotkeys {
    enum Action: UInt32, CaseIterable { case panic = 1, toggle = 2, pick = 3, reveal = 4, allowlist = 5, endShare = 6 }

    private var refs: [Action: EventHotKeyRef] = [:]
    private var handlerRef: EventHandlerRef?
    private var handlers: [Action: () -> Void] = [:]
    private var releaseHandlers: [Action: () -> Void] = [:]
    private static var shared: Hotkeys?

    init() { Hotkeys.shared = self }

    func set(_ action: Action, combo: String?, handler: @escaping () -> Void, onRelease: (() -> Void)? = nil) {
        unregister(action)
        releaseHandlers[action] = onRelease
        guard let combo = combo, !combo.isEmpty, let (key, mods) = Hotkeys.parse(combo) else {
            if let c = combo, !c.isEmpty { Log.warn("hotkey '\(c)' for \(action) not understood") }
            return
        }
        installHandlerIfNeeded()
        handlers[action] = handler
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x534D4B59) /* 'SMKY' */, id: action.rawValue)
        let status = RegisterEventHotKey(key, mods, id, GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref = ref {
            refs[action] = ref
        } else {
            Log.warn("RegisterEventHotKey(\(combo)) failed: \(status)")
        }
    }

    func unregister(_ action: Action) {
        if let r = refs.removeValue(forKey: action) { UnregisterEventHotKey(r) }
        handlers[action] = nil
        releaseHandlers[action] = nil
    }

    func unregisterAll() { Action.allCases.forEach(unregister) }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var specs = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            guard let event = event else { return noErr }
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard let action = Action(rawValue: id.id) else { return noErr }
            if GetEventKind(event) == UInt32(kEventHotKeyReleased) {
                Hotkeys.shared?.releaseHandlers[action]?()
            } else {
                Hotkeys.shared?.handlers[action]?()
            }
            return noErr
        }, 2, &specs, nil, &handlerRef)
    }

    /// "cmd+shift+ctrl+B" → (virtual key code, carbon modifier mask)
    static func parse(_ combo: String) -> (UInt32, UInt32)? {
        var mods: UInt32 = 0
        var key: UInt32?
        for raw in combo.split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }) {
            switch raw {
            case "cmd", "command", "⌘": mods |= UInt32(cmdKey)
            case "shift", "⇧": mods |= UInt32(shiftKey)
            case "ctrl", "control", "⌃": mods |= UInt32(controlKey)
            case "alt", "opt", "option", "⌥": mods |= UInt32(optionKey)
            default:
                guard key == nil, let k = keyCodes[raw] else { return nil }
                key = k
            }
        }
        guard let k = key else { return nil }
        return (k, mods)
    }

    /// Display form, e.g. "⌃⇧⌘B".
    static func pretty(_ combo: String?) -> String {
        guard let combo = combo, let _ = parse(combo) else { return "" }
        var out = ""
        var key = ""
        for raw in combo.split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }) {
            switch raw {
            case "ctrl", "control", "⌃": out += "⌃"
            case "alt", "opt", "option", "⌥": out += "⌥"
            case "shift", "⇧": out += "⇧"
            case "cmd", "command", "⌘": out += "⌘"
            default: key = raw.uppercased()
            }
        }
        return out + key
    }

    // ANSI (US) virtual key codes.
    static let keyCodes: [String: UInt32] = [
        "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05, "z": 0x06, "x": 0x07, "c": 0x08,
        "v": 0x09, "b": 0x0B, "q": 0x0C, "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10, "t": 0x11, "1": 0x12,
        "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17, "=": 0x18, "9": 0x19, "7": 0x1A, "-": 0x1B,
        "8": 0x1C, "0": 0x1D, "]": 0x1E, "o": 0x1F, "u": 0x20, "[": 0x21, "i": 0x22, "p": 0x23, "l": 0x25,
        "j": 0x26, "'": 0x27, "k": 0x28, ";": 0x29, "\\": 0x2A, ",": 0x2B, "/": 0x2C, "n": 0x2D, "m": 0x2E,
        ".": 0x2F, "`": 0x32, "space": 0x31, "return": 0x24, "enter": 0x24, "tab": 0x30, "delete": 0x33,
        "escape": 0x35, "esc": 0x35, "f1": 0x7A, "f2": 0x78, "f3": 0x63, "f4": 0x76, "f5": 0x60, "f6": 0x61,
        "f7": 0x62, "f8": 0x64, "f9": 0x65, "f10": 0x6D, "f11": 0x67, "f12": 0x6F, "left": 0x7B, "right": 0x7C,
        "down": 0x7D, "up": 0x7E, "home": 0x73, "end": 0x77, "pageup": 0x74, "pagedown": 0x79,
    ]
}
