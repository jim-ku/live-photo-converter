import AppKit
import AVFoundation
import Photos
import SwiftUI

enum OutputKind: String, CaseIterable {
    case photos = "Photos album"
    case folder = "Folder"
}

enum DeliveryTarget: Hashable {
    case album(String)
    case folder(URL)

    var name: String {
        switch self {
        case .album(let name): return name
        case .folder(let url): return url.path
        }
    }
}

protocol AlbumLibrary {
    func resolve(_ name: String) async throws -> String
    func create(_ pair: LivePhotoPair) async throws -> String
    func add(_ assetID: String, to albumID: String) async throws
}

struct SystemAlbumLibrary: AlbumLibrary {
    func resolve(_ name: String) async throws -> String {
        try await LivePhotoEngine.resolveOrCreateAlbum(titled: name).localIdentifier
    }
    func create(_ pair: LivePhotoPair) async throws -> String {
        try await LivePhotoEngine.createPhotoAsset(pair)
    }
    func add(_ assetID: String, to albumID: String) async throws {
        try await LivePhotoEngine.addPhotoAsset(assetID, toAlbum: albumID)
    }
}

/// A queue entry owns only this temporary directory. Removing a row or closing its window
/// releases the working copy and generated pair, including after a partially failed import.
final class ClipFiles {
    let directory: URL
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("Clip-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }
    deinit { try? FileManager.default.removeItem(at: directory) }
}

struct TrimSettings: Equatable {
    var trimMode: TrimMode
    var customTrim: CustomTrimTemplate
}

struct QueueItem: Identifiable {
    let id = UUID()
    let source: URL
    var files: ClipFiles?
    var duration: Double = 0
    var nominalFrameRate: Double = 30
    var importError: String?
    var override: TrimSettings?
    var keyframePercent = 0.5
    var pair: LivePhotoPair?
    var photoAssetID: String?
    var delivered = Set<DeliveryTarget>()
    var failures: [DeliveryTarget: String] = [:]

    var filename: String { source.lastPathComponent }
    var url: URL { files?.directory.appendingPathComponent(filename) ?? source }

    func segment(_ defaults: AppDefaults) -> LivePhotoSegment {
        LivePhotoEngine.plannedSegment(sourceDuration: duration, mode: override?.trimMode ?? defaults.trimMode,
                                       custom: override?.customTrim ?? defaults.customTrim)
    }

    mutating func invalidateOutput() {
        if let pair { try? FileManager.default.removeItem(at: pair.movURL.deletingLastPathComponent()) }
        pair = nil
        photoAssetID = nil
        delivered.removeAll()
        failures.removeAll()
    }

    static func ingest(_ source: URL) async -> QueueItem {
        var item = QueueItem(source: source)
        do {
            let files = try ClipFiles()
            let url = files.directory.appendingPathComponent(source.lastPathComponent)
            try FileManager.default.copyItem(at: source, to: url)
            let asset = AVURLAsset(url: url)
            guard let video = try await asset.loadTracks(withMediaType: .video).first else {
                throw LivePhotoEngineError.noVideoTrack
            }
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration > 0 else { throw LivePhotoEngineError.cannotCreateReader }
            let rate = try await video.load(.nominalFrameRate)
            item.nominalFrameRate = rate.isFinite && rate > 0 ? Double(rate) : 30
            item.duration = duration
            item.files = files
        } catch {
            item.importError = error.localizedDescription
        }
        return item
    }
}

@MainActor
final class ConverterViewModel: ObservableObject {
    @Published private(set) var items: [QueueItem] = []
    @Published var selectedID: UUID?
    @Published private(set) var appDefaults: AppDefaults
    @Published var kind = OutputKind.photos
    @Published var albumName: String {
        didSet { preferences.set(albumName, forKey: "photosAlbumName") }
    }
    @Published private(set) var exportDirectory: URL?
    @Published private(set) var isImporting = false
    @Published private(set) var isBatchRunning = false
    @Published private(set) var cancelRequested = false
    @Published private(set) var activeID: UUID?
    @Published private(set) var progress = 0.0
    @Published private(set) var batchTotal = 0
    @Published private(set) var batchFinished = 0
    @Published private(set) var statusMessage = ""
    @Published private(set) var resultTarget: DeliveryTarget?
    private var importRequests: [[URL]] = []
    private let library: AlbumLibrary
    private let preferences: UserDefaults

