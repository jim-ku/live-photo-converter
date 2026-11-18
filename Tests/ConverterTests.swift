import AppKit
import AVFoundation
import ImageIO
import Photos
import SwiftUI
import XCTest
@testable import LivePhotoConverter

private final class TestAlbums: AlbumLibrary {
    var assetCount = 0
    var addAttempts = 0
    var members: [String: Set<String>] = [:]
    var denyAccess = false
    var failNextAdd = false
    var afterAdd: (() async -> Void)?

    func resolve(_ name: String) async throws -> String {
        if denyAccess { throw LivePhotoEngineError.photosDenied }
        return name
    }
    func create(_ pair: LivePhotoPair) async throws -> String {
        assetCount += 1
        return pair.assetIdentifier
    }
    func add(_ assetID: String, to albumID: String) async throws {
        addAttempts += 1
        if failNextAdd {
            failNextAdd = false
            throw LivePhotoEngineError.albumAddFailed
        }
        members[albumID, default: []].insert(assetID)
        await afterAdd?()
    }
}

final class ConverterTests: XCTestCase {
    private var directory: URL!
    private var preferences: UserDefaults!
    private var suite: String!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        suite = UUID().uuidString
        preferences = UserDefaults(suiteName: suite)
    }

    override func tearDownWithError() throws {
        preferences.removePersistentDomain(forName: suite)
        try FileManager.default.removeItem(at: directory)
    }

    func testTrimPlanning() {
        let cases: [(Double, TrimMode, Double, Double)] = [(1, .end3s, 0, 1), (3, .custom, 0, 3),
            (8, .start3s, 0, 3), (8, .center3s, 2.5, 3), (8, .end3s, 5, 3), (8, .custom, 7.5, 0.5)]
        for (duration, mode, start, length) in cases {
            let plan = LivePhotoEngine.plannedSegment(sourceDuration: duration, mode: mode,
                                                      custom: .init(startOffset: 100, windowLength: 0.1))
            XCTAssertEqual(plan.start, start)
            XCTAssertEqual(plan.duration, length)
        }
    }

    func testLandscapeAndPortraitPlayback() async throws {
        for rotated in [false, true] {
            let folder = directory.appendingPathComponent(rotated ? "portrait" : "landscape")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            let url = try await MediaFixture.make(in: folder, portrait: rotated, audio: rotated)
            let pair = try await LivePhotoEngine.convert(videoURL: url, mode: .center3s, keyframePercent: 0.25,
                                                         workingDirectory: folder) { _ in }
            let movie = AVURLAsset(url: pair.movURL)
            let tracks = try await movie.loadTracks(withMediaType: .video)
            let track = try XCTUnwrap(tracks.first)
            let size = try await track.load(.naturalSize), transform = try await track.load(.preferredTransform)
            let display = size.applying(transform)
            let width = rotated ? 96 : 160, height = rotated ? 160 : 96
            XCTAssertEqual(abs(display.width), CGFloat(width))
            XCTAssertEqual(abs(display.height), CGFloat(height))
            let duration = try await movie.load(.duration)
            XCTAssertEqual(duration.seconds, rotated ? 2 : 3, accuracy: 0.09)
            let sound = try await movie.loadTracks(withMediaType: .audio)
            XCTAssertEqual(sound.count, rotated ? 1 : 0)
            let still = try XCTUnwrap(CGImageSourceCreateWithURL(pair.heicURL as CFURL, nil))
            let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(still, 0, nil) as? [CFString: Any])
            XCTAssertEqual(props[kCGImagePropertyPixelWidth] as? Int, width)
            XCTAssertEqual(props[kCGImagePropertyPixelHeight] as? Int, height)
            XCTAssertEqual((props[kCGImagePropertyMakerAppleDictionary] as? [String: Any])?["17"] as? String, pair.assetIdentifier)

            let metadata = try await movie.loadTracks(withMediaType: .metadata)
            let reader = try AVAssetReader(asset: movie)
            let output = AVAssetReaderTrackOutput(track: try XCTUnwrap(metadata.first), outputSettings: nil)
            let adaptor = AVAssetReaderOutputMetadataAdaptor(assetReaderTrackOutput: output)
            reader.add(output)
            XCTAssertTrue(reader.startReading())
            let group = try XCTUnwrap(adaptor.nextTimedMetadataGroup())
            XCTAssertEqual(group.timeRange.start.seconds, pair.segment.duration * 0.25, accuracy: 0.01)
            XCTAssertEqual(group.items.first?.key as? String, "com.apple.quicktime.still-image-time")

            let ready = expectation(description: "PhotoKit loads the complete Live Photo")
            PHLivePhoto.request(withResourceFileURLs: [pair.heicURL, pair.movURL], placeholderImage: nil,
                                targetSize: .zero, contentMode: .aspectFit) { photo, info in
                guard info[PHLivePhotoInfoIsDegradedKey] as? Bool != true else { return }
                XCTAssertNotNil(photo, String(describing: info[PHLivePhotoInfoErrorKey]))
                ready.fulfill()
            }
            await fulfillment(of: [ready], timeout: 20)
        }
    }

    @MainActor func testDestinationSwitchRetryAndEdits() async throws {
        let source = try await MediaFixture.make(in: directory)
        let library = TestAlbums()
        let model = ConverterViewModel(library: library, preferences: preferences)
        await model.loadURLs([source])
        model.kind = .folder
        let out = directory.appendingPathComponent("Exports")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: false)
        await model.startDelivery { nil }
        XCTAssertNil(model.selectedItem?.pair)
        await model.startDelivery { out }
        XCTAssertEqual(model.exportDirectory, out)
        let restored = ConverterViewModel(preferences: preferences)
        XCTAssertEqual(restored.exportDirectory?.resolvingSymlinksInPath().path, out.resolvingSymlinksInPath().path)
        let original = try XCTUnwrap(model.selectedItem?.pair)
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.appendingPathComponent("Camera.HEIC").path))
        XCTAssertEqual(model.eligible(for: model.target).count, 0)

        model.kind = .photos
        library.failNextAdd = true
        await model.runBatch()
        let target = try XCTUnwrap(model.target)
        let first = try XCTUnwrap(model.selectedItem)
        XCTAssertEqual(first.pair, original)
        XCTAssertNotNil(first.photoAssetID)
        XCTAssertTrue(first.failures[target]?.contains("Saved to Library") == true)
        XCTAssertNil(model.resultTarget)
        await model.runBatch(failedOnly: true)
        XCTAssertEqual(library.assetCount, 1)
        XCTAssertEqual(library.addAttempts, 2)
        XCTAssertEqual(library.members[model.albumName]?.count, 1)
        XCTAssertEqual(model.resultTarget, target)
        await model.runBatch()
        XCTAssertEqual(library.addAttempts, 2)

        model.albumName = "Another album"
        await model.runBatch()
        XCTAssertEqual(library.members[model.albumName]?.count, 1)
        XCTAssertEqual(library.assetCount, 1)
        model.updateKeyframe(0.25)
        XCTAssertNil(model.selectedItem?.pair)
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.heicURL.path))
        await model.runBatch()
        XCTAssertEqual(library.assetCount, 2)
        model.kind = .folder
        await model.runBatch()
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.appendingPathComponent("Camera (2).MOV").path))
        model.updateTrim(.init(trimMode: .start3s, customTrim: .default))
        XCTAssertTrue(model.selectedItem?.delivered.isEmpty == true)
    }

    @MainActor func testImportsAndCleanup() async throws {
        let source = try await MediaFixture.make(in: directory)
        let nested = directory.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        let other = nested.appendingPathComponent(source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: other)
        let broken = nested.appendingPathComponent("broken.mp4")
        try Data().write(to: broken)
        let model = ConverterViewModel(preferences: preferences)
        await model.loadURLs([directory, source])
        await model.loadURLs([source])
        XCTAssertEqual(model.items.count, 3)
        XCTAssertEqual(model.items.filter { $0.filename == "Camera.mov" }.count, 2)
        XCTAssertEqual(model.items.filter { $0.importError != nil }.count, 1)
        let working = model.items.compactMap { $0.files?.directory }
        model.removeItem(try XCTUnwrap(model.selectedID))
        model.clear()
        XCTAssertTrue(working.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
    }

    @MainActor func testDeniedPermissionStopAndRetrySubset() async throws {
        let source = try await MediaFixture.make(in: directory)
        let second = directory.appendingPathComponent("second.mov")
        try FileManager.default.copyItem(at: source, to: second)
        let library = TestAlbums()
        let model = ConverterViewModel(library: library, preferences: preferences)
        await model.loadURLs([source])
        library.denyAccess = true
        await model.runBatch()
        XCTAssertEqual(library.assetCount, 0)
        await model.loadURLs([second])
        library.denyAccess = false
        await model.runBatch(failedOnly: true)
        XCTAssertEqual(model.batchTotal, 1)
        XCTAssertEqual(library.assetCount, 1)
        XCTAssertTrue(model.statusMessage.contains("Saved 1"))
        model.albumName = "Cancel test"
        library.afterAdd = { model.cancelBatch() }
        await model.runBatch()
        XCTAssertTrue(model.statusMessage.contains("1 pending"))
        XCTAssertEqual(model.eligible(for: model.target).count, 1)
        library.afterAdd = nil
        await model.runBatch()
        XCTAssertEqual(library.members["Cancel test"]?.count, 2)
    }

    @MainActor func testOpeningCustomEditorInheritsDefaultsAndPlayerBounds() async throws {
        let source = try await MediaFixture.make(in: directory)
        let model = ConverterViewModel(preferences: preferences)
        model.updateAppDefaults(.init(trimMode: .custom, customTrim: .init(startOffset: 100, windowLength: 1)))
        await model.loadURLs([source])
        let item = try XCTUnwrap(model.selectedItem)
        let segment = item.segment(model.appDefaults)
        XCTAssertEqual(segment.end, item.duration, accuracy: 0.01)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 620, height: 680),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: ClipEditor(item: item, model: model))
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertNil(model.selectedItem?.override)
        window.contentView = nil
        let player = SegmentPlayer()
        player.open(item.url)
        player.configure(segment, cover: segment.start + 0.5)
        XCTAssertEqual(player.position, segment.start + 0.5)
        XCTAssertEqual(player.player.currentItem?.forwardPlaybackEndTime.seconds, segment.end)
        XCTAssertEqual(player.player.currentItem?.reversePlaybackEndTime.seconds, segment.start)
        player.toggle(segment)
        try await Task.sleep(nanoseconds: 1_600_000_000)
        XCTAssertEqual(player.player.currentTime().seconds, segment.end, accuracy: 0.09)
        XCTAssertEqual(player.player.rate, 0)
        XCTAssertFalse(player.playing)
        player.close()
        model.updateTrim(.init(trimMode: .end3s, customTrim: .default))
        model.updateTrim(nil)
        XCTAssertNil(model.selectedItem?.override)
    }

    func testCoverAtSelectionEdges() async throws {
        let source = try await MediaFixture.make(in: directory)
        for fraction in [0.0, 1.0] {
            let pair = try await LivePhotoEngine.convert(videoURL: source, mode: .end3s, keyframePercent: fraction,
                                                         workingDirectory: directory) { _ in }
            let asset = AVURLAsset(url: pair.movURL)
            let tracks = try await asset.loadTracks(withMediaType: .metadata)
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: try XCTUnwrap(tracks.first), outputSettings: nil)
            let adaptor = AVAssetReaderOutputMetadataAdaptor(assetReaderTrackOutput: output)
            reader.add(output)
            XCTAssertTrue(reader.startReading())
            let group = try XCTUnwrap(adaptor.nextTimedMetadataGroup())
            XCTAssertGreaterThanOrEqual(group.timeRange.start.seconds, 0)
            XCTAssertLessThan(group.timeRange.start.seconds, 3)
            XCTAssertEqual(group.timeRange.start.seconds, fraction * 3, accuracy: 0.09)
        }
    }

    func testConcurrentExportsShareBasenamesWithoutOverwriting() async throws {
        let sample = directory.appendingPathComponent("input")
        try Data("content".utf8).write(to: sample)
        let destination = try XCTUnwrap(directory)
        let pair = LivePhotoPair(heicURL: sample, movURL: sample, assetIdentifier: UUID().uuidString,
                                 segment: LivePhotoEngine.plannedSegment(sourceDuration: 1, mode: .start3s))
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<6 {
                group.addTask {
                    _ = try LivePhotoEngine.exportPair(pair, to: destination, sourceName: "Video.mp4")
                }
            }
            try await group.waitForAll()
        }
        let outputs = try FileManager.default.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil)
        let stills = outputs.filter { $0.pathExtension == "HEIC" }.map { $0.deletingPathExtension() }
        let movies = outputs.filter { $0.pathExtension == "MOV" }.map { $0.deletingPathExtension() }
        XCTAssertEqual(stills.count, 6)
        XCTAssertEqual(Set(stills), Set(movies))
    }

    func testFailedExportPreservesExistingFiles() throws {
        let out = directory.appendingPathComponent("Out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: false)
        let sentinel = out.appendingPathComponent("Camera.MOV")
        let data = Data("existing".utf8)
        try data.write(to: sentinel)
        let still = directory.appendingPathComponent("input.HEIC")
        try data.write(to: still)
        let pair = LivePhotoPair(heicURL: still, movURL: directory.appendingPathComponent("missing.mov"),
                                 assetIdentifier: UUID().uuidString,
                                 segment: LivePhotoEngine.plannedSegment(sourceDuration: 2, mode: .center3s))
        XCTAssertThrowsError(try LivePhotoEngine.exportPair(pair, to: out, sourceName: "Camera.mp4"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out.path), ["Camera.MOV"])
        XCTAssertEqual(try Data(contentsOf: sentinel), data)
    }
}
