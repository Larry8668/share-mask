import AppKit
import SwiftUI
import ScreenCaptureKit
import ApplicationServices

// MARK: - Illustration: your screen vs. what the call sees

/// Two mini screens with the same chat list; on the "shared" one the list keeps re-pixellating.
struct ShareIllustration: View {
    @State private var tick = 0
    let timer = Timer.publish(every: 0.35, on: .main, in: .common).autoconnect()
    private let rowColors: [Color] = [.teal, .pink, .indigo, .orange, .mint]

    var body: some View {
        HStack(spacing: 26) {
            screen(label: "Your screen", masked: false)
            Image(systemName: "arrow.right").font(.system(size: 20, weight: .semibold)).foregroundStyle(.secondary)
                .offset(x: tick % 2 == 0 ? -2 : 2).animation(.easeInOut(duration: 0.35), value: tick)
            screen(label: "What the call sees", masked: true)
        }
        .onReceive(timer) { _ in tick += 1 }
    }

    private func screen(label: String, masked: Bool) -> some View {
        VStack(spacing: 8) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 10).fill(Color(white: 0.96))
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(0..<5) { i in
                            HStack(spacing: 6) {
                                Circle().fill(rowColors[i]).frame(width: 14, height: 14)
                                VStack(alignment: .leading, spacing: 3) {
                                    Capsule().fill(Color.black.opacity(0.65)).frame(width: 46, height: 4)
                                    Capsule().fill(Color.black.opacity(0.3)).frame(width: 34, height: 3)
                                }
                            }
                        }
                    }
                    .padding(10)
                    .frame(width: 84, alignment: .topLeading)
                    .overlay { if masked { pixels.transition(.opacity) } }
                    Rectangle().fill(Color.black.opacity(0.06)).frame(width: 1)
                    VStack(alignment: .leading, spacing: 8) {
                        Capsule().fill(Color.green.opacity(0.35)).frame(width: 60, height: 10)
                        Capsule().fill(Color.white).frame(width: 74, height: 10).shadow(radius: 0.5)
                        Capsule().fill(Color.green.opacity(0.35)).frame(width: 50, height: 10)
                    }
                    .padding(10)
                }
            }
            .frame(width: 180, height: 116)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
            Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
        }
    }

    /// Coarse blocks whose shades shift every tick, like a live pixellated feed.
    private var pixels: some View {
        let cols = 6, rows = 8
        return VStack(spacing: 0) {
            ForEach(0..<rows, id: \.self) { r in
                HStack(spacing: 0) {
                    ForEach(0..<cols, id: \.self) { c in
                        let v = Double(((r * 7 + c * 13 + tick * 3) % 9)) / 9.0
                        Rectangle().fill(Color(hue: 0.55 + v * 0.3, saturation: 0.35, brightness: 0.65 + v * 0.3))
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.3), value: tick)
    }
}

// MARK: - Onboarding

struct OnboardingView: View {
    @ObservedObject var state: OnboardingState
    var onDone: () -> Void
    var onOpenMenu: () -> Void
    var onRelaunch: () -> Void
    @State private var page = 0
    @State private var bounce = false

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if page == 0 { intro.transition(slide) }
                if page == 1 { permissions.transition(slide) }
                if page == 2 { done.transition(slide) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.spring(response: 0.45, dampingFraction: 0.85), value: page)

            HStack {
                HStack(spacing: 6) {
                    ForEach(0..<3) { i in
                        Capsule().fill(i == page ? Color.accentColor : Color.secondary.opacity(0.3))
                            .frame(width: i == page ? 18 : 7, height: 7)
                    }
                }
                .animation(.spring(), value: page)
                Spacer()
                if page > 0 { Button("Back") { page -= 1 }.controlSize(.large) }
                Button(page == 2 ? "Start using sharemask" : "Continue") {
                    if page == 2 { onDone() } else { page += 1 }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent).controlSize(.large)
            }
            .padding(20)
        }
        .frame(width: 600, height: 440)
        .background(VisualEffect().ignoresSafeArea())
    }

    private var slide: AnyTransition {
        .asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .move(edge: .leading).combined(with: .opacity))
    }

    private var intro: some View {
        VStack(spacing: 20) {
            Text("Share your screen,\nnot your chats").font(.system(size: 28, weight: .bold)).multilineTextAlignment(.center)
            ShareIllustration()
            Text("You pick what gets blurred. You see everything; the call sees the blur.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
        }
        .padding(.top, 30)
    }

    private var permissions: some View {
        VStack(spacing: 18) {
            Text("Two quick permissions").font(.system(size: 24, weight: .bold)).padding(.top, 30)
            permissionCard(symbol: "rectangle.dashed.badge.record", tint: .red, title: "Screen Recording",
                           note: "Required · nothing leaves your Mac", granted: state.screen,
                           needsRelaunch: state.screenNeedsRelaunch, action: state.askScreen, relaunch: onRelaunch)
            permissionCard(symbol: "hand.raised.fill", tint: .blue, title: "Accessibility",
                           note: "Recommended · keeps windows tidy, powers App lock", granted: state.ax,
                           needsRelaunch: false, action: state.askAX, relaunch: {})
        }
        .padding(.horizontal, 40)
    }

    private func permissionCard(symbol: String, tint: Color, title: String, note: String, granted: Bool,
                                needsRelaunch: Bool, action: @escaping () -> Void, relaunch: @escaping () -> Void) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 20, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 44, height: 44).background(RoundedRectangle(cornerRadius: 11).fill(tint.gradient))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15, weight: .semibold))
                Text(note).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            if granted && !needsRelaunch {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 26)).foregroundStyle(.green)
                    .transition(.scale.combined(with: .opacity))
            } else if needsRelaunch {
                Button("Relaunch", action: relaunch).buttonStyle(.borderedProminent).tint(.green)
            } else {
                Button("Allow", action: action).buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(.background.opacity(0.6)))
        .animation(.spring(response: 0.4, dampingFraction: 0.6), value: granted)
    }

    private var done: some View {
        VStack(spacing: 18) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 12).fill(.background.opacity(0.6)).frame(width: 360, height: 120)
                HStack(spacing: 10) {
                    Image(systemName: "wifi"); Image(systemName: "battery.75")
                    Image(systemName: "eye.slash.fill").foregroundStyle(.green)
                        .padding(5).background(Circle().fill(Color.green.opacity(0.18)))
                    Text("10:24").font(.system(size: 12, weight: .medium))
                }
                .font(.system(size: 13)).padding(10)
                Image(systemName: "arrow.up.right").font(.system(size: 30, weight: .bold)).foregroundStyle(.green)
                    .offset(x: -64, y: bounce ? 30 : 44)
                    .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: bounce)
            }
            .padding(.top, 26)
            .onAppear { bounce = true }
            Text("Find it in your menu bar").font(.system(size: 22, weight: .bold))
            HStack(spacing: 18) {
                KeyChip(keys: "⌃⌥B", label: "panic")
                KeyChip(keys: "⌃⌥R", label: "hold to reveal")
                KeyChip(keys: "⌃⇧⌘L", label: "lock apps")
            }
            Button("Show me the menu", action: onOpenMenu).buttonStyle(.link)
        }
    }
}

