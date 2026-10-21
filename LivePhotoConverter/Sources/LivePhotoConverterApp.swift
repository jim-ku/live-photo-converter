import SwiftUI
import AppKit
import Foundation

/// Append-only diagnostics that survive a crash (flush after every line).
enum DropLog {
    static let directory: URL = {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("Logs/LivePhotoConverter", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static var logFileURL: URL { directory.appendingPathComponent("drop.log") }
    static var lastBreadcrumbURL: URL { directory.appendingPathComponent("last-breadcrumb.txt") }

    private static let lock = NSLock()
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
        log("app launch — log at \(logFileURL.path)")
    }

    static func log(_ message: String, file: String = #fileID, line: Int = #line) {
        let stamp = formatter.string(from: Date())
        let lineText = "\(stamp) [\(file):\(line)] \(message)\n"
        lock.lock()
        defer { lock.unlock() }
        writeSynced(lineText)
        NSLog("[LivePhotoConverter] %@", message)
    }

    static func fatal(_ message: String) {
        let stamp = formatter.string(from: Date())
        let lineText = "\(stamp) FATAL \(message)\n"
        lock.lock()
        defer { lock.unlock() }
        writeSynced(lineText)
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
