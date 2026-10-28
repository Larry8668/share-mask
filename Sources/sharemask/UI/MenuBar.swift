import AppKit
import Carbon

/// NSStatusItem + menu. Pure view: everything it does goes through `actions`.
final class MenuBar: NSObject, NSMenuDelegate {
    enum IconState { case idle, active, panic, error }

    struct Actions {
        var toggleProxy: () -> Void
        var panic: () -> Void
        var toggleRegions: () -> Void
        var pick: () -> Void
        var pickFor: (pid_t, String) -> Void
        var removeApp: (String) -> Void
        var toggleMask: (String) -> Void          // disable key
        var toggleAllowlist: () -> Void
        var togglePreview: () -> Void
        var endShare: () -> Void
        var dumpWindows: () -> Void
        var changeHotkey: (String) -> Void        // hotkey name in presets.json
        var toggleLoginItem: () -> Void
        var openPresets: () -> Void
        var openLogs: () -> Void
        var reloadPresets: () -> Void
        var togglePointerGuard: () -> Void
        var toggleHUD: () -> Void
        var openScreenRecordingSettings: () -> Void
        var relaunch: () -> Void
        var bringBackStrays: () -> Void
        var chooseScreen: (CGDirectDisplayID) -> Void
        var appLock: (String, String?) -> Void      // (command, argument)
        var showWelcome: () -> Void
        var openMain: () -> Void
        var present: (CGDirectDisplayID, Bool) -> Void   // (tv, mirror?)
        var stopPresenting: () -> Void
        var showKeys: () -> Void
        var checkUpdates: () -> Void
        var updateNow: () -> Void
        var copyUpdateCommand: () -> Void
        var openReleasePage: () -> Void
        var toggleUpdateChecks: () -> Void
        var removeDisplay: () -> Void
        var quit: () -> Void
    }

    private let item: NSStatusItem
    private let menu = NSMenu()
    private let actions: Actions

    private let startStopItem = NSMenuItem()
    private let panicItem = NSMenuItem()
    private let regionsItem = NSMenuItem()
    private let pickItem = NSMenuItem()
    private let pickForItem = NSMenuItem()
    private let configuredItem = NSMenuItem()
    private let masksItem = NSMenuItem()
    private let allowlistItem = NSMenuItem()
    private let previewItem = NSMenuItem()
    private let endShareItem = NSMenuItem()
    private let hotkeysItem = NSMenuItem()
    private let loginItem = NSMenuItem()
    private let pointerItem = NSMenuItem()
    private let hudItem = NSMenuItem()
    private let statusLine = NSMenuItem()
    private let latencyLine = NSMenuItem()
    private let warningLine = NSMenuItem()
    private let permissionItem = NSMenuItem()
    private let relaunchItem = NSMenuItem()
    private let strayItem = NSMenuItem()
    private let versionItem = NSMenuItem()
    private let screenItem = NSMenuItem()
    private let presentItem = NSMenuItem()
    private let appLockItem = NSMenuItem()
    private let updateChecksItem = NSMenuItem()
    private let removeDisplayItem = NSMenuItem()

    init(actions: Actions) {
        self.actions = actions
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        build()
        setIcon(.idle)
    }

