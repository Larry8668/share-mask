import Foundation
import CoreGraphics

/// `sharemask --probe [options]` — CLI diagnostics. Runs without AppKit.
///
///   --probe                 list displays, create the virtual display, list again, release, time removal
///   --probe <displayID>     print geometry + current mode for one display (used as a child process by
///                           the app because mode reporting is broken in the creating process)
///   --probe --no-create     list only
///   --probe --mode WxH --hidpi 0|1 --dpi N --max WxH --hold SECONDS
enum Probe {
    static func run(arguments: [String]) -> Int32 {
        var args = arguments[...]
        var create = true
        var mode: (Int, Int)?
        var maxPx: (Int, Int)?
        var hiDPI = false
        var dpi = 110.0
        var hold = 2.0
        var single: CGDirectDisplayID?
        var origin: CGPoint?
        var placeOnly = false

        while let a = args.popFirst() {
            switch a {
            case "--no-create": create = false
            case "--fake-tv":
                // Test stand-in for an HDMI/AirPlay screen: its own identity, so sharemask treats it
                // as an external physical display. Optional "--mirror" makes it mirror the main screen.
                let size = parseSize(args.popFirst()) ?? (1920, 1080)
                let mirror = args.first == "--mirror"; if mirror { _ = args.popFirst() }
                var holdFor = 30.0
                var tvName = "faketv"
                if args.first == "--name" { _ = args.popFirst(); tvName = args.popFirst() ?? tvName }
                if args.first == "--hold" { _ = args.popFirst(); holdFor = Double(args.popFirst() ?? "") ?? 30 }
                var spec = VirtualDisplay.Spec.forSource(pixelsWide: size.0, pixelsHigh: size.1)
                spec.name = tvName; spec.vendor = 0x1234; spec.product = 0x0002
                do {
                    let tv = try VirtualDisplay.create(spec: spec)
                    print("fake TV \(tv.displayID) \(size.0)x\(size.1) at \(CGDisplayBounds(tv.displayID))")
                    if mirror {
                        Thread.sleep(forTimeInterval: 0.5)
                        var cfg: CGDisplayConfigRef?
                        CGBeginDisplayConfiguration(&cfg)
                        CGConfigureDisplayMirrorOfDisplay(cfg, tv.displayID, CGMainDisplayID())
                        let r = CGCompleteDisplayConfiguration(cfg, .forSession)
                        print("fake TV mirroring main: \(r.rawValue == 0 ? "ok" : "error \(r.rawValue)")")
                    }
                    fflush(stdout)
                    Thread.sleep(forTimeInterval: holdFor)
                    print("fake TV done (exit reclaims it)")
                } catch { print("fake TV failed: \(error)"); return 1 }
                return 0
            case "--place": placeOnly = true; hold = 0.3
            case "--windows":
                var cache: [pid_t: String?] = [:]
                for w in WindowTracker.copyOnScreenWindows(bundleCache: &cache) {
                    let b = w.boundsPoints
                    print("win \(w.windowID) pid=\(w.pid) \(w.bundleID ?? "?") layer=\(w.layer) alpha=\(w.alpha) sharing=\(w.sharingState) bounds=(\(Int(b.minX)),\(Int(b.minY)) \(Int(b.width))x\(Int(b.height))) title=\(w.title ?? "")")
                }
                return 0
            case "--hidpi": hiDPI = (args.popFirst() ?? "0") != "0"
            case "--dpi": dpi = Double(args.popFirst() ?? "") ?? dpi
            case "--hold": hold = Double(args.popFirst() ?? "") ?? hold
            case "--mode": mode = parseSize(args.popFirst())
            case "--max": maxPx = parseSize(args.popFirst())
            case "--move":
                // --move <displayID> X,Y : only reconfigure an existing display's origin, then exit.
                let id = UInt32(args.popFirst() ?? "") ?? 0
                let parts = (args.popFirst() ?? "").split(separator: ",").compactMap { Double($0) }
                guard parts.count == 2 else { print("usage: --move ID X,Y"); return 2 }
                var cfg: CGDisplayConfigRef?
                CGBeginDisplayConfiguration(&cfg)
                CGConfigureDisplayOrigin(cfg, id, Int32(parts[0]), Int32(parts[1]))
                let r = CGCompleteDisplayConfiguration(cfg, .permanently)
                print("move \(id) -> \(parts): \(r.rawValue == 0 ? "ok" : "error \(r.rawValue)")")
                return 0
            case "--origin":
                let parts = (args.popFirst() ?? "").split(separator: ",").compactMap { Double($0) }
                if parts.count == 2 { origin = CGPoint(x: parts[0], y: parts[1]) }
            default:
                if let id = UInt32(a) { single = id } else { print("unknown probe option \(a)"); return 2 }
            }
        }

        if let id = single {
            // Mode reporting only works for processes that did not enumerate before the display
            // existed — which is exactly why this path runs in a fresh child process.
            describe(id, withModes: true)
            let opts = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
            if let all = CGDisplayCopyAllDisplayModes(id, opts) as? [CGDisplayMode] {
                for m in all {
                    print("  mode \(m.pixelWidth)x\(m.pixelHeight)px / \(m.width)x\(m.height)pt @\(Int(m.refreshRate)) usable=\(m.isUsableForDesktopGUI())")
                }
            } else {
                print("  (CGDisplayCopyAllDisplayModes returned NULL)")
            }
            return 0
        }

        print("== active displays (before) ==")
        let before = activeDisplays()
        before.forEach { describe($0, withModes: true) }
        guard create else { return 0 }

        do { try VirtualDisplay.checkAPI() } catch { print("API check failed: \(error)"); return 1 }

        let main = CGMainDisplayID()
        let srcW = CGDisplayPixelsWide(main), srcH = CGDisplayPixelsHigh(main)
        var spec = VirtualDisplay.Spec.forSource(pixelsWide: srcW, pixelsHigh: srcH, hiDPI: hiDPI)
        if let m = mode { spec.modeWidth = UInt32(m.0); spec.modeHeight = UInt32(m.1) }
        if let m = maxPx { spec.pixelsWide = UInt32(m.0); spec.pixelsHigh = UInt32(m.1) }
        spec.dpi = dpi
        print("\n== creating virtual display: max \(spec.pixelsWide)x\(spec.pixelsHigh) mode \(spec.modeWidth)x\(spec.modeHeight) hiDPI=\(spec.hiDPI) dpi=\(dpi) (\(Int(spec.widthMM))x\(Int(spec.heightMM)) mm) serial=\(spec.serial)")
        let t0 = Date()
        let vd: VirtualDisplay
        do { vd = try VirtualDisplay.create(spec: spec) } catch { print("create failed: \(error)"); return 1 }
        print("created id=\(vd.displayID) in \(ms(t0)) ms, reportedHiDPI=\(vd.reportedHiDPI)")

        if let o = origin {
            Thread.sleep(forTimeInterval: 0.5)
            var cfg: CGDisplayConfigRef?
            CGBeginDisplayConfiguration(&cfg)
            CGConfigureDisplayOrigin(cfg, vd.displayID, Int32(o.x), Int32(o.y))
            let r = CGCompleteDisplayConfiguration(cfg, .permanently)
            print("moved virtual display to \(o): \(r.rawValue == 0 ? "ok" : "error \(r.rawValue)")")
            if placeOnly {
                // The move pins the display to this process; exiting is what releases it, and
                // macOS keeps the new position for the next display with this identity.
                Thread.sleep(forTimeInterval: hold)
                return r.rawValue == 0 ? 0 : 1
            }
        }
        Thread.sleep(forTimeInterval: hold)
        print("\n== active displays (after) ==")
        activeDisplays().forEach { describe($0, withModes: false) }
        print("\n== child-process view of \(vd.displayID) ==")
        runChildProbe(vd.displayID)

        print("\n== releasing ==")
        do {
            let t = try vd.release()
            print("display \(vd.displayID) gone after \(Int(t * 1000)) ms")
        } catch { print("\(error)"); return 1 }
        print("active now: \(activeDisplays())")
        return 0
    }

