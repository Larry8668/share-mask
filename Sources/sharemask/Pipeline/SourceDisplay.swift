import AppKit
import CoreGraphics

/// Geometry of the display being captured (the user's real main display).
struct SourceDisplay: Equatable {
    var id: CGDirectDisplayID
    var geometry: DisplayGeometry

    /// Reads the current geometry from the window server. Uses the display mode for pixel size:
    /// `CGDisplayPixelsWide` returns points on Retina displays.
    static func current(id: CGDirectDisplayID = CGMainDisplayID()) -> SourceDisplay {
        let bounds = CGDisplayBounds(id)
        var pixels = CGSize(width: CGDisplayPixelsWide(id), height: CGDisplayPixelsHigh(id))
        if let mode = CGDisplayCopyDisplayMode(id) {
            pixels = CGSize(width: mode.pixelWidth, height: mode.pixelHeight)
        }
        let scale = bounds.width > 0 ? (pixels.width / bounds.width).rounded() : 1
        return SourceDisplay(id: id, geometry: DisplayGeometry(boundsPoints: bounds, scale: max(1, scale), pixelSize: pixels))
    }
}
