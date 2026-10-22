import Foundation
import CoreAudio

/// Signals that a call is in progress, used to run capture (and macOS's recording indicator) only
/// while it matters.
///
/// Primary signal: the default audio *input* device is "running somewhere" — some process has the
/// microphone open. Meeting apps keep the input device open for the whole call, even when muted
/// in-app. Reading this CoreAudio property needs no microphone permission.
final class MeetingDetector {
    private(set) var micInUse = false
    /// Main thread.
    var onChange: ((Bool) -> Void)?

    private var defaultInput: AudioObjectID = kAudioObjectUnknown
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var defaultListener: AudioObjectPropertyListenerBlock?
    private let queue = DispatchQueue(label: "sharemask.meeting")
    private var pollTimer: DispatchSourceTimer?

    private static var runningAddr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    private static var defaultInputAddr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)

    func start() {
        guard pollTimer == nil else { return }
        defaultListener = { [weak self] _, _ in self?.queue.async { self?.rebindDevice() } }
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &MeetingDetector.defaultInputAddr,
                                            queue, defaultListener!)
        rebindDevice()
        // Belt and braces: listeners occasionally miss transitions after sleep/device swaps.
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 2, repeating: 2)
        t.setEventHandler { [weak self] in self?.refresh() }
        t.resume()
        pollTimer = t
    }

    func stop() {
        pollTimer?.cancel(); pollTimer = nil
        if let l = defaultListener {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &MeetingDetector.defaultInputAddr, queue, l)
            defaultListener = nil
        }
        unbindDevice()
    }

    private func rebindDevice() {
        unbindDevice()
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &MeetingDetector.defaultInputAddr, 0, nil, &size, &id)
        guard st == noErr, id != kAudioObjectUnknown else { refresh(); return }
        defaultInput = id
        deviceListener = { [weak self] _, _ in self?.refresh() }
        AudioObjectAddPropertyListenerBlock(id, &MeetingDetector.runningAddr, queue, deviceListener!)
        refresh()
    }

    private func unbindDevice() {
        if defaultInput != kAudioObjectUnknown, let l = deviceListener {
            AudioObjectRemovePropertyListenerBlock(defaultInput, &MeetingDetector.runningAddr, queue, l)
        }
        deviceListener = nil
        defaultInput = kAudioObjectUnknown
    }

    /// True if ANY input-capable device is running somewhere (not just the default one: Zoom may
    /// be using a headset while the default is the built-in mic).
    static func anyInputDeviceRunning() -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return false }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return false }
        for id in ids where hasInputStreams(id) && isRunningSomewhere(id) { return true }
        return false
    }

    private static func hasInputStreams(_ id: AudioObjectID) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                              mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr && size > 0
    }

    private static func isRunningSomewhere(_ id: AudioObjectID) -> Bool {
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &runningAddr, 0, nil, &size, &running) == noErr && running != 0
    }

    private func refresh() {
        let now = MeetingDetector.anyInputDeviceRunning()
        guard now != micInUse else { return }
        micInUse = now
        Log.info("meeting detector: microphone \(now ? "in use" : "idle")")
        DispatchQueue.main.async { self.onChange?(now) }
    }
}

// MARK: - Which app is using the microphone (macOS 14.2+)

extension MeetingDetector {
    /// Bundle IDs of processes currently running audio *input*, via CoreAudio process objects.
    /// Empty on older systems or when nothing is recording.
    static func bundleIDsUsingMicrophone() -> [String] {
        guard #available(macOS 14.2, *) else { return [] }
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        var out: [String] = []
        for id in ids {
            var runAddr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningInput,
                                                     mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var running: UInt32 = 0
            var rsize = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(id, &runAddr, 0, nil, &rsize, &running) == noErr, running != 0 else { continue }
            var bidAddr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID,
                                                     mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var bid: Unmanaged<CFString>?
            var bsize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            if AudioObjectGetPropertyData(id, &bidAddr, 0, nil, &bsize, &bid) == noErr, let b = bid?.takeRetainedValue() {
                let str = b as String
                if !str.isEmpty { out.append(str) }
            }
        }
        return Array(Set(out)).sorted()
    }
}