    /// Top level = essentials only. Everything else lives in submenus:
    ///   status · warnings · [Bring back stray windows]
    ///   Start/Stop capturing · Panic · End share now
    ///   Masks ▸  Edit regions ▸  What others see
    ///   Settings ▸  Troubleshooting ▸
    ///   Quit
    private func build() {
        menu.delegate = self
        menu.autoenablesItems = false

        statusLine.isEnabled = false
        latencyLine.isEnabled = false
        warningLine.isEnabled = false
        warningLine.isHidden = true
        permissionItem.title = "Open Screen Recording settings…"
        permissionItem.isHidden = true
        bind(permissionItem, #selector(openPermission))
        relaunchItem.title = "Relaunch sharemask"
        relaunchItem.isHidden = true
        bind(relaunchItem, #selector(relaunch))
        strayItem.isHidden = true
        bind(strayItem, #selector(bringBackStrays))

        bind(startStopItem, #selector(toggleProxy))
        bind(panicItem, #selector(panic))
        bind(regionsItem, #selector(toggleRegions))
        bind(pickItem, #selector(pick))
        bind(pointerItem, #selector(togglePointerGuard))
        bind(hudItem, #selector(toggleHUD))
        bind(allowlistItem, #selector(toggleAllowlist))
        bind(previewItem, #selector(togglePreview))
        bind(endShareItem, #selector(endShare))
        bind(loginItem, #selector(toggleLoginItem))
        bind(removeDisplayItem, #selector(removeDisplay))
        pointerItem.title = "Pointer guard (keep cursor off proxy)"
        hudItem.title = "Show status HUD"
        allowlistItem.title = "Allowlist mode (mask all but allowed apps)"
        previewItem.title = "What others see"
        endShareItem.title = "End share now"
        loginItem.title = "Launch at login"
        removeDisplayItem.title = "Remove proxy display now"

        // Header + essentials
        let open = item("Open sharemask…", #selector(openMain), key: "o")
        menu.addItem(open)
        menu.addItem(.separator())
        menu.addItem(statusLine)
        menu.addItem(latencyLine)
        menu.addItem(warningLine)
        menu.addItem(permissionItem)
        menu.addItem(relaunchItem)
        menu.addItem(strayItem)
        menu.addItem(.separator())
        menu.addItem(startStopItem)
        screenItem.submenu = NSMenu()
        screenItem.isHidden = true
        menu.addItem(screenItem)
        presentItem.submenu = NSMenu()
        presentItem.isHidden = true
        menu.addItem(presentItem)
        menu.addItem(panicItem)
        menu.addItem(.separator())

        // Masks ▸ (rebuilt on open by updateMasks; the two toggles stay at the top)
        masksItem.title = "Masks"
        masksItem.submenu = NSMenu()
        menu.addItem(masksItem)

        // Edit regions ▸
        let edit = NSMenu()
        pickItem.title = "Frontmost app…"
        edit.addItem(pickItem)
        pickForItem.title = "Choose app"
        pickForItem.submenu = NSMenu()
        edit.addItem(pickForItem)
        configuredItem.title = "Configured apps"
        configuredItem.submenu = NSMenu()
        edit.addItem(configuredItem)
        edit.addItem(.separator())
        edit.addItem(item("Open presets.json", #selector(openPresets)))
        edit.addItem(item("Reload presets", #selector(reloadPresets)))
        appLockItem.submenu = NSMenu()
        menu.addItem(appLockItem)
        let editItem = NSMenuItem(title: "Edit regions", action: nil, keyEquivalent: "")
        editItem.submenu = edit
        menu.addItem(editItem)
        menu.addItem(previewItem)
        menu.addItem(.separator())

        // Settings ▸
        let settings = NSMenu()
        hotkeysItem.title = "Shortcuts"
        hotkeysItem.submenu = NSMenu()
        settings.addItem(item("Setup & permissions…", #selector(showWelcome)))
        settings.addItem(.separator())
        settings.addItem(hotkeysItem)
        settings.addItem(loginItem)
        settings.addItem(pointerItem)
        settings.addItem(hudItem)
        updateChecksItem.title = "Check for updates daily"
        bind(updateChecksItem, #selector(toggleUpdateChecks))
        settings.addItem(updateChecksItem)
        let settingsItem = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        settingsItem.submenu = settings
        menu.addItem(settingsItem)

        // Troubleshooting ▸
        let trouble = NSMenu()
        trouble.addItem(endShareItem)
        trouble.addItem(removeDisplayItem)
        trouble.addItem(item("Keyboard shortcuts…", #selector(showKeys)))
        trouble.addItem(item("Show log file", #selector(openLogs)))
        trouble.addItem(item("Dump window list to log", #selector(dumpWindows)))
        trouble.addItem(item("Relaunch sharemask", #selector(relaunch)))
        let troubleItem = NSMenuItem(title: "Troubleshooting", action: nil, keyEquivalent: "")
        troubleItem.submenu = trouble
        menu.addItem(troubleItem)
        menu.addItem(.separator())
        versionItem.submenu = NSMenu()
        menu.addItem(versionItem)
        menu.addItem(item("Quit sharemask", #selector(quit), key: "q"))
        item.menu = menu
    }

    private func item(_ title: String, _ sel: Selector, key: String = "") -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        mi.target = self
        return mi
    }

    private func bind(_ mi: NSMenuItem, _ sel: Selector) { mi.target = self; mi.action = sel }

    // MARK: State → UI

    func setIcon(_ state: IconState) {
        let (symbol, color, tip): (String, NSColor, String)
        switch state {
        case .idle: (symbol, color, tip) = ("eye.slash", .secondaryLabelColor, "sharemask: proxy stopped")
        case .active: (symbol, color, tip) = ("eye.slash.fill", .systemGreen, "sharemask: proxy display active")
        case .panic: (symbol, color, tip) = ("eye.slash.fill", .systemRed, "sharemask: PANIC — whole feed redacted")
        case .error: (symbol, color, tip) = ("exclamationmark.triangle.fill", .systemYellow, "sharemask: error")
        }
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))?
            .withSymbolConfiguration(.init(paletteColors: [color])) {
            img.isTemplate = false
            item.button?.image = img
        }
        item.button?.toolTip = tip
    }

    func update(status: String, latency: String, warning: String?, running: Bool, panic: Bool,
                regionsEnabled: Bool, pointerGuard: Bool, hud: Bool, hotkeys: HotkeyConfig, needsPermission: Bool,
                needsRelaunch: Bool, allowlistMode: Bool, previewShown: Bool, launchAtLogin: Bool,
                strayCount: Int, displayExists: Bool) {
        strayItem.isHidden = strayCount == 0
        strayItem.title = "⚠ Bring back \(strayCount) window\(strayCount == 1 ? "" : "s") from the hidden display"
        removeDisplayItem.isEnabled = displayExists
        latencyLine.isHidden = !running
        loginItem.state = launchAtLogin ? .on : .off
        relaunchItem.isHidden = !needsRelaunch
        allowlistItem.state = allowlistMode ? .on : .off
        MenuBar.setKey(allowlistItem, hotkeys.allowlist)
        previewItem.state = previewShown ? .on : .off
        endShareItem.title = "End share now (emergency, ⌃⌥X)"
        endShareItem.isEnabled = running || displayExists
        MenuBar.setKey(endShareItem, hotkeys.endShare)
        statusLine.title = status
        latencyLine.title = latency
        warningLine.title = warning.map { "⚠ \($0)" } ?? ""
        warningLine.isHidden = warning == nil
        permissionItem.isHidden = !needsPermission
        startStopItem.title = running ? "Stop" : "Start capturing"
        panicItem.title = panic ? "Panic: ON (restore)" : "Panic"
        panicItem.state = panic ? .on : .off
        MenuBar.setKey(panicItem, hotkeys.panic)
        regionsItem.title = "Per-app masks"
        regionsItem.state = regionsEnabled ? .on : .off
        MenuBar.setKey(regionsItem, hotkeys.toggle)
        pickItem.title = "Frontmost app…"
        MenuBar.setKey(pickItem, hotkeys.pick)
        pointerItem.state = pointerGuard ? .on : .off
        hudItem.state = hud ? .on : .off
    }

    /// Shows the hotkey in the menu (display only; Carbon handles the actual global binding).
    private static func setKey(_ mi: NSMenuItem, _ combo: String?) {
        guard let combo = combo, let (_, mods) = Hotkeys.parse(combo),
              let keyName = combo.split(separator: "+").last?.trimmingCharacters(in: .whitespaces) else {
            mi.keyEquivalent = ""; return
        }
        if keyName.count == 1 {
            mi.keyEquivalent = keyName.lowercased()
            var m: NSEvent.ModifierFlags = []
            if mods & UInt32(cmdKey) != 0 { m.insert(.command) }
            if mods & UInt32(shiftKey) != 0 { m.insert(.shift) }
            if mods & UInt32(controlKey) != 0 { m.insert(.control) }
            if mods & UInt32(optionKey) != 0 { m.insert(.option) }
            mi.keyEquivalentModifierMask = m
        } else {
            mi.keyEquivalent = ""
            mi.title += "  (\(Hotkeys.pretty(combo)))"
        }
    }

    struct RunningApp { var name: String; var pid: pid_t; var bundleID: String }
    struct MaskEntry { var title: String; var key: String; var enabled: Bool }

    /// Masks submenu: one checkbox per app/region/rule; unchecking disables it until re-checked.
    func updateMasks(_ entries: [MaskEntry], revealHotkey: String?) {
        let m = masksItem.submenu!
        m.removeAllItems()
        m.addItem(regionsItem)
        m.addItem(allowlistItem)
        m.addItem(.separator())
        let hint = NSMenuItem(title: "Hold \(Hotkeys.pretty(revealHotkey)) to reveal the frontmost app", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        m.addItem(hint)
        m.addItem(.separator())
        if entries.isEmpty { m.addItem(withTitle: "No masks configured", action: nil, keyEquivalent: "") }
        for e in entries {
            let mi = NSMenuItem(title: e.title, action: #selector(toggleMask(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = e.key
            mi.state = e.enabled ? .on : .off
            mi.indentationLevel = e.key.contains("/") ? 1 : 0
            m.addItem(mi)
        }
    }

    static let hotkeyNames: [(String, String)] = [("panic", "Panic"), ("toggle", "Toggle regions"), ("pick", "Pick regions"),
                                                  ("reveal", "Hold to reveal"), ("allowlist", "Allowlist mode"), ("endShare", "End share"),
                                                  ("lockAll", "Lock all apps"), ("lockApp", "Lock this app")]

    func updateHotkeys(_ hotkeys: HotkeyConfig) {
        let m = hotkeysItem.submenu!
        m.removeAllItems()
        let values: [String: String?] = ["panic": hotkeys.panic, "toggle": hotkeys.toggle, "pick": hotkeys.pick,
                                         "reveal": hotkeys.reveal, "allowlist": hotkeys.allowlist, "endShare": hotkeys.endShare,
                                         "lockAll": hotkeys.lockAll, "lockApp": hotkeys.lockApp]
        for (key, title) in MenuBar.hotkeyNames {
            let combo = values[key] ?? nil
            let shown = (combo?.isEmpty ?? true) ? "unbound" : Hotkeys.pretty(combo)
            let mi = NSMenuItem(title: "\(title): \(shown)   — change…", action: #selector(changeHotkey(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = key
            m.addItem(mi)
        }
        m.addItem(.separator())
        let hint = NSMenuItem(title: "Stored in presets.json → \"hotkeys\"", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        m.addItem(hint)
    }

    @objc private func toggleLoginItem() { actions.toggleLoginItem() }

    @objc private func changeHotkey(_ sender: NSMenuItem) {
        if let key = sender.representedObject as? String { actions.changeHotkey(key) }
    }

    @objc private func toggleMask(_ sender: NSMenuItem) {
        if let key = sender.representedObject as? String { actions.toggleMask(key) }
    }
    @objc private func toggleAllowlist() { actions.toggleAllowlist() }
    @objc private func togglePreview() { actions.togglePreview() }
    @objc private func endShare() { actions.endShare() }
    @objc private func dumpWindows() { actions.dumpWindows() }
    struct ConfiguredApp { var name: String; var bundleID: String; var regionCount: Int; var pid: pid_t? }

    /// Rebuilds the two app submenus (called when the menu is about to open).
    func updateApps(running: [RunningApp], configured: [ConfiguredApp]) {
        let pickMenu = pickForItem.submenu!
        pickMenu.removeAllItems()
        if running.isEmpty { pickMenu.addItem(withTitle: "No apps with windows", action: nil, keyEquivalent: "") }
        for app in running {
            let mi = NSMenuItem(title: app.name, action: #selector(pickForApp(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = app.bundleID
            mi.tag = Int(app.pid)
            pickMenu.addItem(mi)
        }
        let cfgMenu = configuredItem.submenu!
        cfgMenu.removeAllItems()
        if configured.isEmpty { cfgMenu.addItem(withTitle: "None yet — use “Pick regions for app”", action: nil, keyEquivalent: "") }
        for app in configured {
            let mi = NSMenuItem(title: "\(app.name) — \(app.regionCount) region\(app.regionCount == 1 ? "" : "s")", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            let edit = NSMenuItem(title: app.pid == nil ? "Edit regions… (app not running)" : "Edit regions…",
                                  action: #selector(pickForApp(_:)), keyEquivalent: "")
            edit.target = self
            edit.representedObject = app.bundleID
            edit.tag = Int(app.pid ?? 0)
            edit.isEnabled = app.pid != nil
            sub.addItem(edit)
            let remove = NSMenuItem(title: "Remove all regions", action: #selector(removeApp(_:)), keyEquivalent: "")
            remove.target = self
            remove.representedObject = app.bundleID
            sub.addItem(remove)
            let id = NSMenuItem(title: app.bundleID, action: nil, keyEquivalent: "")
            id.isEnabled = false
            sub.addItem(id)
            mi.submenu = sub
            cfgMenu.addItem(mi)
        }
    }

    @objc private func pickForApp(_ sender: NSMenuItem) {
        guard let bundleID = sender.representedObject as? String else { return }
        actions.pickFor(pid_t(sender.tag), bundleID)
    }
    @objc private func removeApp(_ sender: NSMenuItem) {
        guard let bundleID = sender.representedObject as? String else { return }
        actions.removeApp(bundleID)
    }

    // MARK: Selectors

    @objc private func toggleProxy() { actions.toggleProxy() }
    @objc private func panic() { actions.panic() }
    @objc private func toggleRegions() { actions.toggleRegions() }
    @objc private func pick() { actions.pick() }
    @objc private func openPresets() { actions.openPresets() }
    @objc private func reloadPresets() { actions.reloadPresets() }
    @objc private func openLogs() { actions.openLogs() }
    @objc private func togglePointerGuard() { actions.togglePointerGuard() }
    @objc private func toggleHUD() { actions.toggleHUD() }
    @objc private func openPermission() { actions.openScreenRecordingSettings() }
    @objc private func relaunch() { actions.relaunch() }
    @objc private func bringBackStrays() { actions.bringBackStrays() }

    /// "Share screen: <name> ▸" — only shown when more than one real screen is connected.
    func updateScreens(_ screens: [(id: CGDirectDisplayID, name: String)], selected: CGDirectDisplayID) {
        screenItem.isHidden = screens.count < 2
        screenItem.title = "Share screen: \(screens.first { $0.id == selected }?.name ?? "—")"
        let m = screenItem.submenu!
        m.removeAllItems()
        for s in screens {
            let mi = NSMenuItem(title: s.name, action: #selector(chooseScreen(_:)), keyEquivalent: "")
            mi.target = self
            mi.tag = Int(s.id)
            mi.state = s.id == selected ? .on : .off
            m.addItem(mi)
        }
    }
    /// "Present to <TV> ▸" — offered for each external screen.
    func updatePresent(_ externals: [(id: CGDirectDisplayID, name: String)], active: Pipeline.Output) {
        presentItem.isHidden = externals.isEmpty
        let m = presentItem.submenu!
        m.removeAllItems()
        if let tv = active.tv {
            let name = externals.first { $0.id == tv }?.name ?? "screen"
            presentItem.title = "Presenting to \(name)"
        } else {
            presentItem.title = externals.count == 1 ? "Present to \(externals[0].name)" : "Present to a screen"
        }
        for e in externals {
            if externals.count > 1 {
                let h = NSMenuItem(title: e.name, action: nil, keyEquivalent: ""); h.isEnabled = false; m.addItem(h)
            }
            let ext = NSMenuItem(title: "Masked extend — drag windows onto it", action: #selector(presentChosen(_:)), keyEquivalent: "")
            ext.target = self; ext.tag = Int(e.id); ext.representedObject = false
            ext.state = active == .overlay(e.id) ? .on : .off
            let mir = NSMenuItem(title: "Masked mirror — it shows your screen", action: #selector(presentChosen(_:)), keyEquivalent: "")
            mir.target = self; mir.tag = Int(e.id); mir.representedObject = true
            mir.state = active == .mirror(e.id) ? .on : .off
            m.addItem(ext); m.addItem(mir)
        }
        if active.tv != nil {
            m.addItem(.separator())
            m.addItem(item("Stop presenting", #selector(stopPresenting)))
        }
    }
    struct AppLockModel {
        var enabled: Bool
        var apps: [(bundleID: String, name: String, locked: Bool, unlockedNow: Bool)]
        var relockMinutes: Int
        var relockOnSleep: Bool
        var guardQuit: Bool
        var keepAlive: Bool
        var hasPassword: Bool
    }

    /// "App lock ▸": everything app-lock lives here, one level down from the top menu.
    func updateAppLock(_ m: AppLockModel) {
        let lockedCount = m.apps.filter { $0.locked }.count
        appLockItem.title = m.enabled ? "App lock: on (\(lockedCount) app\(lockedCount == 1 ? "" : "s"))" : "App lock: off"
        let menu = appLockItem.submenu!
        menu.removeAllItems()
        func cmd(_ title: String, _ c: String, _ arg: String? = nil, state: Bool? = nil, enabled: Bool = true) -> NSMenuItem {
            let mi = NSMenuItem(title: title, action: #selector(appLockCommand(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = [c, arg ?? ""]
            if let st = state { mi.state = st ? .on : .off }
            mi.isEnabled = enabled
            return mi
        }
        let lockNow = cmd("Lock all now", "lockAll", enabled: m.enabled && m.apps.contains { $0.unlockedNow })
        lockNow.keyEquivalent = "l"; lockNow.keyEquivalentModifierMask = [.command, .shift, .control]
        menu.addItem(lockNow)
        let lockThis = cmd("Lock the current app", "lockApp", enabled: true)
        lockThis.keyEquivalent = "l"; lockThis.keyEquivalentModifierMask = [.command, .control]
        menu.addItem(lockThis)
        menu.addItem(cmd(m.enabled ? "Turn App lock off…" : "Turn App lock on", "toggle"))
        menu.addItem(.separator())
        let h = NSMenuItem(title: "Apps to lock", action: nil, keyEquivalent: ""); h.isEnabled = false
        menu.addItem(h)
        for a in m.apps {
            let mi = cmd(a.name + (a.unlockedNow ? "  (unlocked)" : ""), "app", a.bundleID, state: a.locked)
            menu.addItem(mi)
        }
        menu.addItem(.separator())
        let relock = NSMenuItem(title: "Relock after", action: nil, keyEquivalent: "")
        let rm = NSMenu()
        for (label, mins) in [("Switching away", 0), ("1 minute", 1), ("5 minutes", 5), ("15 minutes", 15), ("1 hour", 60)] {
            rm.addItem(cmd(label, "relock", "\(mins)", state: m.relockMinutes == mins))
        }
        rm.addItem(.separator())
        rm.addItem(cmd("Also when the screen locks or sleeps", "sleep", state: m.relockOnSleep))
        relock.submenu = rm
        menu.addItem(relock)
        menu.addItem(cmd("Require unlock to quit sharemask", "guardQuit", state: m.guardQuit))
        menu.addItem(cmd("Relaunch sharemask if force-quit", "keepAlive", state: m.keepAlive))
        menu.addItem(cmd(m.hasPassword ? "Change sharemask password…" : "Set a sharemask password…", "password"))
        if m.hasPassword { menu.addItem(cmd("Remove sharemask password…", "removePassword")) }
    }

    @objc private func showWelcome() { actions.showWelcome() }
    @objc private func openMain() { actions.openMain() }

    /// Opens the status item's menu (for "Show me the menu" in the welcome window).
    func openMenu() { item.button?.performClick(nil) }

    @objc private func appLockCommand(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [String], pair.count == 2 else { return }
        actions.appLock(pair[0], pair[1].isEmpty ? nil : pair[1])
    }

    @objc private func presentChosen(_ sender: NSMenuItem) {
        actions.present(CGDirectDisplayID(sender.tag), (sender.representedObject as? Bool) ?? false)
    }
    @objc private func stopPresenting() { actions.stopPresenting() }
    @objc private func showKeys() { actions.showKeys() }

    @objc private func chooseScreen(_ sender: NSMenuItem) { actions.chooseScreen(CGDirectDisplayID(sender.tag)) }
    @objc private func checkUpdates() { actions.checkUpdates() }
    @objc private func updateNow() { actions.updateNow() }
    @objc private func copyUpdateCommand() { actions.copyUpdateCommand() }
    @objc private func openReleasePage() { actions.openReleasePage() }
    @objc private func toggleUpdateChecks() { actions.toggleUpdateChecks() }

    /// Footer: "sharemask 0.1.4 — up to date" or "⬆ Update available: 0.1.5", submenu with actions.
    func updateVersion(current: String, status: UpdateChecker.Status, checksEnabled: Bool, homebrew: Bool) {
        updateChecksItem.state = checksEnabled ? .on : .off
        switch status {
        case .available(let v): versionItem.title = "⬆ Update available: \(v) (you have \(current))"
        case .upToDate: versionItem.title = "sharemask \(current) — up to date"
        case .checking: versionItem.title = "sharemask \(current) — checking…"
        case .failed: versionItem.title = "sharemask \(current) — update check failed"
        case .unknown: versionItem.title = "sharemask \(current)"
        }
        let m = versionItem.submenu!
        m.removeAllItems()
        if case .available = status {
            m.addItem(item(homebrew ? "Update now (runs Homebrew in Terminal)" : "Download update…", #selector(updateNow)))
        }
        if homebrew {
            let copy = item("Copy update command", #selector(copyUpdateCommand))
            copy.toolTip = UpdateChecker.brewCommand
            m.addItem(copy)
        }
        m.addItem(item("Release notes", #selector(openReleasePage)))
        m.addItem(item("Check for updates now", #selector(checkUpdates)))
    }
    @objc private func removeDisplay() { actions.removeDisplay() }
    @objc private func quit() { actions.quit() }

    var onMenuWillOpen: (() -> Void)?
    func menuWillOpen(_ menu: NSMenu) { onMenuWillOpen?() }
}
