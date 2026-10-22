import AppKit
import CoreImage

/// "What others see": a small always-on-top window on the real display showing the proxy output.
/// `sharingType = .none` so the preview itself never appears in the share.
final class PreviewWindow {
    private var window: NSWindow?
    private let imageView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var lastSize = CGSize.zero
    var isVisible: Bool { window?.isVisible ?? false }

    func toggle(sourceDisplayID: CGDirectDisplayID) {
        if isVisible { hide() } else { show(sourceDisplayID: sourceDisplayID) }
    }

    func show(sourceDisplayID: CGDirectDisplayID) {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 234 + 22),
                             styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel], backing: .buffered, defer: false)
            w.title = "What others see"
            w.level = .floating
            w.sharingType = .none
            w.isReleasedWhenClosed = false
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            w.hidesOnDeactivate = false
            w.contentAspectRatio = NSSize(width: 16, height: 10)
            let content = NSView(frame: w.contentView!.bounds)
            content.wantsLayer = true
            content.layer?.backgroundColor = NSColor.black.cgColor
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.frame = NSRect(x: 0, y: 22, width: content.bounds.width, height: content.bounds.height - 22)
            imageView.autoresizingMask = [.width, .height]
            label.frame = NSRect(x: 8, y: 3, width: content.bounds.width - 16, height: 16)
            label.autoresizingMask = [.width]
            label.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
            label.textColor = .secondaryLabelColor
            content.addSubview(imageView)
            content.addSubview(label)
            w.contentView = content
            let b = CGDisplayBounds(sourceDisplayID)
            let primaryH = CGDisplayBounds(CGMainDisplayID()).height
            w.setFrameOrigin(NSPoint(x: b.maxX - 360 - 20, y: primaryH - b.maxY + 60))
            window = w
        }
        window?.orderFrontRegardless()
    }

    func hide() { window?.orderOut(nil) }

    /// Main thread. Downscales the proxy frame to the preview size (cheap: ~10 Hz).
    func update(_ image: CIImage, status: String) {
        guard isVisible else { return }
        let target = imageView.bounds.size
        guard target.width > 0 else { return }
        let scale = min(target.width * 2 / image.extent.width, target.height * 2 / image.extent.height)
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        if let cg = context.createCGImage(small, from: small.extent) {
            imageView.image = NSImage(cgImage: cg, size: NSSize(width: small.extent.width / 2, height: small.extent.height / 2))
        }
        label.stringValue = status
    }

    func setStatus(_ status: String) { label.stringValue = status }
}
