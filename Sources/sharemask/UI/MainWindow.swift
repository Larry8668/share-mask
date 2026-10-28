import AppKit
import SwiftUI

// MARK: - Shared pieces

/// The animated status orb: breathing grey in standby, pulsing green when live, red in panic.
struct StatusOrb: View {
    var phase: AppModel.Phase
    var size: CGFloat = 120
    @State private var pulse = false

    private var color: Color {
        switch phase {
        case .live, .presenting: return .green
        case .panic: return .red
        case .starting: return .orange
        case .error: return .yellow
        case .standby: return .gray
        }
    }
    private var active: Bool { phase == .live || phase == .presenting || phase == .panic }

    var body: some View {
        ZStack {
            // Pulse rings only while sharing: a repeat-forever animation redraws every frame, which
            // costs real CPU (and battery) — measured ~39% of a core when it also ran in standby.
            if active {
                ForEach(0..<2) { i in
                    Circle()
                        .stroke(color.opacity(0.45), lineWidth: 2)
                        .scaleEffect(pulse ? 1.35 + CGFloat(i) * 0.25 : 0.9)
                        .opacity(pulse ? 0 : 1)
                        .animation(.easeOut(duration: 1.8).repeatForever(autoreverses: false).delay(Double(i) * 0.6), value: pulse)
                }
            }
            Circle()
                .fill(RadialGradient(colors: [color.opacity(0.95), color.opacity(0.55)], center: .topLeading, startRadius: 4, endRadius: size))
                .shadow(color: color.opacity(0.6), radius: active ? 18 : 6)
            Image(systemName: phase == .panic ? "eye.slash.circle.fill" : "eye.slash.fill")
                .font(.system(size: size * 0.36, weight: .semibold))
                .foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace))
        }
        .frame(width: size, height: size)
        .onAppear { pulse = active }
        .onChange(of: active) { _, now in pulse = now }
        .animation(.spring(response: 0.5, dampingFraction: 0.7), value: phase)
    }
}

struct Card<Content: View>: View {
    var title: String
    var symbol: String
    var tint: Color
    var trailing: AnyView? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(RoundedRectangle(cornerRadius: 7).fill(tint.gradient))
                Text(title).font(.system(size: 14, weight: .semibold))
                Spacer()
                if let t = trailing { t }
            }
            content
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 16).fill(.background.opacity(0.55)))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.08)))
    }
}

