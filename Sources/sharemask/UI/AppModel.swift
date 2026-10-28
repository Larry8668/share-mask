import AppKit
import SwiftUI

/// Observable snapshot of app state for the SwiftUI windows. AppDelegate refreshes it (once a second
/// and on every change) and supplies the actions; views never touch the pipeline directly.
final class AppModel: ObservableObject {
    enum Phase: Equatable { case standby, starting, live, panic, presenting, error }

    struct AppItem: Identifiable, Equatable {
        var id: String            // bundle ID
        var name: String
        var on: Bool              // mask enabled / app locked
        var detail: String        // "3 regions", "unlocked"
        // App lock per-app settings (unused for masks)
        var closeDelay = 0        // seconds; 0 instantly, -1 never
        var relockMinutes = 5     // in the background; 0 = as soon as you switch away
        var hidesNotifications = false
    }
    struct Screen: Identifiable, Equatable { var id: UInt32; var name: String }

    @Published var phase: Phase = .standby
    @Published var title = "Standby"
    @Published var subtitle = "sharemask starts when a call begins"
    @Published var latency = ""
    @Published var regionsOn = true
    @Published var maskApps: [AppItem] = []
    @Published var lockOn = false
    @Published var lockCloseDelay = 0      // seconds; 0 instantly, -1 never
    @Published var lockHidesNotifications = false
    /// App whose App lock settings popover is open.
    @Published var openLockApp: String?
    @Published var lockApps: [AppItem] = []
    @Published var screens: [Screen] = []
    @Published var presentingTo: UInt32?
    @Published var presentingMirror = false
    @Published var screenGranted = false
    @Published var axGranted = false
    @Published var version = ""
    @Published var updateAvailable: String?
    @Published var runningApps: [AppItem] = []   // for "add app" menus
    @Published var keys: [(String, String)] = []

    struct Actions {
        var toggleCapture: () -> Void = {}
        var panic: () -> Void = {}
        var toggleRegions: () -> Void = {}
        var toggleMask: (String) -> Void = { _ in }
        var editRegions: (String) -> Void = { _ in }
        var toggleLock: () -> Void = {}
        var toggleLockApp: (String) -> Void = { _ in }
        var setCloseDelay: (Int) -> Void = { _ in }
        var lockNow: (String) -> Void = { _ in }
        var toggleHideNotifications: () -> Void = {}
        /// (bundle ID, setting, value): "close" seconds, "background" minutes, "notifications" 0/1
        var setAppLockSetting: (String, String, Int) -> Void = { _, _, _ in }
        var stopLocking: (String) -> Void = { _ in }
        var chooseAppToLock: () -> Void = {}
        var present: (UInt32, Bool) -> Void = { _, _ in }
        var stopPresenting: () -> Void = {}
        var askScreen: () -> Void = {}
        var askAX: () -> Void = {}
        var preview: () -> Void = {}
        var shortcuts: () -> Void = {}
        var update: () -> Void = {}
        var openMenu: () -> Void = {}
    }
    var actions = Actions()
    static let closeDelayChoices: [(Int, String)] = [(0, "Instantly"), (30, "After 30 s"), (60, "After 1 min"), (300, "After 5 min"), (-1, "Never")]
    static let backgroundChoices: [(Int, String)] = [(0, "When you switch away"), (1, "After 1 min"), (5, "After 5 min"), (15, "After 15 min"), (60, "After 1 hour")]

    static func closeText(_ v: Int) -> String {
        switch v { case 0: return "on close"; case -1: return "not on close"; default: return v < 60 ? "\(v) s after close" : "\(v / 60) min after close" }
    }
    static func backgroundText(_ v: Int) -> String { v == 0 ? "when you switch away" : (v >= 60 ? "\(v / 60) h in background" : "\(v) min in background") }

    static func icon(_ bundleID: String) -> NSImage {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil) ?? NSImage()
    }
}
