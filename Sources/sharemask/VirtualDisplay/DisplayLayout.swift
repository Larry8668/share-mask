import CoreGraphics
import Foundation

/// Where the proxy display sits relative to the real ones, and how to move it safely.
///
/// macOS slots a new display next to the existing ones, often *between* two real screens (seen
/// with an external monitor: the proxy went in at x=1470 and pushed the monitor to x=4410). With the
/// pointer guard on, the cursor could then never cross to the monitor.
///
/// Moving it in-process is not an option: any CGBeginDisplayConfiguration touching it makes it
/// un-removable until the process exits (measured again 2026-10-26). But (a) a move done by a
/// short-lived helper process does not pin it, and (b) macOS remembers the position per display
/// identity + display set and restores it on the next creation. So placement is a one-time step per
/// monitor setup, done by `sharemask --probe ... --origin X,Y` in a child process.
enum DisplayLayout {
    /// Real (non-sharemask) active displays.
    /// Uses the ONLINE list: a screen that is mirroring is online but not "active", and a TV
    /// usually connects in mirror mode, so the active list would miss it entirely.
    static func realDisplays(excluding vd: CGDirectDisplayID?) -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var n: UInt32 = 0
        CGGetOnlineDisplayList(32, &ids, &n)
        return ids[..<Int(n)].filter { $0 != vd && CGDisplayVendorNumber($0) != VirtualDisplay.vendorID }
    }

    /// Length of the edge two rects share (0 if they only touch at a corner or not at all).
    static func sharedEdge(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let touchX = abs(a.maxX - b.minX) < 0.5 || abs(b.maxX - a.minX) < 0.5
        let touchY = abs(a.maxY - b.minY) < 0.5 || abs(b.maxY - a.minY) < 0.5
        let overlapY = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        let overlapX = min(a.maxX, b.maxX) - max(a.minX, b.minX)
        return max(touchX ? max(0, overlapY) : 0, touchY ? max(0, overlapX) : 0)
    }

    /// Good = touches the real displays at most at a corner, so the cursor can't wander onto it
    /// along an edge and it can't sit between two screens.
    static func isWellPlaced(_ vd: CGRect, real: [CGRect]) -> Bool {
        real.allSatisfy { sharedEdge(vd, $0) < 1 && !$0.intersects(vd) }
    }

    /// True if `target` sits between real screens (shares an edge with two or more), i.e. blocking
    /// it would cut the cursor off from a screen behind it.
    static func isBetween(_ target: CGRect, real: [CGRect]) -> Bool {
        real.filter { sharedEdge(target, $0) >= 1 }.count >= 2
    }

    /// Below-right corner of the right-most real display: nothing extends past its right edge, so
    /// the proxy overlaps nothing and touches only that one corner.
    static func cornerOrigin(real: [CGRect]) -> CGPoint {
        guard let r = real.max(by: { $0.maxX < $1.maxX }) else { return CGPoint(x: 10000, y: 10000) }
        return CGPoint(x: r.maxX, y: r.maxY)
    }

    /// Runs the helper child that creates the same-identity display, moves it, and exits.
    /// Blocking (~0.5–1 s); call off the main thread.
    static func placeWithHelper(spec: VirtualDisplay.Spec, origin: CGPoint) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        p.arguments = ["--probe", "--place",
                       "--mode", "\(spec.modeWidth)x\(spec.modeHeight)",
                       "--max", "\(spec.pixelsWide)x\(spec.pixelsHigh)",
                       "--dpi", "\(spec.dpi)",
                       "--origin", "\(Int(origin.x)),\(Int(origin.y))"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        do {
            try p.run()
            p.waitUntilExit()
            let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            Log.info("placement helper exited \(p.terminationStatus): \(text.split(separator: "\n").filter { $0.contains("moved") }.joined())")
            return p.terminationStatus == 0
        } catch {
            Log.error("placement helper failed to start: \(error)")
            return false
        }
    }
}
