import SwiftUI
import AppKit
import Foundation
import OSLog

/// Append-only diagnostics that survive a crash (synchronize after every line).
enum DropLog {
    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("LivePhotoConverter", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static var logFileURL: URL { directory.appendingPathComponent("debug.log") }
    static var lastBreadcrumbURL: URL { directory.appendingPathComponent("last-breadcrumb.txt") }

    /// Sandboxed apps resolve Application Support under Containers — never the host ~/Library path.
    static var pathHint: String { logFileURL.path }

    /// Bumped on each diagnostics push so Console/file show which binary Jim ran.
    static let sourceRevision = "photos-album-fix"

    private static let lock = NSLock()
    private static let osLog = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.jim.LivePhotoConverter",
        category: "drop"
    )
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func installCrashTraps() {
        NSSetUncaughtExceptionHandler { exception in
            let stack = exception.callStackSymbols.prefix(24).joined(separator: "\n")
            DropLog.fatal("NSException name=\(exception.name.rawValue) reason=\(exception.reason ?? "nil")\n\(stack)")
        }
        let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let bid = Bundle.main.bundleIdentifier ?? "?"
        log("—— session —— v\(ver) (\(build)) bundle=\(bid) rev=\(sourceRevision)")
        log("debug.log path: \(logFileURL.path)")
    }

    static func log(_ message: String, file: String = #fileID, line: Int = #line) {
        let stamp = formatter.string(from: Date())
        let lineText = "\(stamp) [\(file):\(line)] \(message)\n"
        lock.lock()
        defer { lock.unlock() }
        writeSynced(lineText)
        osLog.log(level: .default, "\(message, privacy: .public)")
        NSLog("[LivePhotoConverter] %@", message)
    }

    static func fatal(_ message: String) {
        let stamp = formatter.string(from: Date())
        let lineText = "\(stamp) FATAL \(message)\n"
        lock.lock()
        defer { lock.unlock() }
        writeSynced(lineText)
        osLog.fault("\(message, privacy: .public)")
        NSLog("[LivePhotoConverter] FATAL %@", message)
    }

    private static func writeSynced(_ lineText: String) {
        guard let data = lineText.data(using: .utf8) else { return }
        if !FileManager.default.fileExists(atPath: logFileURL.path) {
            FileManager.default.createFile(atPath: logFileURL.path, contents: nil)
        }
        if let handle = try? FileHandle(forWritingTo: logFileURL) {
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.synchronize()
        }
        try? data.write(to: lastBreadcrumbURL, options: .atomic)
    }

    static func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([logFileURL])
    }
}

@main
struct LivePhotoConverterApp: App {
    init() {
        DropLog.installCrashTraps()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 520, minHeight: 640)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 560, height: 720)
    }
}
