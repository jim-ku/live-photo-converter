import SwiftUI
import AVKit
import CoreMedia
import UniformTypeIdentifiers
import AppKit
import Photos

enum QueueItemStatus: Equatable {
    case pending
    case converting
    case done
    case failed(String)

    var label: String {
        switch self {
        case .pending: return "Pending"
        case .converting: return "Converting"
        case .done: return "Done"
        case .failed: return "Failed"
        }
    }

    var detail: String? {
        if case .failed(let message) = self { return message }
        return nil
    }

    var tint: Color {
        switch self {
        case .pending: return .secondary
        case .converting: return .accentColor
        case .done: return .green
        case .failed: return .red
        }
    }
}

/// Per-clip trim override. `nil` on a queue item means inherit app defaults (badge Default).
struct TrimSettings: Equatable {
    var trimMode: TrimMode
    var customTrim: CustomTrimTemplate
}

struct QueueItem: Identifiable, Equatable {
    let id: UUID
    let url: URL
    var duration: TimeInterval
    var segment: LivePhotoSegment?
    /// Per-clip Custom trim (used when resolved mode is .custom).
    var customTrim: CustomTrimTemplate
    /// Per-clip key photo position within the selected segment (0…1).
    var keyframePercent: Double
    /// `nil` = Default badge (inherit app trim); set in slice 3 when user overrides.
    var override: TrimSettings?
    var status: QueueItemStatus
    var progress: Double
    var lastPair: LivePhotoPair?

    var filename: String { url.lastPathComponent }
    var usesOverride: Bool { override != nil }
    var trimBadgeLabel: String { usesOverride ? "Override" : "Default" }

    /// Effective trim mode: override wins, else app defaults.
    func resolvedTrimMode(appDefaults: AppDefaults) -> TrimMode {
        override?.trimMode ?? appDefaults.trimMode
    }

    /// Effective custom template: override wins, else app defaults.
    func resolvedCustomTrim(appDefaults: AppDefaults) -> CustomTrimTemplate {
        override?.customTrim ?? appDefaults.customTrim
    }
}

@MainActor
final class ConverterViewModel: ObservableObject {
    private static let albumNameKey = "photosAlbumName"
    private static let exportPathKey = "exportFolderPath"
    private static let exportBookmarkKey = "exportFolderBookmark"

    @Published var items: [QueueItem] = []
    @Published var selectedID: UUID?
    /// App-wide defaults (UserDefaults). Edits go through `updateAppDefaults`.
    @Published private(set) var appDefaults: AppDefaults = .load()
    /// Convenience mirror of `appDefaults.trimMode` for UI / convert.
    var trimMode: TrimMode { appDefaults.trimMode }
    @Published var player: AVPlayer?
    @Published var isBatchRunning = false
    @Published var statusMessage: String = ""
    /// Last folder written by Export (for Reveal in Finder).
    @Published var lastExportDirectory: URL?
    /// True after a successful Photos batch (for Open Photos).
    @Published var lastSavedToPhotos = false
    /// Set by Cancel; checked between queue items (in-flight item may finish).
    @Published private(set) var cancelRequested = false
    /// Last batch destination — used by Retry failed.
    private var lastBatchWasPhotos = true

    /// Photos album title — default “Live Photo Converter”; persisted in UserDefaults.
    @Published var albumName: String = UserDefaults.standard.string(forKey: ConverterViewModel.albumNameKey) ?? "Live Photo Converter" {
        didSet { UserDefaults.standard.set(albumName, forKey: Self.albumNameKey) }
    }

    /// Export folder chosen by the user; path shown in UI; bookmark persisted for sandbox re-access.
    @Published var exportDirectory: URL?
    @Published var exportFolderDisplay: String = "Not set — choose a folder"

    /// Dropped / picked roots we called startAccessingSecurityScopedResource on.
    private var scopedRoots: [URL] = []