    static func activeDisplays() -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        CGGetOnlineDisplayList(32, &ids, &count)   // online: includes screens that are mirroring
        return Array(ids[..<Int(count)])
    }

    static func describe(_ id: CGDirectDisplayID, withModes: Bool) {
        let b = CGDisplayBounds(id)
        var line = "display \(id): bounds=(\(Int(b.minX)),\(Int(b.minY)) \(Int(b.width))x\(Int(b.height)) pt)"
        line += " pixels=\(CGDisplayPixelsWide(id))x\(CGDisplayPixelsHigh(id))"
        line += " vendor=0x\(String(CGDisplayVendorNumber(id), radix: 16)) model=0x\(String(CGDisplayModelNumber(id), radix: 16)) serial=\(CGDisplaySerialNumber(id))"
        line += CGDisplayIsMain(id) != 0 ? " MAIN" : ""
        if CGDisplayIsInMirrorSet(id) != 0 { line += " MIRRORSET(mirrors \(CGDisplayMirrorsDisplay(id)))" }
        if withModes {
            if let m = CGDisplayCopyDisplayMode(id) {
                line += " mode=\(m.pixelWidth)x\(m.pixelHeight)px/\(m.width)x\(m.height)pt@\(Int(m.refreshRate))"
            } else {
                line += " mode=NULL"
            }
        }
        print(line)
    }

    static func runChildProbe(_ id: CGDirectDisplayID) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        p.arguments = ["--probe", String(id)]
        let pipe = Pipe()
        p.standardOutput = pipe
        do {
            try p.run()
            p.waitUntilExit()
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            print(out.trimmingCharacters(in: .newlines))
        } catch { print("child probe failed: \(error)") }
    }

    private static func parseSize(_ s: String?) -> (Int, Int)? {
        guard let s = s else { return nil }
        let parts = s.lowercased().split(separator: "x").compactMap { Int($0) }
        return parts.count == 2 ? (parts[0], parts[1]) : nil
    }

    private static func ms(_ since: Date) -> Int { Int(Date().timeIntervalSince(since) * 1000) }
}