final class OnboardingState: ObservableObject {
    @Published var screen = false
    @Published var ax = false
    @Published var screenNeedsRelaunch = false
    var askScreen: () -> Void = {}
    var askAX: () -> Void = {}
}

// MARK: - Window

/// First-run setup (and Settings ▸ Setup & permissions…). sharemask lives in the menu bar, so
/// without this a new user would see nothing after installing.
final class WelcomeWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var timer: Timer?
    private let state = OnboardingState()
    var onOpenMenu: (() -> Void)?
    var onRelaunch: (() -> Void)?
    var onFinished: (() -> Void)?
    private var screenGrantedAtOpen = false

    static let seenKey = "welcomeSeenVersion"
    static let currentVersion = 2
    /// Only for genuinely new users, and only once. Someone who already used sharemask (presets file
    /// or App lock settings exist, or they've seen any welcome) is marked as seen silently. A missing
    /// permission later is shown in the menu, not by reopening this.
    static var shouldShowAutomatically: Bool {
        let d = UserDefaults.standard
        if d.object(forKey: seenKey) != nil { return false }
        let existingUser = FileManager.default.fileExists(atPath: ConfigStore.fileURL.path) || AppLockStore.hasSavedConfig
        if existingUser {
            d.set(currentVersion, forKey: seenKey)
            Log.info("welcome: existing user, not shown")
            return false
        }
        return true
    }
    /// Test/README only: show the window as a brand-new user sees it.
    private let pretendFresh = ProcessInfo.processInfo.environment["SHAREMASK_PRETEND_NO_PERMISSIONS"] != nil

    var isVisible: Bool { window?.isVisible ?? false }

    func show() {
        if let w = window { NSApp.activate(ignoringOtherApps: true); w.makeKeyAndOrderFront(nil); return }
        screenGrantedAtOpen = CGPreflightScreenCaptureAccess() && !pretendFresh
        state.askScreen = {
            Log.info("welcome: requesting Screen Recording")
            if !CGRequestScreenCaptureAccess() {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
            }
        }
        state.askAX = { Log.info("welcome: requesting Accessibility"); WindowEvacuator.requestTrust() }
        let view = OnboardingView(state: state,
                                  onDone: { [weak self] in self?.window?.close(); self?.onFinished?() },
                                  onOpenMenu: { [weak self] in self?.onOpenMenu?() },
                                  onRelaunch: { [weak self] in self?.markSeen(); self?.onRelaunch?() })
        let w = NSWindow(contentViewController: NSHostingController(rootView: view))
        w.title = "Welcome to sharemask"
        w.styleMask = [.titled, .closable, .fullSizeContentView]
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        window = w
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        Log.info("welcome shown (screen recording \(screenGrantedAtOpen ? "granted" : "not granted"), accessibility \(AXIsProcessTrusted() ? "granted" : "not granted"))")
    }

    private func refresh() {
        let screen = CGPreflightScreenCaptureAccess() && !pretendFresh
        let ax = AXIsProcessTrusted() && !pretendFresh
        if state.screen != screen { state.screen = screen }
        if state.ax != ax { state.ax = ax }
        // macOS only applies a new Screen Recording grant after a relaunch.
        let relaunch = screen && !screenGrantedAtOpen
        if state.screenNeedsRelaunch != relaunch { state.screenNeedsRelaunch = relaunch }
    }

    private func markSeen() { UserDefaults.standard.set(WelcomeWindow.currentVersion, forKey: WelcomeWindow.seenKey) }

    func windowWillClose(_ notification: Notification) {
        markSeen()
        timer?.invalidate(); timer = nil
        window = nil
        Log.info("welcome closed")
    }

    /// Test/README helper: screenshot of the real on-screen window (ScreenCaptureKit).
    func snapshot(to path: String) {
        guard let w = window else { return }
        WindowSnapshot.capture(windowNumber: w.windowNumber, to: path)
    }

    /// Test helper: advance the onboarding by sending Return (the default button).
    func pressDefault() {
        guard let w = window else { return }
        let ev = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber,
                                  context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)
        if let e = ev { w.sendEvent(e) }
    }
}

/// Screenshot of one of our own windows, as it really renders (cacheDisplay drops SwiftUI/text).
enum WindowSnapshot {
    static func capture(windowNumber: Int, to path: String) {
        let id = CGWindowID(windowNumber)
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let sw = content.windows.first(where: { $0.windowID == id }) else { Log.error("snapshot: window not found"); return }
                let cfg = SCStreamConfiguration()
                cfg.width = Int(sw.frame.width * 2); cfg.height = Int(sw.frame.height * 2)
                cfg.captureResolution = .best; cfg.showsCursor = false
                let img = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: sw), configuration: cfg)
                try NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                Log.info("snapshot written to \(path)")
            } catch { Log.error("snapshot failed: \(error)") }
        }
    }
}
