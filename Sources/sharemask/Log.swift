import Foundation
import os

/// Logging façade. Every line goes to three places so problems can be reconstructed after the fact:
///
/// 1. **File**: `~/Library/Logs/sharemask/sharemask.log` (append; rotated at 5 MB to `.1`, the
///    previous `.1` is deleted, so disk use is capped at ~10 MB). Survives relaunches and crashes;
///    readable with `tail -f` or Console.app.
/// 2. **Unified log**: subsystem `dev.sharemask.app` at notice/error level (info-level entries are
///    NOT persisted by macOS, so we never log below notice).
///    `/usr/bin/log show --last 1h --info --predicate 'subsystem == "dev.sharemask.app"'`
/// 3. **stderr** when attached to a terminal or `SHAREMASK_VERBOSE` is set.
///
/// Uncaught exceptions and fatal signals write a final line before the process dies.
enum Log {
    private static let logger = Logger(subsystem: "dev.sharemask.app", category: "app")
    private static let stderrIsTTY = isatty(STDERR_FILENO) != 0
    private static let verbose = ProcessInfo.processInfo.environment["SHAREMASK_VERBOSE"] != nil
    private static let queue = DispatchQueue(label: "sharemask.log", qos: .utility)
    private static let formatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"; return f
    }()
    static let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/sharemask", isDirectory: true)
    static let fileURL = directory.appendingPathComponent("sharemask.log")
    private static let maxBytes = 5 * 1024 * 1024
    private static var handle: FileHandle?

    static func info(_ message: String) { emit("INFO", message); logger.notice("\(message, privacy: .public)") }
    static func warn(_ message: String) { emit("WARN", message); logger.warning("\(message, privacy: .public)") }
    static func error(_ message: String) { emit("ERROR", message); logger.error("\(message, privacy: .public)") }

    /// Call once at launch: opens the file, logs a session header, installs crash hooks.
    static func start(role: String) {
        queue.sync { openFile(); pruneStrays() }
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        info("=== sharemask \(v) \(role) started · pid \(getpid()) · macOS \(os) · \(Bundle.main.bundlePath)")
        installCrashHooks()
    }

    private static func emit(_ level: String, _ message: String) {
        let line = "\(formatter.string(from: Date())) [\(level)] \(message)\n"
        if stderrIsTTY || verbose { FileHandle.standardError.write(line.data(using: .utf8)!) }
        queue.async { writeLine(line) }
    }

    private static func openFile() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: fileURL)
        handle?.seekToEndOfFile()
    }

    private static func writeLine(_ line: String) {
        if handle == nil { openFile() }
        guard let h = handle, let data = line.data(using: .utf8) else { return }
        h.write(data)
        if h.offsetInFile > maxBytes { rotate() }
    }

    /// Removes anything in the log folder other than the two files we manage (older layouts, crash
    /// dumps copied there by hand, …) so the folder can never grow unbounded.
    private static func pruneStrays() {
        guard let items = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for url in items where !["sharemask.log", "sharemask.log.1"].contains(url.lastPathComponent) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func rotate() {
        handle?.closeFile(); handle = nil
        let old = directory.appendingPathComponent("sharemask.log.1")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: fileURL, to: old)
        openFile()
    }

    /// Synchronous, async-signal-unsafe-but-last-resort write used from crash handlers.
    private static func writeNow(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: fileURL) { h.seekToEndOfFile(); h.write(data); h.closeFile() }
        FileHandle.standardError.write(data)
    }

    private static func installCrashHooks() {
        NSSetUncaughtExceptionHandler { exc in
            Log.writeNow("\(Log.formatter.string(from: Date())) [FATAL] uncaught exception \(exc.name.rawValue): \(exc.reason ?? "") \n\(exc.callStackSymbols.joined(separator: "\n"))\n")
        }
        for sig in [SIGSEGV, SIGBUS, SIGILL, SIGABRT, SIGTRAP, SIGFPE] {
            signal(sig) { s in
                Log.writeNow("\(Log.formatter.string(from: Date())) [FATAL] signal \(s) — see ~/Library/Logs/DiagnosticReports for the crash report\n")
                signal(s, SIG_DFL)
                raise(s)
            }
        }
    }
}