    private static var ingestDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("LivePhotoConverterIngest", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    var selectedItem: QueueItem? {
        guard let selectedID else { return items.first }
        return items.first { $0.id == selectedID }
    }

    var doneCount: Int { items.filter { if case .done = $0.status { return true }; return false }.count }
    var failedCount: Int { items.filter { if case .failed = $0.status { return true }; return false }.count }
    var overallLabel: String {
        guard !items.isEmpty else { return "" }
        return "\(doneCount)/\(items.count)"
    }

    init() {
        restoreExportFolder()
        // appDefaults already loaded via property initializer
    }

    /// Defaults UI only — persist + recompute Default (override == nil) items.
    func updateAppDefaults(_ next: AppDefaults) {
        guard next != appDefaults else { return }
        appDefaults = next
        appDefaults.save()
        applyDefaultsToDefaultItems()
    }

    /// Recompute segments for items that inherit defaults; leave override payloads untouched.
    func applyDefaultsToDefaultItems() {
        for i in items.indices {
            guard items[i].override == nil else { continue }
            items[i].customTrim = appDefaults.customTrim
            let d = items[i].duration
            guard d > 0 else { continue }
            items[i].segment = LivePhotoEngine.plannedSegment(
                sourceDuration: d,
                mode: appDefaults.trimMode,
                custom: items[i].customTrim
            )
        }
        refreshPlayerForSelection()
    }

    func clear() {
        player?.pause()
        player = nil
        items = []
        selectedID = nil
        isBatchRunning = false
        statusMessage = ""
        lastExportDirectory = nil
        lastSavedToPhotos = false
        cancelRequested = false
        releaseScopedRoots()
        // Keep album name + export folder (user destinations)
    }

    private func retainScopedRoot(_ url: URL) {
        let ok = url.startAccessingSecurityScopedResource()
        DropLog.log("startAccessing \(url.path) -> \(ok)")
        if ok {
            scopedRoots.append(url)
        }
    }

    private func releaseScopedRoots() {
        DropLog.log("releaseScopedRoots count=\(scopedRoots.count)")
        for url in scopedRoots {
            url.stopAccessingSecurityScopedResource()
        }
        scopedRoots.removeAll()
    }

    /// Copy into the app sandbox cache so AVFoundation never touches a bare drop URL.
    private static func copyIntoIngestCache(_ url: URL) throws -> URL {
        DropLog.log("copyIntoIngestCache begin \(url.path)")
        let accessing = url.startAccessingSecurityScopedResource()
        DropLog.log("copy scoped access=\(accessing)")
        defer {
            if accessing { url.stopAccessingSecurityScopedResource() }
        }
        let dest = ingestDirectory.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: url, to: dest)
        let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? NSNumber)?.int64Value ?? -1
        DropLog.log("copyIntoIngestCache done dest=\(dest.path) bytes=\(size)")
        return dest
    }

    func recomputeSegments() {
        applyDefaultsToDefaultItems()
    }

    func select(_ id: UUID) {
        selectedID = id
        refreshPlayerForSelection()
    }

    private func refreshPlayerForSelection() {
        player?.pause()
        player = nil
        guard let item = selectedItem else {
            DropLog.log("refreshPlayer: no selection")
            return
        }
        DropLog.log("refreshPlayer begin file=\(item.filename) url=\(item.url.path) duration=\(item.duration)")
        let playerItem = AVPlayerItem(url: item.url)
        let av = AVPlayer(playerItem: playerItem)
        DropLog.log("refreshPlayer AVPlayer created (deferred UI attach)")
        // Detach from the ingest Task's immediate SwiftUI invalidation — VideoPlayer
        // was crashing after "after refreshPlayer" with no further breadcrumbs.
        DispatchQueue.main.async {
            DropLog.log("refreshPlayer async attach start itemStatus=\(playerItem.status.rawValue)")
            self.player = av
            DropLog.log("refreshPlayer player published to UI")
            DispatchQueue.main.async {
                DropLog.log("refreshPlayer async seek start")
                self.seekPlayerToKeyframe(for: item, in: av)
                DropLog.log("refreshPlayer seek done")
            }
        }
    }

    /// Seek preview to the key photo time inside the planned segment.
    func seekPlayerToKeyframe(for item: QueueItem, in av: AVPlayer? = nil) {
        guard let seg = item.segment else { return }
        let target = seg.start + seg.duration * item.keyframePercent
        guard target.isFinite, target >= 0 else { return }
        let time = CMTime(seconds: target, preferredTimescale: 600)
        guard time.isValid, !time.isIndefinite else { return }
        // Zero tolerance has crashed some Mac AVPlayer + SwiftUI VideoPlayer paths.
        let slop = CMTime(seconds: 0.05, preferredTimescale: 600)
        (av ?? player)?.seek(to: time, toleranceBefore: slop, toleranceAfter: slop)
    }

    func loadURLs(_ urls: [URL]) {
        DropLog.log("loadURLs begin count=\(urls.count) paths=\(urls.map(\.path))")
        statusMessage = "Ingesting… log: \(DropLog.logFileURL.path)"
        for root in urls {
            retainScopedRoot(root)
        }
        let videos = LivePhotoEngine.collectVideos(from: urls)
        DropLog.log("collectVideos -> \(videos.count) \(videos.map(\.lastPathComponent))")
        guard !videos.isEmpty else {
            statusMessage = "No MP4/MOV/M4V files found. Log: \(DropLog.logFileURL.path)"
            return
        }
        // Dedupe by original filename+size when possible; after ingest paths differ.
        let existingNames = Set(items.map { $0.filename.lowercased() })
        let fresh = videos.filter { !existingNames.contains($0.lastPathComponent.lowercased()) }
        guard !fresh.isEmpty else {
            statusMessage = "Those files are already in the queue."
            return
        }
        Task { @MainActor in
            DropLog.log("ingest Task started fresh=\(fresh.count)")
            var built: [QueueItem] = []
            for url in fresh {
                let defaultCustom = appDefaults.customTrim
                do {
                    DropLog.log("ingest item \(url.lastPathComponent)")
                    let local = try Self.copyIntoIngestCache(url)
                    DropLog.log("loadDuration begin \(local.path)")
                    let d = try await LivePhotoEngine.loadDuration(of: local)
                    DropLog.log("loadDuration -> \(d)")
                    guard d.isFinite, d >= 0 else {
                        throw LivePhotoEngineError.cannotCreateReader
                    }
                    let seg = LivePhotoEngine.plannedSegment(
                        sourceDuration: d,
                        mode: appDefaults.trimMode,
                        custom: defaultCustom
                    )
                    built.append(QueueItem(
                        id: UUID(),
                        url: local,
                        duration: d,
                        segment: seg,
                        customTrim: defaultCustom,
                        keyframePercent: 0.5,
                        override: nil,
                        status: .pending,
                        progress: 0,
                        lastPair: nil
                    ))
                    DropLog.log("queue item built ok \(url.lastPathComponent)")
                } catch {
                    DropLog.log("ingest failed \(url.lastPathComponent): \(error)")
                    built.append(QueueItem(
                        id: UUID(),
                        url: url,
                        duration: 0,
                        segment: nil,
                        customTrim: defaultCustom,
                        keyframePercent: 0.5,
                        override: nil,
                        status: .failed(error.localizedDescription),
                        progress: 0,
                        lastPair: nil
                    ))
                }
            }
            let wasEmpty = items.isEmpty
            items.append(contentsOf: built)
            if wasEmpty || selectedID == nil {
                selectedID = built.first(where: { $0.duration > 0 })?.id ?? built.first?.id
            }
            DropLog.log("before refreshPlayer selected=\(String(describing: selectedID))")
            refreshPlayerForSelection()
            DropLog.log("after refreshPlayer")
            let skipped = videos.count - fresh.count
            if skipped > 0 {
                statusMessage = "Added \(built.count); \(skipped) already queued — Reveal log if crash"
            } else {
                statusMessage = "Added \(built.count) video\(built.count == 1 ? "" : "s") (\(items.count) total) — Reveal log if crash"
            }
        }
    }

    func revealDropLog() {
        DropLog.revealInFinder()
        statusMessage = "Log: \(DropLog.pathHint)"
    }

    /// Per-clip trim mode edit → sets Override (does not touch AppDefaults).
    func updateSelectedTrimMode(_ mode: TrimMode) {
        guard let id = selectedID, let idx = items.firstIndex(where: { $0.id == id }) else { return }
        let custom = items[idx].override?.customTrim ?? items[idx].customTrim
        applyOverride(at: idx, TrimSettings(trimMode: mode, customTrim: custom))
    }

    /// Per-clip custom window edit → Override with Custom mode (Defaults page untouched).
    func updateCustom(start: TimeInterval, length: TimeInterval) {
        guard let id = selectedID, let idx = items.firstIndex(where: { $0.id == id }) else { return }
        let custom = CustomTrimTemplate(startOffset: start, windowLength: length)
        applyOverride(at: idx, TrimSettings(trimMode: .custom, customTrim: custom))
    }

    /// Clear override → Default badge; recompute from current AppDefaults.
    func resetOverride(for id: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].override = nil
        items[idx].customTrim = appDefaults.customTrim
        recomputeSegment(at: idx, mode: appDefaults.trimMode, custom: appDefaults.customTrim)
        seekPlayerToKeyframe(for: items[idx])
    }

    private func applyOverride(at idx: Int, _ settings: TrimSettings) {
        items[idx].override = settings
        items[idx].customTrim = settings.customTrim
        recomputeSegment(at: idx, mode: settings.trimMode, custom: settings.customTrim)
        seekPlayerToKeyframe(for: items[idx])
    }

    private func recomputeSegment(at idx: Int, mode: TrimMode, custom: CustomTrimTemplate) {
        let d = items[idx].duration
        guard d > 0 else {
            items[idx].segment = nil
            return
        }
        items[idx].segment = LivePhotoEngine.plannedSegment(
            sourceDuration: d,
            mode: mode,
            custom: custom
        )
    }

    func updateKeyframe(_ percent: Double) {
        guard let id = selectedID, let idx = items.firstIndex(where: { $0.id == id }) else { return }
        // Keyframe is always per-clip; does not flip Default/Override (trim-only badge).
        items[idx].keyframePercent = percent
        seekPlayerToKeyframe(for: items[idx])
    }

    func removeItem(_ id: UUID) {
        items.removeAll { $0.id == id }
        if selectedID == id {
            selectedID = items.first?.id
            refreshPlayerForSelection()
        }
    }

    func revealLastExport() {
        if let dir = lastExportDirectory ?? exportDirectory {
            NSWorkspace.shared.open(dir)
            return
        }
        statusMessage = "No export folder to reveal yet."
    }

    func openPhotosApp() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Photos") {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Photos.app"))
        }
    }

    // MARK: - Destinations

    func chooseExportFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Export folder for paired HEIC + MOV files"
        if let current = exportDirectory {
            panel.directoryURL = current
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setExportFolder(url)
    }

    func setExportFolder(_ url: URL) {
        exportDirectory = url
        exportFolderDisplay = url.path
        UserDefaults.standard.set(url.path, forKey: Self.exportPathKey)
        do {
            let data = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(data, forKey: Self.exportBookmarkKey)
        } catch {
            // Path still stored; bookmark may fail outside sandbox tests
        }
    }

    private func restoreExportFolder() {
        if let data = UserDefaults.standard.data(forKey: Self.exportBookmarkKey) {
            var stale = false
            do {
                let url = try URL(
                    resolvingBookmarkData: data,
                    options: [.withSecurityScope],
                    relativeTo: nil,
                    bookmarkDataIsStale: &stale
                )
                _ = url.startAccessingSecurityScopedResource()
                exportDirectory = url
                exportFolderDisplay = url.path
                if stale {
                    setExportFolder(url)
                }
                return
            } catch {
                // fall through to path
            }
        }
        if let path = UserDefaults.standard.string(forKey: Self.exportPathKey), !path.isEmpty {
            let url = URL(fileURLWithPath: path)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                exportDirectory = url
                exportFolderDisplay = path
            } else {
                exportFolderDisplay = "Not set — choose a folder"
            }
        }
    }

    func convertAllToPhotos() {
        let name = albumName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            statusMessage = "Enter a Photos album name."
            return
        }
        runBatch(saveToPhotos: true)
    }

    func exportAll() {
        guard let directory = exportDirectory else {
            statusMessage = "Choose an export folder first."
            chooseExportFolder()
            return
        }
        _ = directory.startAccessingSecurityScopedResource()
        runBatch(saveToPhotos: false)
    }

    /// Reset only `.failed` items (readable clips) to pending and re-run the last batch mode.
    func retryFailed() {
        guard !isBatchRunning else { return }
        var reset = 0
        for i in items.indices {
            if case .failed = items[i].status, items[i].duration > 0 {
                items[i].status = .pending
                items[i].progress = 0
                reset += 1
            }
        }
        guard reset > 0 else {
            statusMessage = "No failed items to retry."
            return
        }
        statusMessage = "Retrying \(reset) failed…"
        if lastBatchWasPhotos {
            convertAllToPhotos()
        } else {
            exportAll()
        }
    }

    /// Stop after the current item finishes. Remaining stay pending.
    func cancelBatch() {
        guard isBatchRunning else { return }
        cancelRequested = true
        statusMessage = "Canceling after current item…"
    }

    private func runBatch(saveToPhotos: Bool) {
        guard !items.isEmpty, !isBatchRunning else { return }

        if !saveToPhotos, exportDirectory == nil {
            statusMessage = "Choose an export folder first."
            return
        }

        isBatchRunning = true
        cancelRequested = false
        lastSavedToPhotos = false
        lastBatchWasPhotos = saveToPhotos
        let albumTitle = albumName.trimmingCharacters(in: .whitespacesAndNewlines)
        statusMessage = saveToPhotos
            ? "Converting & saving to album “\(albumTitle)”…"
            : "Exporting HEIC+MOV to \(exportFolderDisplay)…"

        Task {
            var album: PHAssetCollection?
            if saveToPhotos {
                do {
                    album = try await LivePhotoEngine.resolveOrCreateAlbum(titled: albumTitle)
                } catch {
                    isBatchRunning = false
                    cancelRequested = false
                    statusMessage = error.localizedDescription
                    for i in items.indices where items[i].status == .pending {
                        items[i].status = .failed(error.localizedDescription)
                    }
                    return
                }
            }

            var wasCanceled = false
            for i in items.indices {
                if cancelRequested {
                    wasCanceled = true
                    break
                }
                if case .done = items[i].status { continue }
                if case .failed = items[i].status { continue }

                items[i].status = .converting
                items[i].progress = 0
                selectedID = items[i].id
                refreshPlayerForSelection()

                do {
                    let mode = items[i].resolvedTrimMode(appDefaults: appDefaults)
                    let custom = items[i].resolvedCustomTrim(appDefaults: appDefaults)
                    let pair = try await LivePhotoEngine.convert(
                        videoURL: items[i].url,
                        mode: mode,
                        custom: custom,
                        keyframePercent: items[i].keyframePercent
                    ) { [weak self] p in
                        Task { @MainActor in
                            guard let self, i < self.items.count else { return }
                            self.items[i].progress = p
                        }
                    }
                    items[i].lastPair = pair
                    items[i].segment = pair.segment

                    if saveToPhotos, let album {
                        DropLog.log("batch saveToPhotos item=\(items[i].filename) album=\(album.localizedTitle ?? albumTitle)")
                        try await LivePhotoEngine.saveToPhotos(pair, album: album)
                        DropLog.log("batch saveToPhotos ok item=\(items[i].filename)")
                    } else if let exportDir = exportDirectory {
                        _ = try LivePhotoEngine.exportPair(pair, to: exportDir)
                        lastExportDirectory = exportDir
                    }

                    items[i].status = .done
                    items[i].progress = 1
                } catch {
                    items[i].status = .failed(error.localizedDescription)
                }

                statusMessage = "Progress \(doneCount + failedCount)/\(items.count)"
            }

            isBatchRunning = false
            let canceled = wasCanceled || cancelRequested
            cancelRequested = false
            let ok = doneCount
            let bad = failedCount
            if saveToPhotos, ok > 0 { lastSavedToPhotos = true }
            if canceled {
                let left = items.filter {
                    if case .pending = $0.status { return true }
                    return false
                }.count
                statusMessage = "Canceled: \(ok) done, \(bad) failed, \(left) left pending."
            } else if bad == 0 {
                statusMessage = saveToPhotos
                    ? "Saved \(ok) Live Photo\(ok == 1 ? "" : "s") to album “\(albumTitle)”."
                    : "Exported \(ok) HEIC+MOV pair\(ok == 1 ? "" : "s") to\n\(exportFolderDisplay)"
            } else {
                statusMessage = "Finished: \(ok) done, \(bad) failed."
            }
        }
    }
}

