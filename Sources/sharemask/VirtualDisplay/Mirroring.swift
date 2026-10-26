import CoreGraphics

/// Switching a physical screen (HDMI/AirPlay TV) out of macOS mirror mode and back.
///
/// sharemask can't put masks into macOS's own mirroring (the window server copies pixels itself),
/// so both present modes need the TV as a separate display. This is a normal display setting, but
/// it's the user's, so the app only does it after they confirm, and restores it on stop.
///
/// NEVER call while sharemask's proxy display exists: any CGBeginDisplayConfiguration pins a
/// virtual display (un-removable until exit). Present modes don't create one.
enum Mirroring {
    struct Pair: Equatable { var display: CGDirectDisplayID; var master: CGDirectDisplayID }

    /// Displays that currently mirror something, among `id` and whatever it is mirrored with.
    static func mirrorPairs(involving id: CGDirectDisplayID) -> [Pair] {
        guard CGDisplayIsInMirrorSet(id) != 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var n: UInt32 = 0
        CGGetOnlineDisplayList(32, &ids, &n)
        let master = CGDisplayMirrorsDisplay(id) != kCGNullDirectDisplay ? CGDisplayMirrorsDisplay(id) : id
        return ids[..<Int(n)].compactMap { d in
            let m = CGDisplayMirrorsDisplay(d)
            return m != kCGNullDirectDisplay && (m == master || d == id) ? Pair(display: d, master: m) : nil
        }
    }

    static func isMirrored(_ id: CGDirectDisplayID) -> Bool { CGDisplayIsInMirrorSet(id) != 0 }

    /// Un-mirrors every pair; returns what was changed so it can be restored.
    @discardableResult
    static func unmirror(_ pairs: [Pair]) -> Bool {
        guard !pairs.isEmpty else { return true }
        var cfg: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&cfg) == .success else { return false }
        for p in pairs { CGConfigureDisplayMirrorOfDisplay(cfg, p.display, kCGNullDirectDisplay) }
        let r = CGCompleteDisplayConfiguration(cfg, .forSession)
        Log.info("unmirror \(pairs.map { "\($0.display)←\($0.master)" }): \(r == .success ? "ok" : "error \(r.rawValue)")")
        return r == .success
    }

    static func restore(_ pairs: [Pair]) {
        guard !pairs.isEmpty else { return }
        var cfg: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&cfg) == .success else { return }
        for p in pairs { CGConfigureDisplayMirrorOfDisplay(cfg, p.display, p.master) }
        let r = CGCompleteDisplayConfiguration(cfg, .forSession)
        Log.info("restore mirroring \(pairs.map { "\($0.display)←\($0.master)" }): \(r == .success ? "ok" : "error \(r.rawValue)")")
    }
}
