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
        static func == (a: AppItem, b: AppItem) -> Bool { a.id == b.id && a.name == b.name && a.on == b.on && a.detail == b.detail }
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

    static func icon(_ bundleID: String) -> NSImage {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil) ?? NSImage()
    }
}
