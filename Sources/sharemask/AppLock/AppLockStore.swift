import Foundation
import Security
import CommonCrypto

/// App-lock settings. Since 0.2.13 they live in a file of their own (~/.config/sharemask/applock.json, readable only by
/// you) and only the optional sharemask password's hash is in the Keychain: with sharemask
/// self-signed, macOS ties Keychain items to one exact build and asked for access after every
/// update, and a denied read used to leave App lock silently off. Someone at your unlocked Mac could
/// edit the file, but they could stop sharemask outright anyway; the list is visible in its window.
struct AppLockConfig: Codable, Equatable {
    var enabled = false
    var apps: [String] = []                 // bundle IDs
    /// Relock an unlocked app after it has been in the background this long (0 = as soon as it
    /// loses focus).
    var relockMinutes = 5
    var relockOnSleep = true                // also on screen lock / display sleep
    var guardQuit = true                    // quitting sharemask needs authentication
    var keepAlive = true                    // login agent relaunches sharemask if force-quit
    /// Legacy (≤ 0.2.12, when the whole config was in the Keychain): moved to its own Keychain item
    /// on migration and never written to the file.
    var passwordHash: String?
    /// A sharemask password is set (its hash is in the Keychain, read only when it's typed).
    var passwordSet: Bool?
    var hasPassword: Bool { (passwordSet ?? false) || passwordHash != nil }
    /// After an unlocked app's last window closes, relock after this many seconds (0 = instantly,
    /// -1 = never). Optional so settings saved by older versions still decode (a missing key in a
    /// non-optional field would make the whole saved config unreadable).
    var closeRelockSeconds: Int?
    var closeDelay: Int { closeRelockSeconds ?? 0 }
    /// Cover notification banners from locked apps on your own screen (off by default).
    var hideNotifications: Bool?
    var hidesNotifications: Bool { hideNotifications ?? false }

    /// Per-app overrides. Anything not set falls back to the defaults above (which is also what
    /// newly added apps get). Optional for decoding settings saved by older versions.
    struct AppSettings: Codable, Equatable {
        var closeRelockSeconds: Int?
        var relockMinutes: Int?
        var hideNotifications: Bool?
    }
    var appSettings: [String: AppSettings]?

    func closeDelay(for b: String) -> Int { appSettings?[b]?.closeRelockSeconds ?? closeDelay }
    func relockMinutes(for b: String) -> Int { appSettings?[b]?.relockMinutes ?? relockMinutes }
    func hidesNotifications(for b: String) -> Bool { appSettings?[b]?.hideNotifications ?? hidesNotifications }
    var anyHidesNotifications: Bool { apps.contains { hidesNotifications(for: $0) } }

    mutating func setAppSettings(_ b: String, _ change: (inout AppSettings) -> Void) {
        var all = appSettings ?? [:]
        var a = all[b] ?? AppSettings()
        change(&a)
        all[b] = a
        appSettings = all
    }
}

enum AppLockStore {
    private static let service = "dev.sharemask.applock"
    private static let testMode = CommandLine.arguments.contains("--lock-test-store")
        || ProcessInfo.processInfo.environment["SHAREMASK_LOCK_TEST_STORE"] != nil
    /// ≤ 0.2.12: the whole config as one Keychain item.
    private static let legacyAccount = testMode ? "config-test" : "config"
    private static let passwordAccount = testMode ? "password-test" : "password"

    static var fileURL: URL {
        ConfigStore.directory.appendingPathComponent(testMode ? "applock-test.json" : "applock.json")
    }

    /// Something was saved before (file or legacy Keychain item). Never prompts.
    static var hasSavedConfig: Bool {
        FileManager.default.fileExists(atPath: fileURL.path) || legacyItemExists
    }