struct ContentView: View {

    @StateObject private var model = ConverterViewModel()
    @State private var isDropTargeted = false
    @State private var showingDefaults = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(spacing: 18) {
                    if model.items.isEmpty {
                        // Slice 2: big dashed drop CTA only when queue empty
                        dropZone
                        if !model.statusMessage.isEmpty {
                            statusBlock
                        }
                    } else {
                        // Queue stays first when populated (slice 1 layout)
                        queueList
                        thinAppendBar
                        Divider().padding(.vertical, 4)
                        trimSummary
                        if let item = model.selectedItem {
                            previewSection(for: item)
                            if item.duration > LivePhotoEngine.maxLiveDuration,
                               item.resolvedTrimMode(appDefaults: model.appDefaults) == .custom {
                                CustomTrimView(
                                    duration: item.duration,
                                    start: Binding(
                                        get: {
                                            (model.selectedItem ?? item)
                                                .resolvedCustomTrim(appDefaults: model.appDefaults).startOffset
                                        },
                                        set: { newStart in
                                            let cur = (model.selectedItem ?? item)
                                                .resolvedCustomTrim(appDefaults: model.appDefaults)
                                            model.updateCustom(start: newStart, length: cur.windowLength)
                                        }
                                    ),
                                    windowLength: Binding(
                                        get: {
                                            (model.selectedItem ?? item)
                                                .resolvedCustomTrim(appDefaults: model.appDefaults).windowLength
                                        },
                                        set: { newLen in
                                            let cur = (model.selectedItem ?? item)
                                                .resolvedCustomTrim(appDefaults: model.appDefaults)
                                            model.updateCustom(start: cur.startOffset, length: newLen)
                                        }
                                    )
                                )
                            }
                            keyframeScrubber(for: item)
                        }
                        destinationSettings
                        actions
                        statusBlock
                    }
                }
                .padding(24)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("Live Photo Converter")
        .onAppear {
            model.statusMessage = "Log: \(DropLog.pathHint)"
        }
        .sheet(isPresented: $showingDefaults) {
            DefaultsView(model: model)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "livephoto")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.pink)
            VStack(alignment: .leading, spacing: 2) {
                Text("Live Photo Converter")
                    .font(.headline)
                Text("MP4 → Live Photo (≤3s segment)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Defaults") { showingDefaults = true }
                .buttonStyle(.borderless)
                .help("App trim defaults (Start / Center / End / Custom)")
            Button("Reveal log") { model.revealDropLog() }
                .buttonStyle(.borderless)
                .help(DropLog.pathHint)
            if !model.items.isEmpty {
                if !model.overallLabel.isEmpty {
                    Text(model.overallLabel)
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                }
                Button("Clear") { model.clear() }
                    .buttonStyle(.borderless)
                    .disabled(model.isBatchRunning)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    /// Big dashed drop CTA — empty queue only (slice 2 tuck).
    private var dropZone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .foregroundStyle(isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.35))
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(isDropTargeted ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.03))
                )

            VStack(spacing: 12) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 34))
                    .foregroundStyle(Color.secondary)
                Text("Drop MP4s or a folder")
                    .font(.title3.weight(.semibold))
                Text("Live Photos use up to 3s. Clips shorter than 3s keep full length. Longer clips use Start / Center / End / Custom trim (Defaults). Batch supported.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
                HStack(spacing: 10) {
                    Button("Choose files…") { pickFiles() }
                        .buttonStyle(.borderedProminent)
                    Button("Choose folder…") { pickFolder() }
                        .buttonStyle(.bordered)
                }
                .padding(.top, 4)
            }
            .padding(28)
        }
        .frame(minHeight: 220)
        .onDrop(of: [UTType.fileURL, UTType.movie, UTType.mpeg4Movie, UTType.folder], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
    }

    /// Thin append affordance under queue — not a permanent block above queue.
    private var thinAppendBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus.circle")
                .foregroundStyle(.secondary)
            Text(isDropTargeted ? "Drop to append…" : "Drop more to append")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button("Add files…") { pickFiles() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(model.isBatchRunning)
            Button("Add folder…") { pickFolder() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(model.isBatchRunning)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                )
                .foregroundStyle(isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.3))
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isDropTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
                )
        )
        .onDrop(of: [UTType.fileURL, UTType.movie, UTType.mpeg4Movie, UTType.folder], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
    }

    /// App default caption + per-clip trim (Override) + Reset.
    private var trimSummary: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Trim")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("App default: \(model.appDefaults.trimMode.rawValue)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Defaults…") { showingDefaults = true }
                    .buttonStyle(.borderless)
                    .disabled(model.isBatchRunning)
            }

            if let item = model.selectedItem {
                HStack(alignment: .center, spacing: 10) {
                    Text("This clip")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Picker(
                        "Clip trim",
                        selection: Binding(
                            get: {
                                (model.selectedItem ?? item)
                                    .resolvedTrimMode(appDefaults: model.appDefaults)
                            },
                            set: { model.updateSelectedTrimMode($0) }
                        )
                    ) {
                        ForEach(TrimMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .disabled(model.isBatchRunning || item.duration <= 0)

                    if item.usesOverride {
                        Button("Reset") {
                            model.resetOverride(for: item.id)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(model.isBatchRunning)
                        .help("Clear override; use current app Defaults")
                    }
                }

                Text(item.usesOverride
                      ? "Override — Reset restores app Defaults for this clip only."
                      : "Default — editing mode or custom window sets Override. Clips ≤3s keep full length.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Select a clip to edit per-clip trim. App Defaults apply to Default-badge clips.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let seg = model.selectedItem?.segment {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: seg.isShortWarning ? "exclamationmark.triangle.fill" : "info.circle.fill")
                        .foregroundStyle(seg.isShortWarning ? Color.orange : Color.accentColor)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(seg.isShortWarning ? "Short clip warning" : "Selected segment")
                            .font(.subheadline.weight(.semibold))
                        Text(seg.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(seg.isShortWarning ? Color.orange.opacity(0.1) : Color.accentColor.opacity(0.08))
                )
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }

    @ViewBuilder
    private func previewSection(for item: QueueItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.filename)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            if let player = model.player {
                MacPlayerView(player: player)
                    .frame(height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08))
                    )
                    .id(item.id)
                    .onAppear { DropLog.log("MacPlayerView onAppear item=\(item.filename)") }
                    .onDisappear { DropLog.log("MacPlayerView onDisappear item=\(item.filename)") }
            } else {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.secondary.opacity(0.08))
                    .frame(height: 220)
                    .overlay(Text("Loading preview…").font(.caption).foregroundStyle(.secondary))
                    .onAppear { DropLog.log("preview placeholder (no player yet) item=\(item.filename)") }
            }
            if let seg = item.segment, seg.sourceDuration > 0 {
                SegmentTimelineOverlay(
                    sourceDuration: seg.sourceDuration,
                    segmentStart: seg.start,
                    segmentDuration: seg.duration,
                    keyframePercent: item.keyframePercent
                )
                Text("Blue = Live Photo window · white tick = key photo (preview seeks here)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func keyframeScrubber(for item: QueueItem) -> some View {
        let seg = item.segment
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Key photo")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text("This clip only")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: Binding(
                    get: { item.keyframePercent },
                    set: { model.updateKeyframe($0) }
                ),
                in: 0.05...0.95
            )
            .disabled(model.isBatchRunning)
            if let seg {
                Text(String(
                    format: "At %.1fs of source (%.0f%% of %.1fs segment)",
                    seg.start + seg.duration * item.keyframePercent,
                    item.keyframePercent * 100,
                    seg.duration
                ))
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }

    private var destinationSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Destinations")
                .font(.subheadline.weight(.semibold))

            VStack(alignment: .leading, spacing: 6) {
                Text("Photos album")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                TextField("Album name", text: $model.albumName)
                    .textFieldStyle(.roundedBorder)
                    .disabled(model.isBatchRunning)
                Text("Live Photos are saved into this album (created if missing). Previously, saves went to the library with no album.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Export folder")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                HStack(alignment: .top, spacing: 10) {
                    Text(model.exportFolderDisplay)
                        .font(.caption.monospaced())
                        .foregroundStyle(model.exportDirectory == nil ? Color.secondary : Color.primary)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.primary.opacity(0.05))
                        )
                    Button("Export folder…") {
                        model.chooseExportFolder()
                    }
                    .disabled(model.isBatchRunning)
                }
                Text("HEIC+MOV pairs are written flat into this folder with unique names. The last folder is remembered.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }

    private var queueList: some View {

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Queue")
                    .font(.subheadline.weight(.semibold))
                Text("Select a clip to edit trim below")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(model.overallLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ForEach(model.items) { item in
                let selected = model.selectedID == item.id
                HStack(alignment: .top, spacing: 8) {
                    Button {
                        model.select(item.id)
                    } label: {
                        HStack(spacing: 10) {
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(selected ? Color.accentColor : Color.clear)
                                .frame(width: 3)
                                .padding(.vertical, 2)
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Text(item.filename)
                                        .font(.callout.weight(.medium))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Text(item.trimBadgeLabel)
                                        .font(.caption2.weight(.semibold))
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 2)
                                        .background(
                                            Capsule().fill(
                                                item.usesOverride
                                                    ? Color.accentColor.opacity(0.9)
                                                    : Color.secondary.opacity(0.14)
                                            )
                                        )
                                        .foregroundStyle(item.usesOverride ? Color.white : Color.secondary)
                                }
                                Text(String(format: "%.1fs", item.duration) + " · " + (item.segment?.summary ?? "—"))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                if let detail = item.status.detail {
                                    Text(detail)
                                        .font(.caption2)
                                        .foregroundStyle(.red)
                                        .lineLimit(3)
                                        .textSelection(.enabled)
                                }
                                if item.status == .converting {
                                    ProgressView(value: item.progress)
                                        .progressViewStyle(.linear)
                                }
                            }
                            Spacer(minLength: 0)
                            Text(item.status.label)
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(item.status.tint.opacity(0.18)))
                                .foregroundStyle(item.status.tint)
                        }
                        .padding(.vertical, 10)
                        .padding(.trailing, 10)
                        .padding(.leading, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(selected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.03))
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isBatchRunning)

                    Button {
                        model.removeItem(item.id)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .disabled(model.isBatchRunning)
                    .help("Remove from queue")
                }
            }
        }
    }


    private var albumSaveCaption: String {
        let name = model.albumName.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = name.isEmpty ? "Live Photo Converter" : name
        return "Saves into album “\(label)”"
    }

    private var actions: some View {
        VStack(spacing: 10) {
            Button {
                model.convertAllToPhotos()
            } label: {
                HStack {
                    if model.isBatchRunning {
                        ProgressView().controlSize(.small)
                    }
                    Text(model.isBatchRunning
                          ? "Converting \(model.overallLabel)…"
                          : "Convert & Save to Photos")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.isBatchRunning || model.items.isEmpty)

            Text(albumSaveCaption)
                .font(.caption2)
                .foregroundStyle(.secondary)

            Button {
                model.exportAll()
            } label: {
                Text("Export pairs to folder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(model.isBatchRunning || model.items.isEmpty)

            Text(model.exportDirectory == nil
                  ? "Set an export folder above first"
                  : "Writes HEIC+MOV into the folder above")
                .font(.caption2)
                .foregroundStyle(.secondary)

            if model.isBatchRunning {
                Button("Cancel") { model.cancelBatch() }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .disabled(model.cancelRequested)
                    .frame(maxWidth: .infinity)
                Text(model.cancelRequested
                      ? "Will stop after the current item"
                      : "Stops between items; in-flight may finish")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if model.failedCount > 0 {
                Button("Retry failed") { model.retryFailed() }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                Text("Re-runs only Failed rows (skips Done)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var statusBlock: some View {
        if !model.statusMessage.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(.secondary)
                    Text(model.statusMessage)
                        .font(.callout)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                }
                if !model.isBatchRunning {
                    HStack(spacing: 10) {
                        if model.lastSavedToPhotos {
                            Button("Open Photos") { model.openPhotosApp() }
                                .buttonStyle(.bordered)
                        }
                        if model.lastExportDirectory != nil || (model.exportDirectory != nil && model.doneCount > 0) {
                            Button("Reveal in Finder") { model.revealLastExport() }
                                .buttonStyle(.bordered)
                        }
                    }
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.secondary.opacity(0.1))
            )
        }
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.mpeg4Movie, .movie, .quickTimeMovie]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK {
            model.loadURLs(panel.urls)
        }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            model.loadURLs([url])
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        DropLog.log("handleDrop providers=\(providers.count)")
        let group = DispatchGroup()
        var urls: [URL] = []
        let lock = NSLock()

        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                defer { group.leave() }
                if let error {
                    DropLog.log("loadItem error: \(error)")
                }
                var url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                    DropLog.log("loadItem Data -> \(url?.path ?? "nil")")
                } else if let u = item as? URL {
                    url = u
                    DropLog.log("loadItem URL -> \(u.path)")
                } else {
                    DropLog.log("loadItem unexpected type=\(String(describing: type(of: item)))")
                }
                if let url {
                    lock.lock()
                    urls.append(url)
                    lock.unlock()
                }
            }
        }

        group.notify(queue: .main) {
            DropLog.log("handleDrop resolved urls=\(urls.count)")
            model.loadURLs(urls)
        }
        return true
    }
}

