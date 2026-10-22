import Foundation
import CoreGraphics

/// A rectangle to redact in the captured frame.
///
/// `rect` is in **frame pixels with a bottom-left origin** (Core Image convention). The capture
/// buffer and `CGWindowList` are top-left; `RegionResolver` is the single place that converts.
struct PixelRegion: Equatable {
    var rect: CGRect
    var mode: RedactMode
    var shape: RegionShape = .rect
}

/// Geometry of the captured (source) display.
struct DisplayGeometry: Equatable {
    /// Global bounds in points, top-left origin (as returned by `CGDisplayBounds`).
    var boundsPoints: CGRect
    /// Backing scale factor (2 on Retina).
    var scale: CGFloat
    /// Pixel size of the captured frame (`CGDisplayPixelsWide/High`).
    var pixelSize: CGSize
}

/// One on-screen window from `CGWindowListCopyWindowInfo`, in front-to-back order.
struct TrackedWindow: Equatable {
    var windowID: CGWindowID
    var pid: pid_t
    var bundleID: String?
    /// Global bounds in points, top-left origin (`kCGWindowBounds`).
    var boundsPoints: CGRect
    /// `kCGWindowLayer`; 0 = normal application windows.
    var layer: Int
    var alpha: CGFloat
    /// `kCGWindowSharingState`: 0 = not captured by screen recording (sharingType .none).
    var sharingState: Int
    /// `kCGWindowName` (only available with Screen Recording permission).
    var title: String? = nil

    var isNormalVisible: Bool { layer == 0 && alpha > 0 && boundsPoints.width > 0 && boundsPoints.height > 0 }
}

/// Per-frame switches the user can flip without touching presets.json.
struct ResolveOptions: Equatable {
    /// Everything masked except `presets.allowlist` (+ `revealed`).
    var allowlistMode = false
    /// Bundle IDs temporarily shown in full (hold-to-reveal).
    var revealed: Set<String> = []
    /// Temporarily disabled masks: "bundleID" (whole app), "bundleID/regionName" or "rule:<name>".
    var disabled: Set<String> = []
}

/// Pure function: presets × window geometry → pixel rects for this frame.
enum RegionResolver {
    static let maxRegionsPerFrame = 64
    static let notificationCenterBundleID = "com.apple.notificationcenterui"

