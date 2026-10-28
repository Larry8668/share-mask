import AppKit

/// Once-a-day check for a newer GitHub release. This is sharemask's ONLY network request: one
/// unauthenticated GET to api.github.com for the latest release's tag. Nothing about the user or
/// the screen is sent. Disable it under Settings ▸ Check for updates.
///
/// Updating: if the app was installed with Homebrew, "Update now" writes a small .command script
/// and opens it in Terminal (visible progress, no Automation permission needed): it quits
/// sharemask, runs `brew upgrade --cask sharemask`, and relaunches. Otherwise it opens the release
/// page to download the zip.
final class UpdateChecker {
    static let repo = "Larry8668/share-mask"
    static let brewCommand = "brew update && brew upgrade --cask sharemask"

    enum Status: Equatable {
        case unknown, checking, upToDate(String), available(String), failed(String)
    }

    private(set) var status: Status = .unknown
    var onChange: (() -> Void)?
    private var timer: Timer?
    private let defaultsKey = "checkForUpdates"

    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey); newValue ? start() : stop() }
    }

    static var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0" }

    /// Installed via the Homebrew cask (its Caskroom entry exists).
    static var installedWithHomebrew: Bool {
        ["/opt/homebrew/Caskroom/sharemask", "/usr/local/Caskroom/sharemask"].contains { FileManager.default.fileExists(atPath: $0) }
    }

    func start() {
        guard enabled, timer == nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.check() }  // daily, automatic
        timer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { [weak self] _ in self?.check() }
    }

    func stop() { timer?.invalidate(); timer = nil; status = .unknown; onChange?() }

    /// `manual` checks run even when the daily check is turned off.
    func check(manual: Bool = false) {
        guard enabled || manual else { return }
        status = .checking; onChange?()
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(UpdateChecker.repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("sharemask/\(UpdateChecker.currentVersion)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, error in
            let result: Status
            if let error = error {
                result = .failed(error.localizedDescription)
            } else if let data = data, (resp as? HTTPURLResponse)?.statusCode == 200,
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tag = obj["tag_name"] as? String {
                let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
                result = UpdateChecker.isNewer(latest, than: UpdateChecker.currentVersion) ? .available(latest) : .upToDate(latest)
            } else {
                result = .failed("HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)")
            }
            DispatchQueue.main.async {
                self?.status = result
                Log.info("update check: \(result)")
                self?.onChange?()
            }
        }.resume()
    }

    /// Numeric dotted-version comparison ("0.1.10" > "0.1.9").
    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }, pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// Homebrew: run the upgrade visibly in Terminal and relaunch. Otherwise open the release page.
    func updateNow() {
        guard UpdateChecker.installedWithHomebrew else { openReleasePage(); return }
        let script = """
        #!/bin/zsh
        # Written by sharemask to update itself via Homebrew. Safe to delete.
        export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
        echo "Updating sharemask with Homebrew…"
        AGENT="$HOME/Library/LaunchAgents/\(KeepAlive.label).plist"
        # App lock's keep-alive agent would relaunch the old version mid-upgrade: unload it first.
        [ -f "$AGENT" ] && launchctl bootout gui/$(id -u)/\(KeepAlive.label) 2>/dev/null
        pkill -x sharemask 2>/dev/null; sleep 1
        \(UpdateChecker.brewCommand)
        if [ -f "$AGENT" ]; then launchctl bootstrap gui/$(id -u) "$AGENT"; else open -a sharemask; fi
        echo "\\nDone — sharemask relaunched. You can close this window."
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("update-sharemask.command")
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            Log.info("update: opening \(url.path) in Terminal")
            NSWorkspace.shared.open(url)
        } catch {
            Log.error("update: could not write script: \(error)")
            copyCommand()
        }
    }

    func copyCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(UpdateChecker.brewCommand, forType: .string)
    }

    func openReleasePage() {
        NSWorkspace.shared.open(URL(string: "https://github.com/\(UpdateChecker.repo)/releases/latest")!)
    }
}
