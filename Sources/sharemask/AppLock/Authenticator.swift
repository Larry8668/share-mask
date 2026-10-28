import Foundation
import LocalAuthentication

/// Touch ID with the Mac login password as fallback (Apple's standard prompt), or the optional
/// sharemask password. The login password always works, so you can't lock yourself out.
enum Authenticator {
    static var touchIDAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    /// System prompt: Touch ID, or the login password. Completion on the main thread.
    static func system(reason: String, completion: @escaping (Bool) -> Void) {
        let ctx = LAContext()
        ctx.localizedCancelTitle = "Cancel"
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else {
            Log.error("app lock: authentication unavailable: \(err?.localizedDescription ?? "?")")
            DispatchQueue.main.async { completion(false) }
            return
        }
        ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, error in
            if !ok { Log.info("app lock: system auth failed/cancelled: \(error?.localizedDescription ?? "")") }
            DispatchQueue.main.async { completion(ok) }
        }
    }

    static func customPassword(_ password: String, config: AppLockConfig) -> Bool {
        guard let stored = config.passwordHash, !password.isEmpty else { return false }
        return AppLockStore.verify(password, against: stored)
    }
}
