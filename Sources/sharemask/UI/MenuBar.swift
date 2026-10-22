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
        menu.addItem(.separator())
        menu.addItem(pointerItem)
        menu.addItem(hudItem)
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
                needsRelaunch: Bool) {
        relaunchItem.isHidden = !needsRelaunch
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