    init(library: AlbumLibrary = SystemAlbumLibrary(), preferences: UserDefaults = .standard) {
        self.library = library
        self.preferences = preferences
        appDefaults = .load(from: preferences)
        albumName = preferences.string(forKey: "photosAlbumName") ?? "Video to Live Photo"
        if let data = preferences.data(forKey: "exportFolderBookmark") {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
                                  relativeTo: nil, bookmarkDataIsStale: &stale) {
                exportDirectory = url
                if stale { setExportFolder(url) }
            }
        }
        // Earlier versions could persist only a path if bookmark creation failed.
        if exportDirectory == nil, let path = preferences.string(forKey: "exportFolderPath"),
           FileManager.default.isWritableFile(atPath: path) {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
                exportDirectory = URL(fileURLWithPath: path, isDirectory: true)
            }
        }
    }

    var busy: Bool { isImporting || isBatchRunning }
    var selectedItem: QueueItem? { items.first { $0.id == selectedID } }
    var target: DeliveryTarget? {
        switch kind {
        case .photos:
            let name = albumName.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? nil : .album(name)
        case .folder: return exportDirectory.map { .folder($0.resolvingSymlinksInPath().standardizedFileURL) }
        }
    }

    func eligible(for target: DeliveryTarget?, failedOnly: Bool = false) -> [QueueItem] {
        items.filter { item in
            guard item.files != nil else { return false }
            guard let target else { return !failedOnly }
            return !item.delivered.contains(target) && (!failedOnly || item.failures[target] != nil)
        }
    }

    func loadURLs(_ urls: [URL]) async {
        guard !isBatchRunning else { return }
        importRequests.append(urls)
        guard !isImporting else { return }
        isImporting = true
        resultTarget = nil
        defer { isImporting = false }
        var added = 0, skipped = 0, failed = 0
        while !importRequests.isEmpty {
            let roots = importRequests.removeFirst()
            let scopes = roots.filter { $0.startAccessingSecurityScopedResource() }
            defer { scopes.forEach { $0.stopAccessingSecurityScopedResource() } }
            statusMessage = "Finding videos…"
            let videos = await Task.detached(priority: .userInitiated) {
                LivePhotoEngine.collectVideos(from: roots)
            }.value
            var known = Set(items.map { $0.source })
            for (index, video) in videos.enumerated() {
                let source = video.resolvingSymlinksInPath().standardizedFileURL
                guard known.insert(source).inserted else { skipped += 1; continue }
                statusMessage = "Importing \(index + 1) of \(videos.count) · \(source.lastPathComponent)"
                let item = await QueueItem.ingest(source)
                items.append(item)
                if selectedID == nil || (selectedItem?.files == nil && item.files != nil) { selectedID = item.id }
                if item.files == nil { failed += 1 } else { added += 1 }
            }
        }
        var summary = ["\(added) imported"]
        if skipped > 0 { summary.append("\(skipped) already queued") }
        if failed > 0 { summary.append("\(failed) unreadable") }
        statusMessage = added + skipped + failed == 0 ? "No MP4, MOV, or M4V files found." : summary.joined(separator: " · ")
    }

    func removeItem(_ id: UUID) {
        guard !busy, let index = items.firstIndex(where: { $0.id == id }) else { return }
        items.remove(at: index)
        if selectedID == id { selectedID = items.isEmpty ? nil : items[min(index, items.count - 1)].id }
        resetMessage()
    }

    func clear() {
        guard !busy else { return }
        items.removeAll()
        selectedID = nil
        resetMessage()
    }

    private func resetMessage() {
        resultTarget = nil
        statusMessage = ""
    }

    func updateAppDefaults(_ next: AppDefaults) {
        guard !busy, next != appDefaults else { return }
        for i in items.indices where items[i].override == nil {
            let old = items[i].segment(appDefaults), new = items[i].segment(next)
            if old.start != new.start || old.duration != new.duration { items[i].invalidateOutput() }
        }
        appDefaults = next
        next.save(to: preferences)
        resetMessage()
    }

    func updateTrim(_ settings: TrimSettings?) {
        guard !busy, let i = items.firstIndex(where: { $0.id == selectedID }),
              items[i].override != settings else { return }
        let old = items[i].segment(appDefaults)
        items[i].override = settings
        let new = items[i].segment(appDefaults)
        if old.start != new.start || old.duration != new.duration { items[i].invalidateOutput() }
        resetMessage()
    }

    func updateKeyframe(_ fraction: Double) {
        guard !busy, fraction.isFinite, let i = items.firstIndex(where: { $0.id == selectedID }) else { return }
        let value = min(max(fraction, 0), 1)
        guard abs(value - items[i].keyframePercent) > 0.000001 else { return }
        items[i].invalidateOutput()
        items[i].keyframePercent = value
        resetMessage()
    }

    func setExportFolder(_ url: URL) {
        guard !busy else { return }
        exportDirectory = url
        preferences.set(url.path, forKey: "exportFolderPath")
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            preferences.set(data, forKey: "exportFolderBookmark")
        } catch {
            preferences.removeObject(forKey: "exportFolderBookmark")
            statusMessage = "Choose this folder again the next time you open the app."
        }
    }

    func cancelBatch() { if isBatchRunning { cancelRequested = true } }

    func startDelivery(chooseFolder: () -> URL?) async {
        guard !busy else { return }
        if kind == .folder && exportDirectory == nil {
            guard let folder = chooseFolder() else { return }
            setExportFolder(folder)
        }
        await runBatch()
    }

    func runBatch(failedOnly: Bool = false) async {
        guard !busy, let target else { return }
        let jobs = eligible(for: target, failedOnly: failedOnly).map(\.id)
        guard !jobs.isEmpty else { return }
        isBatchRunning = true
        resultTarget = nil
        batchTotal = jobs.count
        batchFinished = 0
        cancelRequested = false
        var written = 0, failed = 0
        defer {
            isBatchRunning = false
            activeID = nil
            cancelRequested = false
        }
        let scope = kind == .folder ? exportDirectory : nil
        let accessing = scope?.startAccessingSecurityScopedResource() ?? false
        defer { if accessing { scope?.stopAccessingSecurityScopedResource() } }
        var albumID: String?
        if case .album(let name) = target {
            statusMessage = "Opening album “\(name)”…"
            do { albumID = try await library.resolve(name) }
            catch {
                for i in items.indices where jobs.contains(items[i].id) {
                    items[i].failures[target] = error.localizedDescription
                }
                statusMessage = error.localizedDescription
                return
            }
        }

        for id in jobs {
            guard !cancelRequested, let i = items.firstIndex(where: { $0.id == id }) else { break }
            activeID = id
            progress = 0
            let item = items[i]
            statusMessage = "\(batchFinished + 1) of \(batchTotal) · \(item.filename)"
            do {
                let pair: LivePhotoPair
                if let existing = item.pair { pair = existing }
                else {
                    guard let files = item.files else { throw LivePhotoEngineError.cannotCreateReader }
                    pair = try await LivePhotoEngine.convert(
                        videoURL: item.url, mode: item.override?.trimMode ?? appDefaults.trimMode,
                        custom: item.override?.customTrim ?? appDefaults.customTrim,
                        keyframePercent: item.keyframePercent, workingDirectory: files.directory
                    ) { [weak self] fraction in
                        Task { @MainActor in
                            guard let self, self.activeID == id else { return }
                            self.progress = max(self.progress, fraction * 0.9)
                        }
                    }
                    items[i].pair = pair
                }
                if let albumID {
                    let assetID: String
                    if let existing = items[i].photoAssetID { assetID = existing }
                    else {
                        assetID = try await library.create(pair)
                        items[i].photoAssetID = assetID
                    }
                    try await library.add(assetID, to: albumID)
                } else if case .folder(let folder) = target {
                    _ = try await Task.detached(priority: .userInitiated) {
                        try LivePhotoEngine.exportPair(pair, to: folder, sourceName: item.filename)
                    }.value
                }
                items[i].delivered.insert(target)
                items[i].failures[target] = nil
                written += 1
            } catch {
                if case .album = target, items[i].photoAssetID != nil {
                    items[i].failures[target] = "Saved to Library · Retry adding to album. " + error.localizedDescription
                } else { items[i].failures[target] = error.localizedDescription }
                failed += 1
            }
            progress = 0
            activeID = nil
            batchFinished += 1
        }
        let verb = kind == .photos ? "Saved" : "Exported"
        var summary = ["\(verb) \(written) to \(target.name)"]
        if failed > 0 { summary.append("\(failed) failed") }
        if batchFinished < jobs.count { summary.append("\(jobs.count - batchFinished) pending") }
        statusMessage = summary.joined(separator: " · ")
        if written > 0 { resultTarget = target }
    }
}
