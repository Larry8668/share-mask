import AppKit
import EventKit

/// Turns raw signals (microphone in use, someone capturing the screen, an imminent calendar event)
/// into "meeting started / ended" decisions and drives the pipeline's auto-capture gate.
///
/// Policy (mode `ask`, the default):
///   signal rises  → prompt "Meeting detected — start proxy?" (auto-starts in mode `auto`)
///   signal falls  → after a 15 s grace, verify nobody else is capturing (0.5 s pause), then stop
///                   and show a short "stopped" notice
/// Modes `always` / `manual` only log the signals.
final class MeetingCoordinator {
    private let detector = MeetingDetector()
    /// Shared with the app's own prompts (TV connected, alerts) so two prompts never stack.
    private let prompt: PromptPanel
    /// True while the "someone is capturing the screen" signal can't be trusted: an AirPlay screen
    /// is connected (AirPlay itself is a screen-capture session), we're presenting to a TV, or
    /// displays changed in the last few seconds.
    var ignoreWatcher: (() -> Bool)?
    private weak var pipeline: Pipeline?
    private var pollTimer: Timer?
    private var endGrace: DispatchWorkItem?
    private var declinedForThisSignal = false
    private var startedByUs = false
    private var lastSignal = false
    private var calendarStore: EKEventStore?
    private var promptedEventIDs: Set<String> = []
    private var lastCalendarCheck = Date.distantPast

    var mode: Pipeline.CaptureMode = .auto
    var calendarLookahead = false { didSet { if calendarLookahead && !oldValue { requestCalendarAccess() } } }
    /// Main thread; called whenever the detector's view of "in a meeting" changes.
    var onStatus: ((String) -> Void)?
    /// Screens to offer in the start prompt (names, selected index) and the handler for the pick.
    var screenChoices: (() -> (names: [String], selected: Int))?
    var onChooseScreen: ((Int) -> Void)?
    private(set) var statusText = "no meeting detected"

    init(pipeline: Pipeline, prompt: PromptPanel) {
        self.prompt = prompt
        self.pipeline = pipeline
    }

