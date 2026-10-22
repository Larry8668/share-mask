import AppKit
import CoreGraphics

/// Polls the window server for on-screen window geometry (front-to-back) every 100 ms and keeps the
/// latest snapshot. Window geometry doesn't need per-frame accuracy: 100 ms of lag on a drag is
/// invisible on a 30 fps call. An app activation triggers an immediate re-poll.
final class WindowTracker {
    struct Snapshot {
        var windows: [TrackedWindow]
        var frontmostBundleID: String?
        var timestamp: TimeInterval
    }

    private let lock = NSLock()
    private var snapshot = Snapshot(windows: [], frontmostBundleID: nil, timestamp: 0)
    private var bundleCache: [pid_t: String?] = [:]
    private let queue = DispatchQueue(label: "sharemask.windowtracker", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var observer: NSObjectProtocol?
    var interval: TimeInterval = 0.1

    var latest: Snapshot {
        lock.lock(); defer { lock.unlock() }
        return snapshot
    }

    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(10))
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil
        ) { [weak self] _ in self?.queue.async { self?.poll() } }
    }

    func stop() {
        timer?.cancel(); timer = nil
        if let o = observer { NSWorkspace.shared.notificationCenter.removeObserver(o); observer = nil }
    }

    func pollNow() { queue.async { self.poll() } }

    private func poll() {
        let windows = WindowTracker.copyOnScreenWindows(bundleCache: &bundleCache)
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        lock.lock()
        snapshot = Snapshot(windows: windows, frontmostBundleID: front, timestamp: CACurrentMediaTime())
        lock.unlock()
    }

    /// Reads `CGWindowListCopyWindowInfo` and maps it to `TrackedWindow`s in z-order (front first).
    static func copyOnScreenWindows(bundleCache: inout [pid_t: String?]) -> [TrackedWindow] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        var result: [TrackedWindow] = []
        result.reserveCapacity(list.count)
        for info in list {
            guard let number = info[kCGWindowNumber as String] as? UInt32,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { continue }
            let layer = info[kCGWindowLayer as String] as? Int ?? 0
            let alpha = info[kCGWindowAlpha as String] as? CGFloat ?? 1
            let sharing = info[kCGWindowSharingState as String] as? Int ?? 1
            let title = info[kCGWindowName as String] as? String
            let bundle: String?
            if let cached = bundleCache[pid] {
                bundle = cached
            } else {
                bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
                bundleCache[pid] = .some(bundle)
            }
            result.append(TrackedWindow(windowID: number, pid: pid, bundleID: bundle, boundsPoints: bounds,
                                        layer: layer, alpha: alpha, sharingState: sharing, title: title))
        }
        // PIDs come and go; keep the cache bounded.
        if bundleCache.count > 512 { bundleCache.removeAll() }
        return result
    }
}
