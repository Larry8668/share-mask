import Foundation
import CoreGraphics

/// A rectangle to redact in the captured frame.
///
/// `rect` is in **frame pixels with a bottom-left origin** (Core Image convention). The capture
/// buffer and `CGWindowList` are top-left; `RegionResolver` is the single place that converts.
struct PixelRegion: Equatable {
    var rect: CGRect
    var mode: RedactMode
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

    var isNormalVisible: Bool { layer == 0 && alpha > 0 && boundsPoints.width > 0 && boundsPoints.height > 0 }
}

/// Pure function: presets × window geometry → pixel rects for this frame.
enum RegionResolver {
    static let maxRegionsPerFrame = 64

    static func resolve(presets: PresetConfig,
                        windows: [TrackedWindow],
                        display: DisplayGeometry,
                        frontmostBundleID: String?,
                        ignorePIDs: Set<pid_t> = [],
                        maxRegions: Int = maxRegionsPerFrame) -> [PixelRegion] {
        var out: [PixelRegion] = []
        var overflow: [PixelRegion] = []

        for (index, window) in windows.enumerated() {
            guard window.isNormalVisible, !ignorePIDs.contains(window.pid),
                  let bundleID = window.bundleID, let app = presets.apps[bundleID] else { continue }
            if app.whenFrontmostOnly && frontmostBundleID != bundleID { continue }

            // Occluders: everything in front of this window (lower index) that is actually drawn
            // into the capture. Windows whose sharing state is .none are invisible to capture, so the
            // content *under* them leaks into the feed: they must not count as occluders.
            let occluders = windows[..<index].filter {
                $0.isNormalVisible && $0.windowID != window.windowID && $0.sharingState != 0
                    && !ignorePIDs.contains($0.pid) && $0.boundsPoints.intersects(window.boundsPoints)
            }

            for region in app.regions {
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

                // Safety: if the subtraction produced too many pieces, over-redact with the
                // unoccluded rect rather than drop anything.
                if out.count + pieces.count > maxRegions {
                    overflow.append(PixelRegion(rect: toPixels(clipped, display: display), mode: region.mode))
                    continue
                }
                for piece in pieces {
                    out.append(PixelRegion(rect: toPixels(piece, display: display), mode: region.mode))
                }
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