// MARK: - Segment + keyframe overlay (source timeline)

/// AVPlayerView is more stable than SwiftUI VideoPlayer for local sandbox files on Mac.
struct MacPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        DropLog.log("MacPlayerView.makeNSView")
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.player = player
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player {
            DropLog.log("MacPlayerView.updateNSView swap player")
            nsView.player = player
        }
    }

    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: Void) {
        DropLog.log("MacPlayerView.dismantleNSView")
        nsView.player = nil
    }
}

struct SegmentTimelineOverlay: View {
    let sourceDuration: TimeInterval
    let segmentStart: TimeInterval
    let segmentDuration: TimeInterval
    let keyframePercent: Double

    var body: some View {
        GeometryReader { geo in
            let w = max(geo.size.width, 1)
            let h: CGFloat = 14
            let startX = CGFloat(segmentStart / max(sourceDuration, 0.001)) * w
            let width = max(CGFloat(segmentDuration / max(sourceDuration, 0.001)) * w, 4)
            let keyT = segmentStart + segmentDuration * keyframePercent
            let keyX = CGFloat(keyT / max(sourceDuration, 0.001)) * w

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.2))
                    .frame(width: w, height: h)
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.accentColor.opacity(0.55))
                    .frame(width: width, height: h)
                    .offset(x: startX)
                Rectangle()
                    .fill(Color.white)
                    .frame(width: 2, height: h + 4)
                    .offset(x: keyX - 1)
                    .shadow(radius: 1)
            }
            .frame(width: w, height: h + 4)
        }
        .frame(height: 18)
    }
}

