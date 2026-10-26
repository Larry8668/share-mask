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
        process(src, regions: regions, patchesOnly: false)
    }

    /// `patchesOnly`: return just the redacted patches on a transparent background (overlay mode);
    /// panic still returns a full opaque frame.
    func process(_ src: CVPixelBuffer, regions: [PixelRegion], patchesOnly: Bool) -> CIImage {
        let base = CIImage(cvPixelBuffer: src)
        let frame = base.extent

        // Panic is unconditional and applied before any per-app region.
        if panic {
            switch panicStyle {
            case .pixellate: return Redactor.pixellate(base, rect: frame, scale: 64)
            case .solid: return CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: frame)
            }
        }
        let clear = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: frame)
        guard !regions.isEmpty else { return patchesOnly ? clear : base }

        var acc = patchesOnly ? clear : base
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
            if region.shape == .ellipse {
                let mask = ellipseMask(for: rect)
                let blend = CIFilter.blendWithMask()
                blend.inputImage = patch
                blend.backgroundImage = acc
                blend.maskImage = mask
                acc = blend.outputImage ?? patch.composited(over: acc)
            } else {
                acc = patch.composited(over: acc)
            }
        }
        return acc.cropped(to: frame)
    }

    private var maskCache: [String: CIImage] = [:]

    /// White ellipse on transparent, positioned at `rect` in frame coordinates. Cached per rect.
    private func ellipseMask(for rect: CGRect) -> CIImage {
        let key = "\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height))"
        lock.lock(); defer { lock.unlock() }
        if let m = maskCache[key] { return m }
        if maskCache.count > 64 { maskCache.removeAll() }
        let w = max(1, Int(rect.width)), h = max(1, Int(rect.height))
        let cs = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            return CIImage(color: .white).cropped(to: rect)
        }
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fillEllipse(in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let cg = ctx.makeImage() else { return CIImage(color: .white).cropped(to: rect) }
        let img = CIImage(cgImage: cg).transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY))
        maskCache[key] = img
        return img
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
