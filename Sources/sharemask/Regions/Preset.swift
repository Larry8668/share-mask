import Foundation
import CoreGraphics

/// How a region is redacted. Default is coarse pixellation: a Gaussian blur at small radius is
/// partially invertible; pixellation at a coarse block size (24 px) is not.
enum RedactMode: Equatable {
    case pixellate(scale: Int)
    case blur(radius: Float)
    case solid(color: RGBA)

    static let defaultPixellate = RedactMode.pixellate(scale: 24)
}

struct RGBA: Equatable {
    var r: Double, g: Double, b: Double, a: Double
    static let black = RGBA(r: 0, g: 0, b: 0, a: 1)

    /// Parses "#RRGGBB" or "#RRGGBBAA" (case-insensitive, '#' optional).
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        if s.count == 6 {
            self.init(r: Double((v >> 16) & 0xFF) / 255, g: Double((v >> 8) & 0xFF) / 255,
                      b: Double(v & 0xFF) / 255, a: 1)
        } else {
            self.init(r: Double((v >> 24) & 0xFF) / 255, g: Double((v >> 16) & 0xFF) / 255,
                      b: Double((v >> 8) & 0xFF) / 255, a: Double(v & 0xFF) / 255)
        }
    }
    init(r: Double, g: Double, b: Double, a: Double) { self.r = r; self.g = g; self.b = b; self.a = a }
}

enum RegionShape: String, Equatable { case rect, ellipse }

/// A region of a window, in window-normalised coordinates [0,1], origin top-left.
struct PresetRegion: Equatable {
    var name: String
    var rect: CGRect        // x, y, w, h normalised to the window frame (bounding box for ellipses)
    var mode: RedactMode
    var shape: RegionShape = .rect
}

struct AppPreset: Equatable {
    var regions: [PresetRegion]
    var whenFrontmostOnly: Bool
}

/// A rule matched against any window: by bundle ID and/or a case-insensitive title substring.
/// Lets one browser bundle carry different masks for "WhatsApp", "Gmail", … tabs.
struct MaskRule: Equatable {
    var name: String
    var bundleID: String?
    var titleContains: String?
    var regions: [PresetRegion]
    var whenFrontmostOnly: Bool

    func matches(_ w: TrackedWindow) -> Bool {
        if let b = bundleID, b != w.bundleID { return false }
        if let t = titleContains {
            guard let title = w.title, title.range(of: t, options: .caseInsensitive) != nil else { return false }
        }
        return bundleID != nil || titleContains != nil
    }
}

struct HotkeyConfig: Equatable {
    var panic: String?
    var toggle: String?
    var pick: String?
    var reveal: String?       // hold to temporarily unmask the frontmost app
    var allowlist: String?    // toggle allowlist mode
    var endShare: String?     // emergency: remove the virtual display (ends the share)
}

/// The fully-resolved in-memory form of ~/.config/sharemask/presets.json.
struct PresetConfig: Equatable {
    var version: Int
    var defaultMode: RedactMode
    var apps: [String: AppPreset]          // keyed by bundle identifier
    var rules: [MaskRule]
    /// Allowlist mode: everything is masked except these bundle IDs (toggle with the hotkey/menu).
    var allowlist: [String]
    /// Mask macOS notification banners (Notification Center windows) automatically.
    var maskNotifications: Bool
    var hotkeys: HotkeyConfig
    var pointerGuard: Bool
    var hud: Bool
    /// "ask" (default): detect meetings and ask before capturing · "auto": start/stop silently ·
    /// "always": capture whenever the proxy is started · "manual": only via the menu.
    var captureMode: String
    /// Look at upcoming calendar events (needs Calendar access) to prompt before a meeting starts.
    var calendarLookahead: Bool

    static let empty = PresetConfig(version: 1, defaultMode: .defaultPixellate, apps: [:], rules: [], allowlist: [],
                                    maskNotifications: true,
                                    hotkeys: HotkeyConfig(panic: "cmd+shift+ctrl+B",
                                                          toggle: "cmd+shift+ctrl+M",
                                                          pick: "cmd+shift+ctrl+P",
                                                          reveal: "cmd+shift+ctrl+R",
                                                          allowlist: "cmd+shift+ctrl+A",
                                                          endShare: "cmd+shift+ctrl+X"),
                                    pointerGuard: true, hud: false, captureMode: "ask", calendarLookahead: false)
}

// MARK: - JSON (de)serialisation

/// Raw Codable mirror of the on-disk schema. Kept separate from the resolved model so that
/// per-region fields can fall back to `defaults`, and unknown keys are ignored.
struct PresetFile: Codable {
    struct Defaults: Codable {
        var mode: String?
        var scale: Int?
        var radius: Float?
        var color: String?
    }
    struct Region: Codable {
        var name: String?
        var rect: [Double]
        var mode: String?
        var scale: Int?
        var radius: Float?
        var color: String?
        var shape: String?
    }
    struct App: Codable {
        var regions: [Region]
        var whenFrontmostOnly: Bool?
    }
    struct Hotkeys: Codable {
        var panic: String?
        var toggle: String?
        var pick: String?
        var reveal: String?
        var allowlist: String?
        var endShare: String?
    }
    struct Rule: Codable {
        var name: String?
        var bundleID: String?
        var titleContains: String?
        var regions: [Region]
        var whenFrontmostOnly: Bool?
    }
    var version: Int?
    var defaults: Defaults?
    var apps: [String: App]?
    var rules: [Rule]?
    var allowlist: [String]?
    var maskNotifications: Bool?
    var hotkeys: Hotkeys?
    var pointerGuard: Bool?
    var hud: Bool?
    var idleMode: Bool?          // legacy alias: true → capture "auto"
    var capture: String?
    var calendarLookahead: Bool?
}

