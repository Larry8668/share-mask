import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo

protocol FrameSource: AnyObject {
    func start(onFrame: @escaping (CVPixelBuffer, CMTime) -> Void) async throws
    func stop() async
}

enum CaptureError: Error, CustomStringConvertible {
    case permissionDenied
    case displayNotFound(CGDirectDisplayID)
    var description: String {
        switch self {
        case .permissionDenied: return "Screen Recording permission is required (System Settings → Privacy & Security → Screen & System Audio Recording)"
        case .displayNotFound(let id): return "Display \(id) is not available for capture"
        }
    }
}

/// ScreenCaptureKit wrapper capturing one whole display (cursor, menu bar, Spaces and z-order for
/// free). Frames are delivered on a dedicated serial queue; sharemask's own windows are excluded.
final class Capture: NSObject, FrameSource, SCStreamOutput, SCStreamDelegate {
    let displayID: CGDirectDisplayID
    private(set) var pixelSize: CGSize
    private let queue = DispatchQueue(label: "sharemask.capture", qos: .userInteractive)
    private var stream: SCStream?
    private var onFrame: ((CVPixelBuffer, CMTime) -> Void)?
    /// Invoked (on an arbitrary queue) when the stream stops on its own.
    var onStopped: ((Error?) -> Void)?
    var frameRate = 60

    init(displayID: CGDirectDisplayID, pixelSize: CGSize) {
        self.displayID = displayID
        self.pixelSize = pixelSize
    }

    func start(onFrame: @escaping (CVPixelBuffer, CMTime) -> Void) async throws {
        self.onFrame = onFrame
        if !CGPreflightScreenCaptureAccess() {
            // Prompts once (TCC remembers the answer, keyed by our stable code signature).
            if !CGRequestScreenCaptureAccess() { throw CaptureError.permissionDenied }
        }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            if (error as NSError).domain == SCStreamErrorDomain,
               (error as NSError).code == SCStreamError.Code.userDeclined.rawValue {
                throw CaptureError.permissionDenied
            }
            throw error
        }
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.displayNotFound(displayID)
        }
        let me = content.applications.filter { $0.processID == getpid() }
        let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.width = Int(pixelSize.width)
        config.height = Int(pixelSize.height)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        config.showsCursor = true
        config.queueDepth = 5
        config.colorSpaceName = CGColorSpace.sRGB
        config.capturesAudio = false
        config.captureResolution = .best
        config.streamName = "sharemask proxy"
        if #available(macOS 14.2, *) { config.includeChildWindows = true }

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
        Log.info("capture started: display \(displayID) \(Int(pixelSize.width))x\(Int(pixelSize.height)) @\(frameRate)")
    }

    func stop() async {
        guard let s = stream else { return }
        stream = nil
        do { try await s.stopCapture() } catch { Log.warn("stopCapture: \(error)") }
    }

    /// Call when the source display's pixel size changed; the caller restarts the stream.
    func updatePixelSize(_ size: CGSize) { pixelSize = size }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRaw), status == .complete,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }
        onFrame?(pixelBuffer, CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.error("capture stream stopped: \(error)")
        self.stream = nil
        onStopped?(error)
    }
}
