import Foundation
import LocalAuthentication

/// Touch ID with the Mac login password as fallback (Apple's standard prompt), or the optional
/// sharemask password. The login password always works, so you can't lock yourself out.
enum Authenticator {
    static var touchIDAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    /// System prompt: Touch ID, or the login password. Completion on the main thread. Returns the
    /// context so a caller can cancel the prompt (e.g. when the card is dismissed another way).
    @discardableResult
    static func system(reason: String, completion: @escaping (Bool) -> Void) -> LAContext? {
        let ctx = LAContext()
        ctx.localizedCancelTitle = "Cancel"
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else {
            Log.error("app lock: system authentication unavailable: \(err?.localizedDescription ?? "?")")
            DispatchQueue.main.async { completion(false) }
            return nil
        }
        Log.info("app lock: system auth prompt (\(touchIDAvailable ? "Touch ID, password fallback" : "password")) for \(reason)")
        ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, error in
            if ok {
                // .deviceOwnerAuthentication doesn't say which factor was used; biometryType tells
                // whether Touch ID was available for it.
                Log.info("app lock: system auth succeeded (\(ctx.biometryType == .touchID ? "Touch ID or login password" : "login password"))")
            } else {
                let code = (error as? LAError)?.code
                let why: String
                switch code {
                case .userCancel?: why = "cancelled by user"
                case .systemCancel?: why = "cancelled by system"
                case .appCancel?: why = "dismissed (another method used)"
                case .authenticationFailed?: why = "failed"
                case .biometryLockout?: why = "Touch ID locked out (too many attempts)"
                default: why = error?.localizedDescription ?? "unknown"
                }
                Log.info("app lock: system auth not completed: \(why)")
            }
            DispatchQueue.main.async { completion(ok) }
        }
        return ctx
    }

    static func customPassword(_ password: String, config: AppLockConfig) -> Bool {
        guard let stored = config.passwordHash, !password.isEmpty else { return false }
        return AppLockStore.verify(password, against: stored)
    }
}