// MARK: - Custom trimmer (sliding ≤3s window)

struct CustomTrimView: View {
    let duration: TimeInterval
    @Binding var start: TimeInterval
    @Binding var windowLength: TimeInterval

    private var maxWindow: TimeInterval {
        min(LivePhotoEngine.maxLiveDuration, max(duration, LivePhotoEngine.minCustomWindow))
    }

    private var clampedLength: TimeInterval {
        min(max(windowLength, LivePhotoEngine.minCustomWindow), maxWindow)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Custom trim")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(String(format: "%.1fs – %.1fs  (%0.1fs)", start, start + clampedLength, clampedLength))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            // Slice 4: one filmstrip control only — L/R handles = length, mid drag = position
            GeometryReader { geo in
                let w = geo.size.width
                let trackH: CGFloat = 28
                TimelineTrimBar(
                    duration: duration,
                    start: start,
                    length: clampedLength,
                    width: w,
                    height: trackH
                ) { newStart, newLength in
                    let len = min(max(newLength, LivePhotoEngine.minCustomWindow), maxWindow)
                    let st = min(max(newStart, 0), max(0, duration - len))
                    start = st
                    windowLength = len
                }
            }
            .frame(height: 36)

            Text("Drag the blue window to move; pull the L/R handles to set length. Max 3s.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .onAppear {
            let len = min(max(windowLength, LivePhotoEngine.minCustomWindow), maxWindow)
            windowLength = len
            start = min(max(start, 0), max(0, duration - len))
        }
    }
}