enum PresetError: Error, CustomStringConvertible {
    case badRect(app: String, region: String)
    case unknownMode(String)
    case badColor(String)
    case unsupportedVersion(Int)

    var description: String {
        switch self {
        case .badRect(let app, let r): return "region '\(r)' of \(app): rect must be [x, y, w, h] within [0,1]"
        case .unknownMode(let m): return "unknown mode '\(m)' (expected pixellate | blur | solid)"
        case .badColor(let c): return "bad color '\(c)' (expected #RRGGBB)"
        case .unsupportedVersion(let v): return "unsupported presets version \(v)"
        }
    }
}

extension PresetConfig {
    static func parse(data: Data) throws -> PresetConfig {
        let file = try JSONDecoder().decode(PresetFile.self, from: data)
        return try resolve(file)
    }

    static func resolve(_ file: PresetFile) throws -> PresetConfig {
        let version = file.version ?? 1
        guard version == 1 else { throw PresetError.unsupportedVersion(version) }

        let d = file.defaults
        let defaultMode = try mode(name: d?.mode ?? "pixellate", scale: d?.scale, radius: d?.radius,
                                   color: d?.color, fallback: .defaultPixellate)

        func parseRegions(_ list: [PresetFile.Region], owner: String) throws -> [PresetRegion] {
            var regions: [PresetRegion] = []
            for (i, r) in list.enumerated() {
                let name = r.name ?? "region \(i + 1)"
                guard r.rect.count == 4 else { throw PresetError.badRect(app: owner, region: name) }
                let rect = CGRect(x: r.rect[0], y: r.rect[1], width: r.rect[2], height: r.rect[3])
                guard rect.width > 0, rect.height > 0,
                      rect.minX >= 0, rect.minY >= 0, rect.maxX <= 1.0001, rect.maxY <= 1.0001
                else { throw PresetError.badRect(app: owner, region: name) }
                let m = try mode(name: r.mode ?? d?.mode ?? "pixellate",
                                 scale: r.scale ?? d?.scale, radius: r.radius ?? d?.radius,
                                 color: r.color ?? d?.color, fallback: defaultMode)
                let shape = RegionShape(rawValue: (r.shape ?? "rect").lowercased()) ?? .rect
                regions.append(PresetRegion(name: name, rect: rect.clamped01, mode: m, shape: shape))
            }
            return regions
        }

        var apps: [String: AppPreset] = [:]
        for (bundleID, app) in file.apps ?? [:] {
            apps[bundleID] = AppPreset(regions: try parseRegions(app.regions, owner: bundleID),
                                       whenFrontmostOnly: app.whenFrontmostOnly ?? false)
        }
        var rules: [MaskRule] = []
        for (i, r) in (file.rules ?? []).enumerated() {
            let name = r.name ?? "rule \(i + 1)"
            rules.append(MaskRule(name: name, bundleID: r.bundleID, titleContains: r.titleContains,
                                  regions: try parseRegions(r.regions, owner: name),
                                  whenFrontmostOnly: r.whenFrontmostOnly ?? false))
        }

        let e = PresetConfig.empty.hotkeys
        let hk = HotkeyConfig(panic: file.hotkeys?.panic ?? e.panic, toggle: file.hotkeys?.toggle ?? e.toggle,
                              pick: file.hotkeys?.pick ?? e.pick, reveal: file.hotkeys?.reveal ?? e.reveal,
                              allowlist: file.hotkeys?.allowlist ?? e.allowlist, endShare: file.hotkeys?.endShare ?? e.endShare)
        return PresetConfig(version: version, defaultMode: defaultMode, apps: apps, rules: rules,
                            allowlist: file.allowlist ?? [], maskNotifications: file.maskNotifications ?? true, hotkeys: hk,
                            pointerGuard: file.pointerGuard ?? true, hud: file.hud ?? false,
                            captureMode: captureMode(file), calendarLookahead: file.calendarLookahead ?? false)
    }

    private static func captureMode(_ file: PresetFile) -> String {
        if let c = file.capture?.lowercased(), ["ask", "auto", "always", "manual"].contains(c) { return c }
        if file.idleMode == true { return "auto" }
        return "ask"
    }

    private static func mode(name: String, scale: Int?, radius: Float?, color: String?,
                             fallback: RedactMode) throws -> RedactMode {
        switch name.lowercased() {
        case "pixellate", "pixelate", "pixel":
            return .pixellate(scale: max(2, scale ?? 24))
        case "blur":
            return .blur(radius: max(1, radius ?? 30))
        case "solid", "black", "box":
            guard let c = RGBA(hex: color ?? "#000000") else { throw PresetError.badColor(color ?? "") }
            return .solid(color: c)
        default:
            throw PresetError.unknownMode(name)
        }
    }
}

extension CGRect {
    var clamped01: CGRect {
        let x0 = max(0, minX), y0 = max(0, minY), x1 = min(1, maxX), y1 = min(1, maxY)
        return CGRect(x: x0, y: y0, width: max(0, x1 - x0), height: max(0, y1 - y0))
    }
}
