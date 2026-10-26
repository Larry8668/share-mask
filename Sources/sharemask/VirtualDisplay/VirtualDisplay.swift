import Foundation
import CoreGraphics
import CGVirtualDisplayShim

/// Swift owner of the "sharemask" virtual display. Encodes the invariants measured for the private
/// API (macOS 26/27):
///
/// 1. `checkAPI()` must pass before anything else; a missing selector is a hard crash, not an error.
/// 2. The display's mode is NEVER changed after creation (no `CGDisplaySetDisplayMode`, no
///    `CGBeginDisplayConfiguration` on it). Any mode change makes it un-removable until exit.
/// 3. ONE fixed identity (name/vendor/product + serial hashed from (name, w, h)): macOS writes a
///    root-owned ICC profile per identity and never removes it, and restores the last-used mode
///    per identity.
/// 4. Mode reporting is broken in the creating process if it enumerated displays before creating.
///    Create first thing at launch; use `sharemask --probe <id>` (a child process) for mode info.
/// 5. Removal is asynchronous: `release()` polls `CGGetActiveDisplayList` until the ID is gone.
/// 6. The window server reclaims the display if the process dies; we still release on quit.
/// 7. Created at the source display's pixel size; see `Spec.forSource`.
final class VirtualDisplay {
    static let name = "sharemask"
    static let vendorID: UInt32 = 0x534D      // "SM"
    static let productID: UInt32 = 0x0001

    struct Spec: Equatable {
        var pixelsWide: UInt32
        var pixelsHigh: UInt32
        var modeWidth: UInt32
        var modeHeight: UInt32
        var hiDPI: Bool
        var refreshHz: Double = 60
        var dpi: Double = 110
        /// Identity. Defaults are sharemask's fixed identity (invariant 3); only the test "fake TV"
        /// (probe --fake-tv) overrides them.
        var name: String = VirtualDisplay.name
        var vendor: UInt32 = VirtualDisplay.vendorID
        var product: UInt32 = VirtualDisplay.productID

        /// The advertised pixel size; the display comes up at `modeWidth × modeHeight` points.
        ///
        /// macOS chooses the initial mode from the physical size: at ~110 DPI a (W,H) mode is
        /// entered at 1× so the display runs at the full W×H pixel count (what we want: the shared
        /// frame is pixel-exact). At ~220 DPI it would come up "looks like" W/2×H/2 instead.
        static func forSource(pixelsWide w: Int, pixelsHigh h: Int, hiDPI: Bool = false) -> Spec {
            Spec(pixelsWide: UInt32(w), pixelsHigh: UInt32(h), modeWidth: UInt32(w), modeHeight: UInt32(h),
                 hiDPI: hiDPI)
        }

        var widthMM: Double { Double(modeWidth) / dpi * 25.4 }
        var heightMM: Double { Double(modeHeight) / dpi * 25.4 }
        var serial: UInt32 { VirtualDisplay.stableSerial(name: name, w: Int(modeWidth), h: Int(modeHeight)) }

        var cSpec: SMVirtualDisplaySpec {
            SMVirtualDisplaySpec(maxPixelsWide: pixelsWide, maxPixelsHigh: pixelsHigh,
                                 modeWidth: modeWidth, modeHeight: modeHeight, refreshHz: refreshHz,
                                 hiDPI: hiDPI ? 1 : 0, widthMM: widthMM, heightMM: heightMM,
                                 vendorID: vendor, productID: product,
                                 serial: serial)
        }
    }

    enum Error: Swift.Error, CustomStringConvertible {
        case apiMissing(String)
        case createFailed(String)
        case removalTimedOut(CGDirectDisplayID)

        var description: String {
            switch self {
            case .apiMissing(let s): return "Private virtual display API unavailable on this macOS: missing \(s)"
            case .createFailed(let s): return "Could not create virtual display: \(s)"
            case .removalTimedOut(let id): return "Virtual display \(id) did not disappear within the timeout"
            }
        }
    }

    let displayID: CGDirectDisplayID
    let spec: Spec
    let reportedHiDPI: UInt32
    private(set) var handle: SMVirtualDisplayHandle?
    private(set) var createdAt = Date()

    /// Invariant 1. Cheap; call at launch and refuse to run the pipeline if it throws.
    static func checkAPI() throws {
        var missing: NSString?
        if !SMVirtualDisplayAPIAvailable(&missing) {
            throw Error.apiMissing(missing as String? ?? "unknown")
        }
    }

    /// Invariant 4: call this BEFORE any display enumeration in this process.
    static func create(spec: Spec) throws -> VirtualDisplay {
        try checkAPI()
        var error: NSString?
        guard let handle = SMVirtualDisplayCreate(spec.name, spec.cSpec, &error) else {
            throw Error.createFailed(error as String? ?? "unknown error")
        }
        return VirtualDisplay(handle: handle, spec: spec)
    }

    private init(handle: SMVirtualDisplayHandle, spec: Spec) {
        self.handle = handle
        self.displayID = handle.displayID
        self.spec = spec
        self.reportedHiDPI = handle.reportedHiDPI
    }

    var isValid: Bool { handle?.isValid ?? false }

    /// Pixel size the window server reports right now (works even when mode reporting is broken).
    var currentPixelSize: CGSize {
        CGSize(width: CGDisplayPixelsWide(displayID), height: CGDisplayPixelsHigh(displayID))
    }

    /// Bounds in global points, top-left origin.
    var bounds: CGRect { CGDisplayBounds(displayID) }

    /// Safety: the proxy must never be the main display or part of a mirror set with a real
    /// display, otherwise its black presenter window would cover the user's own screen.
    var isSafeToPresent: Bool {
        CGDisplayIsMain(displayID) == 0 && CGDisplayIsInMirrorSet(displayID) == 0
    }

    static func isActive(_ id: CGDirectDisplayID) -> Bool {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(32, &ids, &count) == .success else { return false }
        return ids[..<Int(count)].contains(id)
    }

    /// Invariant 5. Releases the display and blocks (polling every 50 ms) until the window server
    /// has removed it. Returns the time it took. Expect ~0.1–2 s.
    @discardableResult
    func release(timeout: TimeInterval = 5) throws -> TimeInterval {
        guard let h = handle else { return 0 }
        let start = Date()
        h.invalidate()
        handle = nil
        while Date().timeIntervalSince(start) < timeout {
            if !VirtualDisplay.isActive(displayID) { return Date().timeIntervalSince(start) }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw Error.removalTimedOut(displayID)
    }

    /// Non-blocking release for app (AppKit) use. The process's view of the active display list
    /// only refreshes when the main run loop turns, so polling it while blocking the main thread
    /// (as `release()` does) never sees the display go and always times out. This polls from the
    /// main run loop instead. `completion(seconds)` is nil on timeout. Main thread.
    func releaseAsync(timeout: TimeInterval = 5, completion: @escaping (TimeInterval?) -> Void) {
        guard let h = handle else { completion(0); return }
        let start = Date()
        h.invalidate()
        handle = nil
        let id = displayID
        func poll() {
            let t = Date().timeIntervalSince(start)
            if !VirtualDisplay.isActive(id) { completion(t); return }
            if t > timeout { completion(nil); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: poll)
        }
        DispatchQueue.main.async(execute: poll)
    }

    /// FNV-1a over "name:w:h" — stable across launches and machines (invariant 3).
    static func stableSerial(name: String, w: Int, h: Int) -> UInt32 {
        var hash: UInt32 = 2166136261
        for byte in "\(name):\(w):\(h)".utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16777619
        }
        return hash == 0 ? 1 : hash
    }
}