struct TimelineTrimBar: View {
    let duration: TimeInterval
    let start: TimeInterval
    let length: TimeInterval
    let width: CGFloat
    let height: CGFloat
    let onChange: (TimeInterval, TimeInterval) -> Void

    @State private var dragMode: DragMode = .none
    @State private var dragOriginStart: TimeInterval = 0
    @State private var dragOriginLength: TimeInterval = 0

    private enum DragMode { case none, move, startHandle, endHandle }

    private var end: TimeInterval { start + length }

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.2))
                .frame(width: width, height: height)

            // Selection
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.accentColor.opacity(0.45))
                .frame(width: max(x(end) - x(start), 8), height: height)
                .offset(x: x(start))
                .overlay(alignment: .leading) {
                    handle.offset(x: x(start) - 6)
                }
                .overlay(alignment: .leading) {
                    handle.offset(x: x(end) - 6)
                }

            // Invisible gesture layer
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if dragMode == .none {
                                beginDrag(at: value.startLocation.x)
                            }
                            applyDrag(translation: value.translation.width)
                        }
                        .onEnded { _ in
                            dragMode = .none
                        }
                )
        }
        .frame(width: width, height: height)
    }

    // Art Soft: visible grip; hit testing uses ≥20pt in beginDrag
    private var handle: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(Color.white)
            .frame(width: 12, height: height - 2)
            .shadow(radius: 1)
    }

    /// Minimum handle hit width in points (Art Soft slice-4 add-on).
    private var handleHitPts: CGFloat { 20 }

    private func x(_ t: TimeInterval) -> CGFloat {
        guard duration > 0, width > 0 else { return 0 }
        return CGFloat(t / duration) * width
    }

    private func time(for px: CGFloat) -> TimeInterval {
        guard width > 0 else { return 0 }
        return Double(px / width) * duration
    }

    private func beginDrag(at px: CGFloat) -> Void {
        let t = time(for: px)
        // ≥20pt hit targets for L/R handles (Art Soft)
        let startPx = x(start)
        let endPx = x(end)
        if abs(px - startPx) <= handleHitPts / 2 {
            dragMode = .startHandle
        } else if abs(px - endPx) <= handleHitPts / 2 {
            dragMode = .endHandle
        } else if t >= start && t <= end {
            dragMode = .move
        } else {
            dragMode = .move
            // Jump window so click becomes new start (clamped)
            let maxWin = min(LivePhotoEngine.maxLiveDuration, duration)
            let len = min(max(length, LivePhotoEngine.minCustomWindow), maxWin)
            let st = min(max(t - len / 2, 0), max(0, duration - len))
            onChange(st, len)
            dragOriginStart = st
            dragOriginLength = len
            return
        }
        dragOriginStart = start
        dragOriginLength = length
    }

    private func applyDrag(translation: CGFloat) {
        let dt = time(for: translation)
        let maxWin = min(LivePhotoEngine.maxLiveDuration, duration)
        switch dragMode {
        case .move:
            let len = min(max(dragOriginLength, LivePhotoEngine.minCustomWindow), maxWin)
            let st = min(max(dragOriginStart + dt, 0), max(0, duration - len))
            onChange(st, len)
        case .startHandle:
            var newStart = dragOriginStart + dt
            var newEnd = dragOriginStart + dragOriginLength
            newStart = min(max(newStart, 0), newEnd - LivePhotoEngine.minCustomWindow)
            if newEnd - newStart > maxWin {
                newStart = newEnd - maxWin
            }
            onChange(newStart, newEnd - newStart)
        case .endHandle:
            var newStart = dragOriginStart
            var newEnd = dragOriginStart + dragOriginLength + dt
            newEnd = max(min(newEnd, duration), newStart + LivePhotoEngine.minCustomWindow)
            if newEnd - newStart > maxWin {
                newEnd = newStart + maxWin
            }
            onChange(newStart, newEnd - newStart)
        case .none:
            break
        }
    }
}