    static func resolve(presets: PresetConfig,
                        windows: [TrackedWindow],
                        display: DisplayGeometry,
                        frontmostBundleID: String?,
                        ignorePIDs: Set<pid_t> = [],
                        options: ResolveOptions = ResolveOptions(),
                        maxRegions: Int = maxRegionsPerFrame) -> [PixelRegion] {
        var out: [PixelRegion] = []
        var overflow: [PixelRegion] = []
        let frame = CGRect(origin: .zero, size: display.pixelSize)

        func emit(_ pieces: [CGRect], unoccluded: CGRect, mode: RedactMode, shape: RegionShape = .rect) {
            if out.count + pieces.count > maxRegions {
                overflow.append(PixelRegion(rect: toPixels(unoccluded, display: display), mode: mode))
                return
            }
            for piece in pieces { out.append(PixelRegion(rect: toPixels(piece, display: display), mode: mode, shape: shape)) }
        }

        // 1. Allowlist mode: mask the whole frame except the visible parts of allowed windows.
        if options.allowlistMode {
            let allowed = Set(presets.allowlist).union(options.revealed)
            var visible: [CGRect] = []
            for (index, w) in windows.enumerated() where w.isNormalVisible && !ignorePIDs.contains(w.pid) {
                guard let b = w.bundleID, allowed.contains(b) else { continue }
                var pieces = [w.boundsPoints.intersection(display.boundsPoints)].filter { !$0.isNull && $0.width > 0 && $0.height > 0 }
                for front in windows[..<index] where front.isNormalVisible && !ignorePIDs.contains(front.pid)
                        && !(front.bundleID.map { allowed.contains($0) } ?? false) && front.boundsPoints.intersects(w.boundsPoints) {
                    pieces = pieces.flatMap { subtract(front.boundsPoints, from: $0) }
                }
                visible.append(contentsOf: pieces)
            }
            var masked = [display.boundsPoints]
            for v in visible { masked = masked.flatMap { subtract(v, from: $0) } }
            if masked.count > maxRegions / 2 {
                // Too fragmented: mask everything (safe) — the user can reveal fewer apps.
                out.append(PixelRegion(rect: frame, mode: presets.defaultMode))
            } else {
                emit(masked, unoccluded: display.boundsPoints, mode: presets.defaultMode)
            }
        }

        // 2. Per-app presets and title rules.
        for (index, window) in windows.enumerated() {
            guard window.isNormalVisible, !ignorePIDs.contains(window.pid) else { continue }
            let bundleID = window.bundleID ?? ""
            if options.revealed.contains(bundleID) || options.disabled.contains(bundleID) { continue }

            var regions: [(PresetRegion, String)] = []   // (region, disable key)
            if let app = presets.apps[bundleID], !(app.whenFrontmostOnly && frontmostBundleID != bundleID) {
                regions += app.regions.map { ($0, "\(bundleID)/\($0.name)") }
            }
            for rule in presets.rules where rule.matches(window) && !(rule.whenFrontmostOnly && frontmostBundleID != bundleID)
                    && !options.disabled.contains("rule:\(rule.name)") {
                regions += rule.regions.map { ($0, "rule:\(rule.name)/\($0.name)") }
            }
            guard !regions.isEmpty else { continue }

            // Occluders: everything in front of this window (lower index) that is actually drawn
            // into the capture. Windows whose sharing state is .none are invisible to capture, so the
            // content *under* them leaks into the feed: they must not count as occluders.
            let occluders = windows[..<index].filter {
                $0.isNormalVisible && $0.windowID != window.windowID && $0.sharingState != 0
                    && !ignorePIDs.contains($0.pid) && $0.boundsPoints.intersects(window.boundsPoints)
            }

            for (region, key) in regions {
                if options.disabled.contains(key) { continue }
                let w = window.boundsPoints
                let absolute = CGRect(x: w.minX + region.rect.minX * w.width,
                                      y: w.minY + region.rect.minY * w.height,
                                      width: region.rect.width * w.width,
                                      height: region.rect.height * w.height)
                let clipped = absolute.intersection(display.boundsPoints)
                guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { continue }

                var pieces = [clipped]
                for occluder in occluders {
                    pieces = pieces.flatMap { subtract(occluder.boundsPoints, from: $0) }
                    if pieces.isEmpty { break }
                }
                // An ellipse survives as an ellipse only if nothing cut into it; otherwise the
                // remaining rect pieces are used (over-redacts the ellipse's corners, never under).
                if region.shape == .ellipse, pieces.count == 1, pieces[0] == clipped, clipped == absolute {
                    emit([clipped], unoccluded: clipped, mode: region.mode, shape: .ellipse)
                    continue
                }
                emit(pieces, unoccluded: clipped, mode: region.mode)
            }
        }

        // 3. Notification banners: Notification Center windows of any layer, black box, no
        //    occlusion (they are above everything). Large windows (the opened panel) are skipped
        //    only if they'd cover more than a third of the display — they then get masked too.
        if presets.maskNotifications && !options.disabled.contains(notificationCenterBundleID) {
            for w in windows where w.bundleID == notificationCenterBundleID && w.alpha > 0 {
                let r = w.boundsPoints.intersection(display.boundsPoints)
                guard !r.isNull, r.width > 8, r.height > 8 else { continue }
                emit([r], unoccluded: r, mode: .solid(color: .black))
            }
        }

        if !overflow.isEmpty {
            // Last resort: collapse every overflowing rect into one bounding box (over-redaction is
            // always the safe direction).
            let union = overflow.dropFirst().reduce(overflow[0].rect) { $0.union($1.rect) }
            if out.count < maxRegions {
                out.append(PixelRegion(rect: union, mode: overflow[0].mode))
            } else {
                out[maxRegions - 1] = PixelRegion(rect: out[maxRegions - 1].rect.union(union), mode: .solid(color: .black))
            }
        }
        return out
    }

    /// Converts a rect in global points (top-left origin) to frame pixels in Core Image's
    /// bottom-left origin, snapped outwards to whole pixels so no sub-pixel sliver leaks.
    static func toPixels(_ r: CGRect, display: DisplayGeometry) -> CGRect {
        let s = display.scale
        let x0 = floor((r.minX - display.boundsPoints.minX) * s)
        let x1 = ceil((r.maxX - display.boundsPoints.minX) * s)
        let yTop0 = floor((r.minY - display.boundsPoints.minY) * s)
        let yTop1 = ceil((r.maxY - display.boundsPoints.minY) * s)
        let h = display.pixelSize.height
        let flipped = CGRect(x: x0, y: h - yTop1, width: x1 - x0, height: yTop1 - yTop0)
        let frame = CGRect(origin: .zero, size: display.pixelSize)
        let clipped = flipped.intersection(frame)
        return clipped.isNull ? .zero : clipped
    }

    /// `a` minus `b` as at most four non-overlapping rects (top, bottom, left, right bands).
    static func subtract(_ b: CGRect, from a: CGRect) -> [CGRect] {
        let i = a.intersection(b)
        guard !i.isNull, i.width > 0, i.height > 0 else { return [a] }
        var result: [CGRect] = []
        if i.minY > a.minY {  // band above the hole (smaller y)
            result.append(CGRect(x: a.minX, y: a.minY, width: a.width, height: i.minY - a.minY))
        }
        if i.maxY < a.maxY {  // band below the hole
            result.append(CGRect(x: a.minX, y: i.maxY, width: a.width, height: a.maxY - i.maxY))
        }
        if i.minX > a.minX {  // left of the hole, limited to the hole's rows
            result.append(CGRect(x: a.minX, y: i.minY, width: i.minX - a.minX, height: i.height))
        }
        if i.maxX < a.maxX {  // right of the hole
            result.append(CGRect(x: i.maxX, y: i.minY, width: a.maxX - i.maxX, height: i.height))
        }
        return result.filter { $0.width > 0 && $0.height > 0 }
    }
}
