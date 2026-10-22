import Foundation
import CoreMedia
import QuartzCore

/// Latency + fps instrumentation. All times in milliseconds.
///
/// - `captureToPresent`: SCK sample timestamp → command buffer committed (what the viewer feels).
/// - `pipeline`: our callback entry → committed (what we control).
/// - `gpu`: MTLCommandBuffer gpuEndTime - gpuStartTime.
final class FrameClock {
    struct Summary: CustomStringConvertible {
        var fps: Double
        var captureToPresentP50: Double, captureToPresentP95: Double
        var pipelineP50: Double, pipelineP95: Double
        var gpuP50: Double, gpuP95: Double
        var dropped: Int

        var description: String {
            String(format: "%.0f fps · latency %.0f/%.0f ms (p50/p95) · pipeline %.1f/%.1f ms · GPU %.1f/%.1f ms · dropped %d",
                   fps, captureToPresentP50, captureToPresentP95, pipelineP50, pipelineP95, gpuP50, gpuP95, dropped)
        }
        static let zero = Summary(fps: 0, captureToPresentP50: 0, captureToPresentP95: 0, pipelineP50: 0,
                                  pipelineP95: 0, gpuP50: 0, gpuP95: 0, dropped: 0)
    }

    private let lock = NSLock()
    private var captureToPresent: [Double] = []
    private var pipeline: [Double] = []
    private var gpu: [Double] = []
    private var frameTimes: [Double] = []
    private var droppedCount = 0
    private let capacity = 240
    private var lastLog = CACurrentMediaTime()
    var logInterval: TimeInterval = 5

    static func hostSeconds() -> Double { CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock())) }

    /// Called when a frame has been committed to the GPU.
    func recordPresented(samplePTS: CMTime, callbackEntry: Double) {
        let now = FrameClock.hostSeconds()
        let c2p = (now - CMTimeGetSeconds(samplePTS)) * 1000
        lock.lock()
        if c2p.isFinite, c2p >= 0, c2p < 1000 { push(&captureToPresent, c2p) }
        push(&pipeline, (now - callbackEntry) * 1000)
        push(&frameTimes, now)
        let shouldLog = now - lastLog >= logInterval
        if shouldLog { lastLog = now }
        lock.unlock()
        if shouldLog { Log.info("frameclock: \(summary())") }
    }

    func recordGPU(seconds: Double) {
        lock.lock(); push(&gpu, seconds * 1000); lock.unlock()
    }

    func recordDropped() { lock.lock(); droppedCount += 1; lock.unlock() }

    func summary() -> Summary {
        lock.lock(); defer { lock.unlock() }
        let now = FrameClock.hostSeconds()
        let recent = frameTimes.filter { now - $0 <= 2 }
        let fps = recent.count >= 2 ? Double(recent.count - 1) / max(0.001, recent.last! - recent.first!) : 0
        return Summary(fps: fps,
                       captureToPresentP50: pct(captureToPresent, 0.5), captureToPresentP95: pct(captureToPresent, 0.95),
                       pipelineP50: pct(pipeline, 0.5), pipelineP95: pct(pipeline, 0.95),
                       gpuP50: pct(gpu, 0.5), gpuP95: pct(gpu, 0.95), dropped: droppedCount)
    }

    private func push(_ a: inout [Double], _ v: Double) {
        a.append(v)
        if a.count > capacity { a.removeFirst(a.count - capacity) }
    }

    private func pct(_ a: [Double], _ p: Double) -> Double {
        guard !a.isEmpty else { return 0 }
        let s = a.sorted()
        return s[min(s.count - 1, Int(Double(s.count - 1) * p + 0.5))]
    }
}