// MARK: - Defaults (slice 2)

struct DefaultsView: View {
    @ObservedObject var model: ConverterViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Defaults")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)

            Divider()

            Form {
                Section {
                    Picker("Trim mode", selection: trimModeBinding) {
                        ForEach(TrimMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(model.isBatchRunning)

                    Text("Applies to new drops and existing Default-badge clips. Override clips stay untouched.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Trim mode (clips longer than 3s)")
                }

                if model.appDefaults.trimMode == .custom {
                    Section {
                        HStack {
                            Text("Start offset")
                            Spacer()
                            TextField(
                                "sec",
                                value: customStartBinding,
                                format: .number.precision(.fractionLength(1))
                            )
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 72)
                            Text("s")
                                .foregroundStyle(.secondary)
                        }
                        HStack {
                            Text("Window length")
                            Spacer()
                            TextField(
                                "sec",
                                value: customLengthBinding,
                                format: .number.precision(.fractionLength(1))
                            )
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 72)
                            Text("s")
                                .foregroundStyle(.secondary)
                        }
                        Text("Template for Custom mode (0.5…3s). Clamped per clip on ingest / recompute.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } header: {
                        Text("Custom template")
                    }
                }
            }
            .formStyle(.grouped)
            .padding(.bottom, 12)
        }
        .frame(minWidth: 420, minHeight: 320)
    }

    private var trimModeBinding: Binding<TrimMode> {
        Binding(
            get: { model.appDefaults.trimMode },
            set: { mode in
                var next = model.appDefaults
                next.trimMode = mode
                model.updateAppDefaults(next)
            }
        )
    }

    private var customStartBinding: Binding<Double> {
        Binding(
            get: { model.appDefaults.customTrim.startOffset },
            set: { start in
                var next = model.appDefaults
                next.customTrim.startOffset = max(0, start)
                model.updateAppDefaults(next)
            }
        )
    }

    private var customLengthBinding: Binding<Double> {
        Binding(
            get: { model.appDefaults.customTrim.windowLength },
            set: { length in
                var next = model.appDefaults
                next.customTrim.windowLength = min(
                    max(length, LivePhotoEngine.minCustomWindow),
                    LivePhotoEngine.maxLiveDuration
                )
                model.updateAppDefaults(next)
            }
        )
    }
}

#Preview {
    ContentView()
        .frame(width: 580, height: 820)
}