    private static var legacyItemExists: Bool {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: legacyAccount]
        return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess   // attributes only: no prompt
    }

    /// Tests: pretend macOS refused Keychain access (test store only).
    static var simulateDenied = testMode && ProcessInfo.processInfo.environment["SHAREMASK_TEST_KEYCHAIN_DENY"] != nil

    enum Loaded {
        case ok(AppLockConfig)
        /// Settings are still in the Keychain (from ≤ 0.2.12) and macOS didn't allow reading them.
        case keychainDenied(OSStatus)
    }

    static func load() -> Loaded {
        if let data = try? Data(contentsOf: fileURL) {
            if let cfg = try? JSONDecoder().decode(AppLockConfig.self, from: data) { return .ok(cfg) }
            Log.error("app lock: \(fileURL.lastPathComponent) is unreadable; starting from defaults")
            return .ok(AppLockConfig())
        }
        guard legacyItemExists else { return .ok(AppLockConfig()) }
        // One-time move out of the Keychain (this read is the one that may ask for access).
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: legacyAccount, kSecReturnData as String: true]
        var out: CFTypeRef?
        let status = simulateDenied ? errSecAuthFailed : SecItemCopyMatching(q as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data,
              var cfg = try? JSONDecoder().decode(AppLockConfig.self, from: data) else {
            Log.warn("app lock: couldn't read settings from the Keychain (\(status)) — they stay there until access is allowed")
            return .keychainDenied(status)
        }
        if let h = cfg.passwordHash {
            guard setPasswordHash(h) else {
                Log.error("app lock: couldn't move the sharemask password to its own Keychain item; will retry")
                return .ok(cfg)   // usable this run (hash in memory); the move is retried next launch
            }
            cfg.passwordHash = nil
            cfg.passwordSet = true
        }
        guard save(cfg) else { return .ok(cfg) }
        let del: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                  kSecAttrAccount as String: legacyAccount]
        let d = SecItemDelete(del as CFDictionary)
        Log.info("app lock: settings moved from the Keychain to \(fileURL.lastPathComponent) (old item removed: \(d == errSecSuccess))")
        return .ok(cfg)
    }

    /// Writes the settings file (owner read/write only). Never contains the password hash.
    @discardableResult
    static func save(_ cfg: AppLockConfig) -> Bool {
        var c = cfg
        c.passwordHash = nil
        guard let data = try? JSONEncoder().encode(c) else { return false }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            return true
        } catch {
            Log.error("app lock: couldn't save settings: \(error)")
            return false
        }
    }

    // MARK: The sharemask password (Keychain)

    enum PasswordRead { case hash(String), missing, denied(OSStatus) }

    /// Reads the password hash. May ask for Keychain access (e.g. the first time after an update).
    static func readPasswordHash() -> PasswordRead {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: passwordAccount, kSecReturnData as String: true]
        var out: CFTypeRef?
        let status = simulateDenied ? errSecAuthFailed : SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return .missing }
        guard status == errSecSuccess, let data = out as? Data, let h = String(data: data, encoding: .utf8) else { return .denied(status) }
        return .hash(h)
    }

    @discardableResult
    static func setPasswordHash(_ hash: String) -> Bool {
        _ = deletePasswordHash()
        var add: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                  kSecAttrAccount as String: passwordAccount, kSecValueData as String: Data(hash.utf8)]
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        add[kSecAttrLabel as String] = "sharemask App lock password"
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess { Log.error("app lock: keychain save failed \(status)") }
        return status == errSecSuccess
    }

    @discardableResult
    static func deletePasswordHash() -> Bool {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: passwordAccount]
        let s = SecItemDelete(q as CFDictionary)
        return s == errSecSuccess || s == errSecItemNotFound
    }

    /// Tests: an old-style (≤ 0.2.12) settings item, to exercise the move out of the Keychain.
    static func writeLegacyForTesting(_ cfg: AppLockConfig) {
        guard testMode, let data = try? JSONEncoder().encode(cfg) else { return }
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: legacyAccount]
        SecItemDelete(q as CFDictionary)
        var add = q; add[kSecValueData as String] = data
        Log.info("test: legacy keychain settings written (\(SecItemAdd(add as CFDictionary, nil)))")
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Removes the test entries (tests only).
    static func deleteTestEntry() {
        guard testMode else { return }
        for account in ["config-test", "password-test"] {
            let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
            SecItemDelete(q as CFDictionary)
        }
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: Password hashing (PBKDF2-SHA256, 200k rounds, 16-byte salt)

    static func hash(_ password: String, salt: Data? = nil) -> String {
        let salt = salt ?? Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        var derived = Data(count: 32)
        let pw = Array(password.utf8)
        _ = derived.withUnsafeMutableBytes { d in
            salt.withUnsafeBytes { s in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pw.map { Int8(bitPattern: $0) }, pw.count,
                                     s.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 200_000,
                                     d.bindMemory(to: UInt8.self).baseAddress, 32)
            }
        }
        return salt.base64EncodedString() + ":" + derived.base64EncodedString()
    }

    static func verify(_ password: String, against stored: String) -> Bool {
        let parts = stored.split(separator: ":")
        guard parts.count == 2, let salt = Data(base64Encoded: String(parts[0])) else { return false }
        // Constant-time-ish compare of the encoded results.
        let a = Array(hash(password, salt: salt).utf8), b = Array(stored.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
