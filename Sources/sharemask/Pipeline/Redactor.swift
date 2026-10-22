import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import Metal

protocol FrameProcessor: AnyObject {
    func process(_ src: CVPixelBuffer, regions: [PixelRegion]) -> CIImage
}

/// Core Image redaction. Builds a lazy filter graph per frame: for each region, filter the base
/// image, crop to the region, composite over the accumulator. Only region pixels are computed.
///
/// Coordinates: `PixelRegion.rect` is already in Core Image's bottom-left pixel space.
final class Redactor: FrameProcessor {
    enum PanicStyle { case pixellate, solid }

    let device: MTLDevice
    let context: CIContext
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Full-frame redaction, read on every frame with no debounce. Set from the hotkey thread.
    var panic: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _panic }
        set { lock.lock(); _panic = newValue; lock.unlock() }
    }
    var panicStyle: PanicStyle = .pixellate
    private var _panic = false
    private let lock = NSLock()

    init(device: MTLDevice) {
        self.device = device
        context = CIContext(mtlDevice: device, options: [
            .cacheIntermediates: false,
            .workingColorSpace: colorSpace,
            .outputColorSpace: colorSpace,
            .workingFormat: CIFormat.RGBA8,
            .name: "sharemask",
        ])
    }

    func process(_ src: CVPixelBuffer, regions: [PixelRegion]) -> CIImage {
        let base = CIImage(cvPixelBuffer: src)
        let frame = base.extent

        // Panic is unconditional and applied before any per-app region.
        if panic {
            switch panicStyle {
            case .pixellate: return Redactor.pixellate(base, rect: frame, scale: 64)
            case .solid: return CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: frame)
            }
        }
        guard !regions.isEmpty else { return base }

        var acc = base
        for region in regions {
            let rect = region.rect.intersection(frame).integral
            guard !rect.isNull, rect.width >= 1, rect.height >= 1 else { continue }
            let patch: CIImage
            switch region.mode {
            case .pixellate(let scale):
                patch = Redactor.pixellate(base, rect: rect, scale: scale)
            case .blur(let radius):
                patch = base.clampedToExtent()
                    .applyingGaussianBlur(sigma: Double(radius))
                    .cropped(to: rect)
            case .solid(let c):
                patch = CIImage(color: CIColor(red: c.r, green: c.g, blue: c.b, alpha: 1)).cropped(to: rect)
            }
            acc = patch.composited(over: acc)
        }
        return acc.cropped(to: frame)
    }

    /// Pixellates `rect` of `image`; block grid anchored to the rect origin so blocks align to it,
    /// and the filter sees the whole image so edge blocks don't sample transparency.
    static func pixellate(_ image: CIImage, rect: CGRect, scale: Int) -> CIImage {
        let f = CIFilter.pixellate()
        f.inputImage = image.clampedToExtent()
        f.scale = Float(max(2, scale))
        f.center = CGPoint(x: rect.minX, y: rect.minY)
        return (f.outputImage ?? image).cropped(to: rect)
    }
}
