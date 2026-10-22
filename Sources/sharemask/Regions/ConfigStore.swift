import Foundation

/// Loads `~/.config/sharemask/presets.json`, watches it for changes (live reload) and keeps the
/// last good config when the file is malformed.
final class ConfigStore {
    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/sharemask", isDirectory: true)
    static let fileURL = directory.appendingPathComponent("presets.json")

    private(set) var config: PresetConfig = .empty
    private(set) var lastError: String?
    /// Main thread. Called after every successful reload (and once at start).
    var onChange: ((PresetConfig) -> Void)?
    var onError: ((String?) -> Void)?

    private var dirSource: DispatchSourceFileSystemObject?
    private var fileSource: DispatchSourceFileSystemObject?
    private var lastData: Data?
    private let queue = DispatchQueue(label: "sharemask.config")

    func start() {
        ensureFileExists()
        reload()
        watch()
    }

    /// Creates the config directory and seeds presets.json from the bundled example if missing.
    func ensureFileExists() {
        let fm = FileManager.default
        try? fm.createDirectory(at: ConfigStore.directory, withIntermediateDirectories: true)
        guard !fm.fileExists(atPath: ConfigStore.fileURL.path) else { return }
        if let example = Bundle.main.url(forResource: "presets.example", withExtension: "json"),
           let data = try? Data(contentsOf: example) {
            try? data.write(to: ConfigStore.fileURL)
        } else {
            try? ConfigStore.defaultJSON.data(using: .utf8)?.write(to: ConfigStore.fileURL)
        }
        Log.info("created \(ConfigStore.fileURL.path)")
    }

    func reload() {
        queue.async { self.reloadSync() }
    }

    private func reloadSync() {
        guard let data = try? Data(contentsOf: ConfigStore.fileURL) else {
            report(error: "presets.json missing or unreadable")
            return
        }
        if data == lastData { return }
        lastData = data
        do {
            let cfg = try PresetConfig.parse(data: data)
            DispatchQueue.main.async {
                self.config = cfg
                self.lastError = nil
                self.onError?(nil)
                self.onChange?(cfg)
            }
            Log.info("presets loaded: \(cfg.apps.count) app(s)")
        } catch let e as DecodingError {
            report(error: "presets.json: \(ConfigStore.describe(e))")
        } catch {
            report(error: "presets.json: \(error)")
        }
    }

    private func report(error: String) {
        Log.warn(error)
        DispatchQueue.main.async { self.lastError = error; self.onError?(error) }
    }

    /// Editors save atomically (write temp + rename), so watching the file descriptor alone goes
    /// stale. Watch the directory for writes and the file for writes; re-arm the file watcher when
    /// it gets replaced.
    private func watch() {
        let dirFD = open(ConfigStore.directory.path, O_EVTONLY)
        if dirFD >= 0 {
            let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: dirFD, eventMask: [.write], queue: queue)
            s.setEventHandler { [weak self] in self?.fileChanged() }
            s.setCancelHandler { close(dirFD) }
            s.resume()
            dirSource = s
        }
        watchFile()
    }

    private func watchFile() {
        fileSource?.cancel(); fileSource = nil
        let fd = open(ConfigStore.fileURL.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename, .extend], queue: queue)
        s.setEventHandler { [weak self] in self?.fileChanged() }
        s.setCancelHandler { close(fd) }
        s.resume()
        fileSource = s
    }

    private var debounce: DispatchWorkItem?
    private func fileChanged() {
        debounce?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.watchFile()
            self.reloadSync()
        }
        debounce = item
        queue.asyncAfter(deadline: .now() + 0.15, execute: item)
    }

    // MARK: Writing (used by the RegionPicker)

    /// Merges regions into the app's entry, preserving everything else in the file verbatim-ish
    /// (round-trips through JSONSerialization so unknown keys survive).
    func addRegions(bundleID: String, regions: [(name: String, rect: CGRect)], replace: Bool) throws {
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: ConfigStore.fileURL),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = obj
        }
        if root["version"] == nil { root["version"] = 1 }
        var apps = root["apps"] as? [String: Any] ?? [:]
        var app = apps[bundleID] as? [String: Any] ?? [:]
        var list = replace ? [] : (app["regions"] as? [[String: Any]] ?? [])
        for r in regions {
            list.append(["name": r.name, "rect": [round4(r.rect.minX), round4(r.rect.minY), round4(r.rect.width), round4(r.rect.height)]])
        }
        app["regions"] = list
        apps[bundleID] = app
        root["apps"] = apps
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: ConfigStore.fileURL, options: .atomic)
    }

    private func round4(_ v: CGFloat) -> Double { (Double(v) * 10000).rounded() / 10000 }

    static func describe(_ e: DecodingError) -> String {
        switch e {
        case .keyNotFound(let k, let c): return "missing key '\(k.stringValue)' at \(path(c))"
        case .typeMismatch(_, let c): return "wrong type at \(path(c)): \(c.debugDescription)"
        case .valueNotFound(_, let c): return "missing value at \(path(c))"
        case .dataCorrupted(let c): return "invalid JSON: \(c.debugDescription)"
        @unknown default: return "\(e)"
        }
    }
    private static func path(_ c: DecodingError.Context) -> String {
        c.codingPath.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: ".")
    }

    static let defaultJSON = """
    {
      "version": 1,
      "defaults": { "mode": "pixellate", "scale": 24 },
      "apps": {},
      "hotkeys": { "panic": "cmd+shift+ctrl+B", "toggle": "cmd+shift+ctrl+M", "pick": "cmd+shift+ctrl+P" },
      "pointerGuard": true,
      "hud": false,
      "idleMode": false
    }
    """
}
