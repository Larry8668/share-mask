import Foundation

/// Per-user launchd agent that relaunches sharemask if it's force-quit or killed while App lock is
/// on. No admin rights: a plist in ~/Library/LaunchAgents. Clean exits (authenticated Quit,
/// logout, shutdown) exit 0 and are NOT relaunched (KeepAlive.SuccessfulExit = false).
enum KeepAlive {
    static let label = "dev.sharemask.keepalive"
    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }
    private static var domain: String { "gui/\(getuid())" }

    /// This process was started by the agent.
    static var runningUnderAgent: Bool { ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == label }

    static var isLoaded: Bool { launchctl(["print", "\(domain)/\(label)"]) == 0 }

    static var installedExecutable: String? {
        guard let d = NSDictionary(contentsOf: plistURL), let args = d["ProgramArguments"] as? [String] else { return nil }
        return args.first
    }

    /// Writes the plist for the current executable and loads it (which starts an instance).
    static func install() {
        let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [exe],
            "RunAtLoad": true,                                  // also covers launch at login
            "KeepAlive": ["SuccessfulExit": false],             // relaunch only after a crash/kill
            "ThrottleInterval": 2,
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua",
            "AbandonProcessGroup": true,                        // helper scripts survive our exit
        ]
        try? FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        (plist as NSDictionary).write(to: plistURL, atomically: true)
        if isLoaded { launchctl(["bootout", "\(domain)/\(label)"]) }
        let r = launchctl(["bootstrap", domain, plistURL.path])
        Log.info("keep-alive agent installed for \(exe) (bootstrap \(r == 0 ? "ok" : "exit \(r)"))")
    }

    /// Make sure an agent-managed instance is running (used when this instance was opened manually).
    static func kickstart() { launchctl(["kickstart", "\(domain)/\(label)"]) }

    /// Unload + delete. If this process IS the agent's job, unloading kills it, so the work runs in a
    /// detached shell that then reopens sharemask normally.
    static func uninstall(reopen: Bool) {
        let bundle = Bundle.main.bundlePath
        let script = "launchctl bootout \(domain)/\(label) 2>/dev/null; rm -f '\(plistURL.path)'" + (reopen ? "; sleep 1; open -n '\(bundle)'" : "")
        if runningUnderAgent {
            Log.info("keep-alive agent: removing (from inside the job; sharemask will reopen)")
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", script]
            try? p.run()
        } else {
            launchctl(["bootout", "\(domain)/\(label)"])
            try? FileManager.default.removeItem(at: plistURL)
            Log.info("keep-alive agent removed")
        }
    }

    @discardableResult
    private static func launchctl(_ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus } catch { return -1 }
    }
}
