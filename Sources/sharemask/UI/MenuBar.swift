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

    init(actions: Actions) {
        self.actions = actions
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        build()
        setIcon(.idle)
    }

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

        bind(startStopItem, #selector(toggleProxy))
        bind(panicItem, #selector(panic))
        bind(regionsItem, #selector(toggleRegions))
        bind(pickItem, #selector(pick))
        bind(pointerItem, #selector(togglePointerGuard))
        bind(hudItem, #selector(toggleHUD))
        pointerItem.title = "Pointer guard (keep cursor off proxy)"
        hudItem.title = "Show status HUD"

        menu.addItem(statusLine)
        menu.addItem(latencyLine)
        menu.addItem(warningLine)
        menu.addItem(permissionItem)
        menu.addItem(relaunchItem)
        menu.addItem(.separator())
        menu.addItem(startStopItem)
        menu.addItem(.separator())
        menu.addItem(panicItem)
        menu.addItem(regionsItem)
        allowlistItem.title = "Allowlist mode (mask everything except allowed apps)"
        bind(allowlistItem, #selector(toggleAllowlist))
        menu.addItem(allowlistItem)
        masksItem.title = "Masks"
        masksItem.submenu = NSMenu()
        menu.addItem(masksItem)
        menu.addItem(.separator())
        previewItem.title = "Show “what others see” preview"
        bind(previewItem, #selector(togglePreview))
        menu.addItem(previewItem)
        endShareItem.title = "End share now (remove proxy display)"
        bind(endShareItem, #selector(endShare))
        menu.addItem(endShareItem)
        menu.addItem(.separator())
        menu.addItem(pickItem)
        pickForItem.title = "Pick regions for app"
        pickForItem.submenu = NSMenu()
        menu.addItem(pickForItem)
        configuredItem.title = "Configured apps"
        configuredItem.submenu = NSMenu()
        menu.addItem(configuredItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Open presets.json", action: #selector(openPresets), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Reload presets", action: #selector(reloadPresets), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Show log file", action: #selector(openLogs), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Dump window list to log", action: #selector(dumpWindows), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(pointerItem)
        menu.addItem(hudItem)
        hotkeysItem.title = "Shortcuts"
        hotkeysItem.submenu = NSMenu()
        menu.addItem(hotkeysItem)
        loginItem.title = "Launch at login"
        bind(loginItem, #selector(toggleLoginItem))
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit sharemask", action: #selector(quit), keyEquivalent: "q").target = self
        item.menu = menu
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
                needsRelaunch: Bool, allowlistMode: Bool, previewShown: Bool, launchAtLogin: Bool) {
        loginItem.state = launchAtLogin ? .on : .off
        relaunchItem.isHidden = !needsRelaunch
        allowlistItem.state = allowlistMode ? .on : .off
        MenuBar.setKey(allowlistItem, hotkeys.allowlist)
        previewItem.state = previewShown ? .on : .off
        endShareItem.title = "End share now (remove proxy display)"
        MenuBar.setKey(endShareItem, hotkeys.endShare)
        statusLine.title = status
        latencyLine.title = latency
        warningLine.title = warning.map { "⚠ \($0)" } ?? ""
        warningLine.isHidden = warning == nil
        permissionItem.isHidden = !needsPermission
        startStopItem.title = running ? "Stop capturing" : "Start capturing"
        panicItem.title = panic ? "Panic: ON (restore)" : "Panic"
        panicItem.state = panic ? .on : .off
        MenuBar.setKey(panicItem, hotkeys.panic)
        regionsItem.title = regionsEnabled ? "Regions: enabled" : "Regions: disabled"
        regionsItem.state = regionsEnabled ? .on : .off
        MenuBar.setKey(regionsItem, hotkeys.toggle)
        pickItem.title = "Pick region for frontmost app…"
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
                                                  ("reveal", "Hold to reveal"), ("allowlist", "Allowlist mode"), ("endShare", "End share")]

    func updateHotkeys(_ hotkeys: HotkeyConfig) {
        let m = hotkeysItem.submenu!
        m.removeAllItems()
        let values: [String: String?] = ["panic": hotkeys.panic, "toggle": hotkeys.toggle, "pick": hotkeys.pick,
                                         "reveal": hotkeys.reveal, "allowlist": hotkeys.allowlist, "endShare": hotkeys.endShare]
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
    @objc private func quit() { actions.quit() }

    var onMenuWillOpen: (() -> Void)?
    func menuWillOpen(_ menu: NSMenu) { onMenuWillOpen?() }
}