    func start() {
        detector.onChange = { [weak self] _ in self?.evaluate() }
        detector.start()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.evaluate() }
        evaluate()
    }

    func stop() {
        detector.stop()
        pollTimer?.invalidate(); pollTimer = nil
        prompt.dismiss()
    }

    // MARK: Signals

    private var micUsers: [String] { MeetingDetector.bundleIDsUsingMicrophone().filter { $0 != Bundle.main.bundleIdentifier } }

    private func evaluate() {
        guard let p = pipeline else { return }
        let mic = detector.micInUse
        let users = mic ? micUsers : []
        let watcher = p.someoneElseIsCapturing && !(ignoreWatcher?() ?? false)   // only meaningful while our capture is off
        let signal = mic || watcher
        let who = users.map { appName($0) }.joined(separator: ", ")
        statusText = signal ? (mic ? "call detected (\(who.isEmpty ? "microphone in use" : who))" : "screen share detected")
                            : "no meeting detected"
        onStatus?(statusText)

        if signal != lastSignal {
            Log.info("meeting signal \(signal ? "ON" : "off"): mic=\(mic) users=\(users) watcher=\(watcher)")
            lastSignal = signal
            if !signal { declinedForThisSignal = false }
        }
        if calendarLookahead { checkCalendar() }

        switch mode {
        case .always, .manual:
            return
        case .auto:
            if signal { endGrace?.cancel(); endGrace = nil; if !p.meetingActive { startProxy(reason: statusText) } }
            else if p.meetingActive { scheduleEnd() }
        case .ask:
            if signal {
                endGrace?.cancel(); endGrace = nil
                if !p.meetingActive && !declinedForThisSignal && !prompt.isVisible {
                    askToStart(detail: who.isEmpty ? (mic ? "The microphone is in use." : "Another app is capturing your screen.")
                                                   : "\(who) is using the microphone.")
                }
            } else if p.meetingActive && startedByUs {
                scheduleEnd()
            }
        }
    }

    private func askToStart(detail: String) {
        let choices = screenChoices?()
        let multi = (choices?.names.count ?? 0) > 1
        prompt.show(title: "Meeting detected — start sharemask proxy?",
                    detail: detail + (multi ? " Pick the screen to mirror, then share the “sharemask” display."
                                            : " Start the proxy so you can share the “sharemask” display safely."),
                    primary: "Start proxy", secondary: "Not now",
                    choices: multi ? choices?.names : nil, selected: choices?.selected ?? 0,
                    onChoice: { [weak self] i in self?.onChooseScreen?(i) },
                    onPrimary: { [weak self] in self?.startProxy(reason: "user accepted prompt") },
                    onSecondary: { [weak self] in self?.declinedForThisSignal = true; Log.info("meeting prompt declined") })
    }

    private func startProxy(reason: String) {
        guard let p = pipeline else { return }
        Log.info("auto capture: starting (\(reason))")
        startedByUs = true
        p.meetingActive = true
    }

    private func scheduleEnd() {
        guard endGrace == nil else { return }
        let item = DispatchWorkItem { [weak self] in self?.endIfReallyOver() }
        endGrace = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: item)
    }

    private func endIfReallyOver() {
        endGrace = nil
        guard let p = pipeline, p.meetingActive, !detector.micInUse else { return }
        // The mic went quiet, but the user may still be sharing without audio: pause briefly and
        // check whether any other process is capturing before stopping.
        p.probeOtherWatchers { [weak self] stillShared in
            guard let self = self, let p = self.pipeline else { return }
            if stillShared {
                Log.info("auto capture: mic idle but screen is still being shared; keeping capture on")
                self.scheduleEnd()
            } else {
                Log.info("auto capture: meeting over, stopping capture")
                p.meetingActive = false
                self.startedByUs = false
                self.prompt.show(title: "Meeting ended — proxy stopped", detail: "Capture is off; the recording indicator will disappear.",
                                 primary: "OK", secondary: "Keep running", timeout: 8,
                                 onPrimary: {}, onSecondary: { [weak self] in self?.startProxy(reason: "user kept it running") })
            }
        }
    }

    /// Manual start/stop from the menu overrides the gate for this session.
    func userStartedManually() { startedByUs = false; pipeline?.meetingActive = true }
    func userStoppedManually() { startedByUs = false; declinedForThisSignal = true; pipeline?.meetingActive = false }

    // MARK: Calendar lookahead (opt-in)

    private func requestCalendarAccess() {
        let store = EKEventStore()
        calendarStore = store
        store.requestFullAccessToEvents { granted, error in
            Log.info("calendar access \(granted ? "granted" : "denied") \(error.map { "(\($0))" } ?? "")")
        }
    }

    private func checkCalendar() {
        guard let store = calendarStore, EKEventStore.authorizationStatus(for: .event) == .fullAccess,
              Date().timeIntervalSince(lastCalendarCheck) > 30 else { return }
        lastCalendarCheck = Date()
        let now = Date()
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-60), end: now.addingTimeInterval(5 * 60), calendars: nil)
        for event in store.events(matching: predicate) where !event.isAllDay {
            let id = event.eventIdentifier ?? event.title ?? "\(event.startDate!)"
            guard !promptedEventIDs.contains(id), looksLikeVideoCall(event) else { continue }
            promptedEventIDs.insert(id)
            Log.info("calendar: upcoming call '\(event.title ?? "")' at \(event.startDate!)")
            guard mode == .ask || mode == .auto, let p = pipeline, !p.meetingActive, !prompt.isVisible else { continue }
            let mins = max(0, Int(event.startDate.timeIntervalSince(now) / 60))
            prompt.show(title: "“\(event.title ?? "Meeting")” starts in \(mins) min",
                        detail: "Start the sharemask proxy now so it's ready when you share your screen?",
                        primary: "Start proxy", secondary: "Not now",
                        onPrimary: { [weak self] in self?.startProxy(reason: "calendar event") }, onSecondary: {})
        }
    }

    private func looksLikeVideoCall(_ e: EKEvent) -> Bool {
        if e.hasAttendees { return true }
        let text = [e.location, e.notes, e.url?.absoluteString, e.title].compactMap { $0 }.joined(separator: " ").lowercased()
        return ["zoom.us", "meet.google", "teams.microsoft", "webex", "facetime", "slack.com/huddle", "meet."].contains { text.contains($0) }
    }

    private func appName(_ bundleID: String) -> String {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).flatMap { Bundle(url: $0)?.infoDictionary?["CFBundleName"] as? String }
            ?? bundleID
    }
}
