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

        while let a = args.popFirst() {
            switch a {
            case "--no-create": create = false
            case "--hidpi": hiDPI = (args.popFirst() ?? "0") != "0"
            case "--dpi": dpi = Double(args.popFirst() ?? "") ?? dpi
            case "--hold": hold = Double(args.popFirst() ?? "") ?? hold
            case "--mode": mode = parseSize(args.popFirst())
            case "--max": maxPx = parseSize(args.popFirst())
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
        CGGetActiveDisplayList(32, &ids, &count)
        return Array(ids[..<Int(count)])
    }

    static func describe(_ id: CGDirectDisplayID, withModes: Bool) {
        let b = CGDisplayBounds(id)
        var line = "display \(id): bounds=(\(Int(b.minX)),\(Int(b.minY)) \(Int(b.width))x\(Int(b.height)) pt)"
        line += " pixels=\(CGDisplayPixelsWide(id))x\(CGDisplayPixelsHigh(id))"
        line += " vendor=0x\(String(CGDisplayVendorNumber(id), radix: 16)) model=0x\(String(CGDisplayModelNumber(id), radix: 16)) serial=\(CGDisplaySerialNumber(id))"
        line += CGDisplayIsMain(id) != 0 ? " MAIN" : ""
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
