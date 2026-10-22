import Foundation
import os

/// Tiny logging façade: unified log (subsystem dev.sharemask.app) + stderr when run from a terminal.
enum Log {
    private static let logger = Logger(subsystem: "dev.sharemask.app", category: "app")
    private static let stderrIsTTY = isatty(STDERR_FILENO) != 0
    private static let formatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f
    }()

    static func info(_ message: String) { emit("INFO", message); logger.info("\(message, privacy: .public)") }
    static func warn(_ message: String) { emit("WARN", message); logger.warning("\(message, privacy: .public)") }
    static func error(_ message: String) { emit("ERROR", message); logger.error("\(message, privacy: .public)") }

    private static func emit(_ level: String, _ message: String) {
        guard stderrIsTTY || ProcessInfo.processInfo.environment["SHAREMASK_VERBOSE"] != nil else { return }
        FileHandle.standardError.write("\(formatter.string(from: Date())) [\(level)] \(message)\n".data(using: .utf8)!)
    }
}
