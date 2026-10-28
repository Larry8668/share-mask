import Foundation
import Security
import CommonCrypto

/// App-lock settings, kept in the Keychain rather than presets.json: a plain JSON file would let
/// anyone remove an app from the lock list with a text editor.
struct AppLockConfig: Codable, Equatable {
    var enabled = false
    var apps: [String] = []                 // bundle IDs
    /// Relock an unlocked app after it has been in the background this long (0 = as soon as it
    /// loses focus).
    var relockMinutes = 5
    var relockOnSleep = true                // also on screen lock / display sleep
    var guardQuit = true                    // quitting sharemask needs authentication
    var keepAlive = true                    // login agent relaunches sharemask if force-quit
    var passwordHash: String?               // optional sharemask password: base64(salt) + ":" + base64(PBKDF2)
}

enum AppLockStore {
    private static let service = "dev.sharemask.applock"
    /// Tests use a separate Keychain entry so they never touch the user's real App lock settings.
    private static let account = (CommandLine.arguments.contains("--lock-test-store")
        || ProcessInfo.processInfo.environment["SHAREMASK_LOCK_TEST_STORE"] != nil) ? "config-test" : "config"

    static func load() -> AppLockConfig {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data,
              let cfg = try? JSONDecoder().decode(AppLockConfig.self, from: data) else { return AppLockConfig() }
        return cfg
    }

    /// Removes the test entry (tests only).
    static func deleteTestEntry() {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: "config-test"]
        SecItemDelete(q as CFDictionary)
    }

    @discardableResult
    static func save(_ cfg: AppLockConfig) -> Bool {
        guard let data = try? JSONEncoder().encode(cfg) else { return false }
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        let status: OSStatus
        if SecItemCopyMatching(base as CFDictionary, nil) == errSecSuccess {
            status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        } else {
            var add = base; add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            status = SecItemAdd(add as CFDictionary, nil)
        }
        if status != errSecSuccess { Log.error("app lock: keychain save failed \(status)") }
        return status == errSecSuccess
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