struct KeyChip: View {
    var keys: String
    var label: String
    var body: some View {
        HStack(spacing: 6) {
            Text(keys).font(.system(size: 11, weight: .semibold, design: .rounded))
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5).fill(.quaternary))
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

struct AppIcon: View {
    var bundleID: String
    var size: CGFloat = 28
    var body: some View {
        Image(nsImage: AppModel.icon(bundleID)).resizable().interpolation(.high).frame(width: size, height: size)
    }
}

// MARK: - Main window

struct MainView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 16) {
            hero
            HStack(spacing: 14) {
                masksCard
                lockCard
                presentCard
            }
            .frame(height: 250)
            footer
        }
        .padding(.horizontal, 22)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .frame(width: 820, height: 470, alignment: .top)
        .background(VisualEffect().ignoresSafeArea())
    }

    // Hero: orb + status + primary actions
    private var hero: some View {
        HStack(spacing: 22) {
            StatusOrb(phase: model.phase, size: 104)
            VStack(alignment: .leading, spacing: 6) {
                Text(model.title)
                    .font(.system(size: 24, weight: .bold))
                    .contentTransition(.numericText())
                Text(model.subtitle).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(2)
                if !model.latency.isEmpty {
                    Label(model.latency, systemImage: "speedometer").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                HStack(spacing: 10) {
                    Button(action: model.actions.toggleCapture) {
                        Label(isRunning ? "Stop" : "Start sharing", systemImage: isRunning ? "stop.fill" : "play.fill")
                            .frame(minWidth: 130)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .tint(isRunning ? .gray : .green)

                    Button(action: model.actions.panic) {
                        Label(model.phase == .panic ? "Restore" : "Panic", systemImage: "exclamationmark.octagon.fill")
                    }
                    .buttonStyle(.bordered).controlSize(.large)
                    .tint(.red)
                    .disabled(!isRunning)

                    Button(action: model.actions.preview) { Label("What others see", systemImage: "eye") }
                        .buttonStyle(.bordered).controlSize(.large)
                        .disabled(!isRunning)
                }
                .padding(.top, 6)
            }
            Spacer()
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 20).fill(.background.opacity(0.55)))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.08)))
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: model.phase)
    }

    private var isRunning: Bool { [.live, .panic, .presenting, .starting].contains(model.phase) }

    // Masks
    private var masksCard: some View {
        Card(title: "Masks", symbol: "square.dashed.inset.filled", tint: .blue,
             trailing: AnyView(Toggle("", isOn: Binding(get: { model.regionsOn }, set: { _ in model.actions.toggleRegions() }))
                .toggleStyle(.switch).controlSize(.small).labelsHidden())) {
            if model.maskApps.isEmpty {
                emptyState("No masks yet", "Pick an app and draw the parts to blur.", "square.dashed")
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(model.maskApps) { app in
                            HStack(spacing: 8) {
                                AppIcon(bundleID: app.id, size: 24)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(app.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                    Text(app.detail).font(.system(size: 10)).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button { model.actions.editRegions(app.id) } label: { Image(systemName: "pencil") }
                                    .buttonStyle(.borderless).help("Edit regions")
                                Toggle("", isOn: Binding(get: { app.on }, set: { _ in model.actions.toggleMask(app.id) }))
                                    .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                            }
                            .opacity(app.on && model.regionsOn ? 1 : 0.5)
                        }
                    }
                }
            }
            addAppMenu("Add an app") { model.actions.editRegions($0) }
        }
    }

    // App lock — click an app for its own settings (when it relocks, notification previews, remove).
    private var lockCard: some View {
        Card(title: "App lock", symbol: "lock.fill", tint: .green,
             trailing: AnyView(Toggle("", isOn: Binding(get: { model.lockOn }, set: { _ in model.actions.toggleLock() }))
                .toggleStyle(.switch).controlSize(.small).labelsHidden().help(model.lockOn ? "App lock is on" : "App lock is off"))) {
            let locked = model.lockApps.filter { $0.on }
            if locked.isEmpty {
                emptyState("Nothing locked", "Add an app to hide it behind Touch ID.", "lock.open")
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(locked) { app in
                            lockRow(app)
                                .popover(isPresented: Binding(get: { model.openLockApp == app.id }, set: { if !$0 { model.openLockApp = nil } }),
                                         arrowEdge: .trailing) {
                                    LockAppSettings(app: app, model: model) { model.openLockApp = nil }
                                }
                        }
                    }
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: locked)
                }
            }
            HStack {
                Menu {
                    let candidates = model.runningApps.filter { a in !locked.contains { $0.id == a.id } }
                    if !candidates.isEmpty {
                        Section("Running apps") {
                            ForEach(candidates) { a in Button { model.actions.toggleLockApp(a.id) } label: { Text(a.name) } }
                        }
                    }
                    Divider()
                    Button("Choose from Applications…") { model.actions.chooseAppToLock() }
                } label: { Label("Add an app", systemImage: "plus") }
                .menuStyle(.borderlessButton).fixedSize().font(.system(size: 12))
                Spacer()
                Menu {
                    Section("For newly added apps: lock again when closed") {
                        ForEach(AppModel.closeDelayChoices, id: \.0) { c in
                            Button { model.actions.setCloseDelay(c.0) } label: {
                                if c.0 == model.lockCloseDelay { Label(c.1, systemImage: "checkmark") } else { Text(c.1) }
                            }
                        }
                    }
                    Divider()
                    Button { model.actions.toggleHideNotifications() } label: {
                        if model.lockHidesNotifications { Label("Hide notification previews", systemImage: "checkmark") }
                        else { Text("Hide notification previews") }
                    }
                } label: { Label("Defaults", systemImage: "slider.horizontal.3") }
                .menuStyle(.borderlessButton).fixedSize().font(.system(size: 11))
                .help("Settings new apps start with. Click an app above to change its own settings.")
            }
        }
    }

    private func lockRow(_ app: AppModel.AppItem) -> some View {
        let open = app.detail == "unlocked"
        return Button { model.openLockApp = app.id } label: {
            HStack(spacing: 8) {
                ZStack(alignment: .bottomTrailing) {
                    AppIcon(bundleID: app.id, size: 26)
                    Image(systemName: open ? "lock.open.fill" : "lock.fill")
                        .font(.system(size: 7, weight: .bold)).foregroundStyle(.white)
                        .padding(2.5).background(Circle().fill(open ? Color.orange : Color.green))
                        .offset(x: 3, y: 3)
                }
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(app.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        if open {
                            Text("unlocked").font(.system(size: 9, weight: .semibold)).foregroundStyle(.orange)
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(Capsule().fill(Color.orange.opacity(0.15)))
                        }
                    }
                    HStack(spacing: 8) {
                        chip("xmark.square", short(close: app.closeDelay), help: "Locks again \(AppModel.closeText(app.closeDelay))")
                        chip("clock", short(background: app.relockMinutes), help: "Locks again \(AppModel.backgroundText(app.relockMinutes))")
                        if app.hidesNotifications { chip("bell.slash", nil, help: "Notification previews hidden") }
                    }
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 4).padding(.horizontal, 6)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 8).fill(model.openLockApp == app.id ? Color.accentColor.opacity(0.15) : .clear))
        }
        .buttonStyle(.plain)
        .opacity(model.lockOn ? 1 : 0.45)
        .help("\(app.name): click for its lock settings")
    }

    private func chip(_ symbol: String, _ text: String?, help: String) -> some View {
        HStack(spacing: 2) {
            Image(systemName: symbol).font(.system(size: 9))
            if let t = text { Text(t).font(.system(size: 10)) }
        }
        .foregroundStyle(.secondary)
        .help(help)
    }

    private func short(close v: Int) -> String { v == 0 ? "instantly" : v == -1 ? "never" : (v < 60 ? "\(v) s" : "\(v / 60) min") }
    private func short(background v: Int) -> String { v == 0 ? "on switch" : (v >= 60 ? "\(v / 60) h" : "\(v) min") }

    // Present
    private var presentCard: some View {
        Card(title: "Present", symbol: "tv", tint: .purple) {
            if model.screens.isEmpty {
                emptyState("No TV connected", "Plug in HDMI or pick a TV under Screen Mirroring.", "airplayvideo")
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(model.screens) { s in
                        VStack(alignment: .leading, spacing: 6) {
                            Label(s.name, systemImage: "display").font(.system(size: 12, weight: .medium)).lineLimit(1)
                            if model.presentingTo == s.id {
                                HStack {
                                    Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(.green)
                                    Text(model.presentingMirror ? "Mirroring, masked" : "Extended, masked").font(.system(size: 11))
                                    Spacer()
                                    Button("Stop", action: model.actions.stopPresenting).controlSize(.small)
                                }
                            } else {
                                HStack {
                                    Button { model.actions.present(s.id, false) } label: { Label("Extend", systemImage: "rectangle.on.rectangle") }
                                    Button { model.actions.present(s.id, true) } label: { Label("Mirror", systemImage: "rectangle.2.swap") }
                                }
                                .controlSize(.small)
                            }
                        }
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 16) {
            ForEach(Array(model.keys.enumerated()), id: \.offset) { _, k in KeyChip(keys: k.0, label: k.1) }
            Spacer()
            if let v = model.updateAvailable {
                Button { model.actions.update() } label: { Label("Update to \(v)", systemImage: "arrow.down.circle.fill") }
                    .buttonStyle(.borderedProminent).controlSize(.small).tint(.blue)
            } else {
                Text("sharemask \(model.version)").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            Button { model.actions.shortcuts() } label: { Image(systemName: "keyboard") }.buttonStyle(.borderless).help("All shortcuts")
            Button { model.actions.openMenu() } label: { Image(systemName: "ellipsis.circle") }.buttonStyle(.borderless).help("More in the menu bar")
        }
    }

    private func emptyState(_ title: String, _ text: String, _ symbol: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 28, weight: .light)).foregroundStyle(.tertiary)
            Text(title).font(.system(size: 12, weight: .semibold))
            Text(text).font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 18)
    }

    private func addAppMenu(_ title: String, pick: @escaping (String) -> Void) -> some View {
        Menu {
            ForEach(model.runningApps) { a in
                Button { pick(a.id) } label: { Text(a.name) }
            }
        } label: { Label(title, systemImage: "plus") }
        .menuStyle(.borderlessButton).fixedSize()
        .font(.system(size: 12))
    }
}

struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView(); v.material = .underWindowBackground; v.blendingMode = .behindWindow; v.state = .active; return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// Owns the main window. Showing it makes sharemask a regular app (Dock icon, ⌘-Tab) until closed.
final class MainWindowController: NSObject, NSWindowDelegate {
    let model: AppModel
    private var window: NSWindow?
    init(model: AppModel) { self.model = model }
    /// Called right before showing, so the (otherwise paused) model is current.
    var onWillShow: (() -> Void)?
    var isVisible: Bool { window?.isVisible ?? false }

    func show() {
        onWillShow?()
        if window == nil {
            let host = NSHostingController(rootView: MainView(model: model))
            let w = NSWindow(contentViewController: host)
            w.title = "sharemask"
            w.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            // Not movable by background: SwiftUI then recomputes drag regions on every frame.
            w.isMovableByWindowBackground = false
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.setContentSize(NSSize(width: 820, height: 470))
            w.center()
            window = w
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        Log.info("main window shown")
    }

    func windowWillClose(_ notification: Notification) {
        Log.info("main window closed")
        // Free the SwiftUI view so nothing keeps updating or animating while it's closed.
        DispatchQueue.main.async { self.window?.contentViewController = nil; self.window = nil }
        DispatchQueue.main.async { NSApp.setActivationPolicy(.accessory) }
    }

    var windowNumber: Int? { window?.windowNumber }
}


/// Per-app App lock settings, shown when an app in the App lock card is clicked.
struct LockAppSettings: View {
    var app: AppModel.AppItem
    @ObservedObject var model: AppModel
    var dismiss: () -> Void
    @State private var confirmRemove = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                AppIcon(bundleID: app.id, size: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text(app.name).font(.system(size: 15, weight: .semibold))
                    Text(app.detail == "unlocked" ? "Unlocked right now" : "Locked")
                        .font(.system(size: 11)).foregroundStyle(app.detail == "unlocked" ? .orange : .secondary)
                }
                Spacer()
                if app.detail == "unlocked" {
                    Button { model.actions.lockNow(app.id) } label: { Label("Lock now", systemImage: "lock.fill") }
                        .controlSize(.small)
                }
            }
            Divider()
            setting("Lock again when its window closes", symbol: "xmark.square") {
                Picker("", selection: Binding(get: { app.closeDelay }, set: { model.actions.setAppLockSetting(app.id, "close", $0) })) {
                    ForEach(AppModel.closeDelayChoices, id: \.0) { Text($0.1).tag($0.0) }
                }
                .labelsHidden().frame(width: 140)
            }
            setting("Lock again in the background", symbol: "clock") {
                Picker("", selection: Binding(get: { app.relockMinutes }, set: { model.actions.setAppLockSetting(app.id, "background", $0) })) {
                    ForEach(AppModel.backgroundChoices, id: \.0) { Text($0.1).tag($0.0) }
                }
                .labelsHidden().frame(width: 140)
            }
            setting("Hide notification previews", symbol: "bell.slash") {
                Toggle("", isOn: Binding(get: { app.hidesNotifications },
                                         set: { model.actions.setAppLockSetting(app.id, "notifications", $0 ? 1 : 0) }))
                    .toggleStyle(.switch).controlSize(.small).labelsHidden()
            }
            Text("Making these looser asks for Touch ID.").font(.system(size: 10)).foregroundStyle(.tertiary)
            Divider()
            HStack {
                if confirmRemove {
                    Text("Stop locking \(app.name)?").font(.system(size: 12))
                    Spacer()
                    Button("Cancel") { confirmRemove = false }.controlSize(.small)
                    Button("Stop locking") { dismiss(); model.actions.stopLocking(app.id) }
                        .controlSize(.small).tint(.red).buttonStyle(.borderedProminent)
                } else {
                    Button(role: .destructive) { confirmRemove = true } label: { Label("Stop locking \(app.name)", systemImage: "lock.open") }
                        .buttonStyle(.borderless).foregroundStyle(.red).font(.system(size: 12))
                    Spacer()
                    Button("Done", action: dismiss).keyboardShortcut(.defaultAction).controlSize(.small)
                }
            }
        }
        .padding(16)
        .frame(width: 360)
    }

    private func setting<C: View>(_ title: String, symbol: String, @ViewBuilder control: () -> C) -> some View {
        HStack {
            Label(title, systemImage: symbol).font(.system(size: 12))
            Spacer()
            control()
        }
    }
}
