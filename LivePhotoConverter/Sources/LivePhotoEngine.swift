import Foundation
import AVFoundation
import ImageIO
import CoreGraphics
import Photos
import UniformTypeIdentifiers

enum LivePhotoEngineError: LocalizedError {
    case noVideoTrack
    case cannotCreateWriter
    case cannotCreateReader
    case cannotExtractKeyframe
    case cannotWriteHEIC
    case exportFailed(String)
    case photosDenied
    case photosSaveFailed(String)
    case albumCreateFailed
    case exportFolderMissing

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: return "No video track found in the file."
        case .cannotCreateWriter: return "Could not create the Live Photo video writer."
        case .cannotCreateReader: return "Could not read the source video."
        case .cannotExtractKeyframe: return "Could not extract a keyframe for the still image."
        case .cannotWriteHEIC: return "Could not write the Live Photo HEIC still image."
        case .exportFailed(let m): return m
        case .photosDenied: return "Photos access was denied. Enable it in System Settings → Privacy & Security → Photos."
        case .photosSaveFailed(let m): return m
        case .albumCreateFailed: return "Could not create or find the Photos album."
        case .exportFolderMissing: return "Choose an export folder before exporting pairs."
        }
    }
}

enum TrimMode: String, CaseIterable, Identifiable, Codable {
    case start3s = "Start 3s"
    case center3s = "Center 3s"
    case end3s = "End 3s"
    case custom = "Custom"

    var id: String { rawValue }
}

/// Template for Custom mode, applied per clip (clamped to each duration).
struct CustomTrimTemplate: Equatable {
    /// Preferred window start offset from clip start (seconds).
    var startOffset: TimeInterval
    /// Preferred window length (0.5…3s).
    var windowLength: TimeInterval

    static let `default` = CustomTrimTemplate(startOffset: 0, windowLength: 3.0)
}

struct LivePhotoPair: Equatable {
    let heicURL: URL
    let movURL: URL
    let assetIdentifier: String
    let segment: LivePhotoSegment
}

struct LivePhotoSegment: Equatable {
    let start: TimeInterval
    let duration: TimeInterval
    let sourceDuration: TimeInterval
    let mode: TrimMode
    let isShortWarning: Bool

    var end: TimeInterval { start + duration }

    var summary: String {
        if sourceDuration <= LivePhotoEngine.maxLiveDuration + 0.001 {
            if isShortWarning {
                return String(
                    format: "Using full clip (%.1fs) — under %.1fs; Photos may not treat it as ideal Live Photo length",
                    sourceDuration,
                    LivePhotoEngine.minLiveDuration
                )
            }
            return String(format: "Using full clip (%.1fs)", sourceDuration)
        }
        switch mode {
        case .start3s:
            return String(format: "Start 3s: %.1fs–%.1fs of %.1fs", start, end, sourceDuration)
        case .center3s:
            return String(format: "Center 3s: %.1fs–%.1fs of %.1fs", start, end, sourceDuration)
        case .end3s:
            return String(format: "End 3s: %.1fs–%.1fs of %.1fs", start, end, sourceDuration)
        case .custom:
            return String(format: "Custom: %.1fs–%.1fs (%.1fs of %.1fs)", start, end, duration, sourceDuration)
        }
    }
}

final class LivePhotoEngine {
    static let minLiveDuration: TimeInterval = 1.5
    static let maxLiveDuration: TimeInterval = 3.0
    static let minCustomWindow: TimeInterval = 0.5

    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]

    /// Plan the segment for a clip under the current trim mode.
    /// - Duration ≤ 3s: always full original length (no pad/loop).
    /// - Duration > 3s: Start / Center / End / Custom window (≤3s).
    static func plannedSegment(
        sourceDuration: TimeInterval,
        mode: TrimMode,
        custom: CustomTrimTemplate = .default
    ) -> LivePhotoSegment {
        let dur = max(sourceDuration, 0)
        let shortWarn = dur > 0 && dur < minLiveDuration

        if dur <= maxLiveDuration {
            return LivePhotoSegment(
                start: 0,
                duration: dur,
                sourceDuration: dur,
                mode: mode,
                isShortWarning: shortWarn
            )
        }

        let window = maxLiveDuration
        let start: TimeInterval
        let length: TimeInterval

        switch mode {
        case .start3s:
            start = 0
            length = window
        case .center3s:
            start = max(0, (dur - window) / 2)
            length = window
        case .end3s:
            start = max(0, dur - window)
            length = window
        case .custom:
            let maxWin = min(maxLiveDuration, dur)
            length = min(max(custom.windowLength, minCustomWindow), maxWin)
            let maxStart = max(0, dur - length)
            start = min(max(custom.startOffset, 0), maxStart)
        }

        return LivePhotoSegment(
            start: start,
            duration: length,
            sourceDuration: dur,
            mode: mode,
            isShortWarning: false
        )
    }

    static func isSupportedVideo(_ url: URL) -> Bool {
        videoExtensions.contains(url.pathExtension.lowercased())
    }

    /// Collect MP4/MOV/M4V from files and folders (non-recursive one level + recursive walk).
    static func collectVideos(from urls: [URL]) -> [URL] {
        var results: [URL] = []
        var seen = Set<String>()
        let fm = FileManager.default

        func add(_ url: URL) {
            let resolved = url.resolvingSymlinksInPath()
            let key = resolved.path
            guard !seen.contains(key) else { return }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: resolved.path, isDirectory: &isDir) else { return }
            if isDir.boolValue {
                if let enumerator = fm.enumerator(
                    at: resolved,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                ) {
                    for case let fileURL as URL in enumerator {
                        if isSupportedVideo(fileURL) {
                            let k = fileURL.path
                            if !seen.contains(k) {
                                seen.insert(k)
                                results.append(fileURL)
                            }
                        }
                    }
                }
            } else if isSupportedVideo(resolved) {
                seen.insert(key)
                results.append(resolved)
            }
        }

        for url in urls { add(url) }
        return results.sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
    }

    static func loadDuration(of url: URL) async throws -> TimeInterval {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        return CMTimeGetSeconds(duration)
    }

    static func convert(
        videoURL: URL,
        mode: TrimMode,
        custom: CustomTrimTemplate = .default,
        keyframePercent: Double = 0.5,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> LivePhotoPair {
        let asset = AVURLAsset(url: videoURL)
        let sourceDuration = CMTimeGetSeconds(try await asset.load(.duration))
        let segment = plannedSegment(sourceDuration: sourceDuration, mode: mode, custom: custom)
        let assetIdentifier = UUID().uuidString

        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LivePhotoConverter-\(assetIdentifier)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        progress(0.05)

        let heicURL = workDir.appendingPathComponent("IMG_\(assetIdentifier).HEIC")
        let movURL = workDir.appendingPathComponent("IMG_\(assetIdentifier).MOV")

        let keyTime = segment.start + segment.duration * max(0.05, min(keyframePercent, 0.95))
        try await extractAndStampHEIC(
            asset: asset,
            at: keyTime,
            assetIdentifier: assetIdentifier,
            to: heicURL
        )
        progress(0.25)

        try await writeLiveMOV(
            source: asset,
            segment: segment,
            assetIdentifier: assetIdentifier,
            keyframePercent: keyframePercent,
            to: movURL,
            progress: { p in progress(0.25 + p * 0.7) }
        )
        progress(1.0)

        return LivePhotoPair(
            heicURL: heicURL,
            movURL: movURL,
            assetIdentifier: assetIdentifier,
            segment: segment
        )
    }

    /// Find an existing user album by title, or create one.
    /// Uses `PHAssetCollection.fetchAssetCollections` then
    /// `PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle:)`.
    static func resolveOrCreateAlbum(titled title: String) async throws -> PHAssetCollection {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? "Live Photo Converter" : trimmed

        let status = await requestPhotosAccess()
        guard status == .authorized || status == .limited else {
            throw LivePhotoEngineError.photosDenied
        }

        if let existing = fetchAlbum(named: name) {
            return existing
        }

        var placeholder: PHObjectPlaceholder?
        try await PHPhotoLibrary.shared().performChanges {
            let req = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: name)
            placeholder = req.placeholderForCreatedAssetCollection
        }
        guard let localID = placeholder?.localIdentifier else {
            throw LivePhotoEngineError.albumCreateFailed
        }
        let result = PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: [localID],
            options: nil
        )
        guard let album = result.firstObject else {
            throw LivePhotoEngineError.albumCreateFailed
        }
        return album
    }

    private static func fetchAlbum(named title: String) -> PHAssetCollection? {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "title = %@", title)
        let result = PHAssetCollection.fetchAssetCollections(
            with: .album,
            subtype: .albumRegular,
            options: options
        )
        return result.firstObject
    }

    /// Create Live Photo in the library and add it to `album`
    /// via `PHAssetCreationRequest` + `PHAssetCollectionChangeRequest(for:)`.
    static func saveToPhotos(_ pair: LivePhotoPair, album: PHAssetCollection) async throws {
        let status = await requestPhotosAccess()
        guard status == .authorized || status == .limited else {
            throw LivePhotoEngineError.photosDenied
        }

        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.shouldMoveFile = false
            request.addResource(with: .photo, fileURL: pair.heicURL, options: options)
            request.addResource(with: .pairedVideo, fileURL: pair.movURL, options: options)

            let placeholder = request.placeholderForCreatedAsset
            let albumChange = PHAssetCollectionChangeRequest(for: album)
            if let placeholder, let albumChange {
                albumChange.addAssets([placeholder] as NSArray)
            }
        }
    }

    /// Convenience: resolve/create album by name, then save.
    static func saveToPhotos(_ pair: LivePhotoPair, albumTitle: String) async throws {
        let album = try await resolveOrCreateAlbum(titled: albumTitle)
        try await saveToPhotos(pair, album: album)
    }

    static func exportPair(_ pair: LivePhotoPair, to directory: URL) throws -> (URL, URL) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDir), isDir.boolValue else {
            throw LivePhotoEngineError.exportFolderMissing
        }
        let base = "LivePhoto-\(pair.assetIdentifier.prefix(8))"
        let heicDest = directory.appendingPathComponent("\(base).HEIC")
        let movDest = directory.appendingPathComponent("\(base).MOV")
        if FileManager.default.fileExists(atPath: heicDest.path) {
            try FileManager.default.removeItem(at: heicDest)
        }
        if FileManager.default.fileExists(atPath: movDest.path) {
            try FileManager.default.removeItem(at: movDest)
        }
        try FileManager.default.copyItem(at: pair.heicURL, to: heicDest)
        try FileManager.default.copyItem(at: pair.movURL, to: movDest)
        return (heicDest, movDest)
    }

    @MainActor
    private static func requestPhotosAccess() async -> PHAuthorizationStatus {
        // readWrite required to find/create albums and add assets to them
        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if current == .notDetermined {
            return await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        return current
    }

    private static func extractAndStampHEIC(
        asset: AVAsset,
        at seconds: TimeInterval,
        assetIdentifier: String,
        to destinationURL: URL
    ) async throws {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceAfter = .zero
        generator.requestedTimeToleranceBefore = .zero

        let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        let cgImage: CGImage
        if #available(macOS 13.0, *) {
            let result = try await generator.image(at: time)
            cgImage = result.image
        } else {
            var actual = CMTime.zero
            cgImage = try generator.copyCGImage(at: time, actualTime: &actual)
        }

        guard let dest = CGImageDestinationCreateWithURL(
            destinationURL as CFURL,
            UTType.heic.identifier as CFString,
            1,
            nil
        ) else {
            throw LivePhotoEngineError.cannotWriteHEIC
        }

        // HEIC preserves Apple MakerNote (key 17) more reliably than JPEG for Live Photo pairing.
        let makerNote: [String: Any] = ["17": assetIdentifier]
        let properties: [CFString: Any] = [
            kCGImagePropertyMakerAppleDictionary: makerNote,
            kCGImageDestinationLossyCompressionQuality: 0.95
        ]
        CGImageDestinationAddImage(dest, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw LivePhotoEngineError.cannotWriteHEIC
        }
    }

    private static func writeLiveMOV(
        source: AVAsset,
        segment: LivePhotoSegment,
        assetIdentifier: String,
        keyframePercent: Double,
        to destinationURL: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }

        let videoTracks = try await source.loadTracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first else {
            throw LivePhotoEngineError.noVideoTrack
        }

        let naturalSize = try await videoTrack.load(.naturalSize)
        let preferredTransform = try await videoTrack.load(.preferredTransform)
        let nominalRate = try await videoTrack.load(.nominalFrameRate)
        let frameRate = max(nominalRate > 0 ? nominalRate : 30, 1)

        let transformed = naturalSize.applying(preferredTransform)
        let width = abs(transformed.width)
        let height = abs(transformed.height)
        guard width > 0, height > 0 else {
            throw LivePhotoEngineError.noVideoTrack
        }

        let writer = try AVAssetWriter(outputURL: destinationURL, fileType: .mov)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(width),
            AVVideoHeightKey: Int(height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Int(width * height * 4),
                AVVideoExpectedSourceFrameRateKey: Int(frameRate.rounded())
            ]
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        videoInput.transform = preferredTransform
        guard writer.canAdd(videoInput) else { throw LivePhotoEngineError.cannotCreateWriter }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        let audioTracks = try await source.loadTracks(withMediaType: .audio)
        if audioTracks.first != nil {
            let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: nil)
            aInput.expectsMediaDataInRealTime = false
            if writer.canAdd(aInput) {
                writer.add(aInput)
                audioInput = aInput
            }
        }

        writer.metadata = [metadataForAssetID(assetIdentifier)]

        let stillAdaptor = createMetadataAdaptorForStillImageTime()
        guard writer.canAdd(stillAdaptor.assetWriterInput) else {
            throw LivePhotoEngineError.cannotCreateWriter
        }
        writer.add(stillAdaptor.assetWriterInput)

        let composition = AVMutableComposition()
        guard let compVideo = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw LivePhotoEngineError.cannotCreateWriter
        }
        compVideo.preferredTransform = preferredTransform

        var compAudio: AVMutableCompositionTrack?
        if audioInput != nil, audioTracks.first != nil {
            compAudio = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            )
        }

        try insertSegment(
            videoTrack: compVideo,
            audioTrack: compAudio,
            sourceVideo: videoTrack,
            sourceAudio: audioTracks.first,
            segment: segment
        )

        let reader = try AVAssetReader(asset: composition)
        let videoReaderSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        let videoOutput = AVAssetReaderTrackOutput(track: compVideo, outputSettings: videoReaderSettings)
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { throw LivePhotoEngineError.cannotCreateReader }
        reader.add(videoOutput)

        var audioOutput: AVAssetReaderTrackOutput?
        if let compAudio {
            let ao = AVAssetReaderTrackOutput(track: compAudio, outputSettings: nil)
            ao.alwaysCopiesSampleData = false
            if reader.canAdd(ao) {
                reader.add(ao)
                audioOutput = ao
            }
        }

        writer.startWriting()
        reader.startReading()
        writer.startSession(atSourceTime: .zero)

        let outputDuration = CMTime(seconds: max(segment.duration, 0.01), preferredTimescale: 600)
        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(frameRate.rounded(), 1)))
        let stillStart = CMTimeMultiplyByFloat64(
            outputDuration,
            multiplier: max(0.05, min(keyframePercent, 0.95))
        )
        stillAdaptor.append(
            AVTimedMetadataGroup(
                items: [metadataItemForStillImageTime()],
                timeRange: CMTimeRange(start: stillStart, duration: frameDuration)
            )
        )

        let totalFrames = max(Int(segment.duration * Double(frameRate)), 1)

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let videoQueue = DispatchQueue(label: "livephoto.video")
            let audioQueue = DispatchQueue(label: "livephoto.audio")
            let lock = NSLock()
            var videoDone = false
            var audioDone = audioInput == nil || audioOutput == nil
            var frameCount = 0
            var finished = false

            func finishIfNeeded() {
                lock.lock()
                defer { lock.unlock() }
                guard videoDone && audioDone, !finished else { return }
                finished = true
                writer.finishWriting {
                    if writer.status == .completed {
                        cont.resume()
                    } else {
                        let msg = writer.error?.localizedDescription ?? "Unknown writer error"
                        cont.resume(throwing: LivePhotoEngineError.exportFailed(msg))
                    }
                }
            }

            videoInput.requestMediaDataWhenReady(on: videoQueue) {
                while videoInput.isReadyForMoreMediaData {
                    if let sample = videoOutput.copyNextSampleBuffer() {
                        if !videoInput.append(sample) {
                            videoInput.markAsFinished()
                            lock.lock(); videoDone = true; lock.unlock()
                            finishIfNeeded()
                            return
                        }
                        frameCount += 1
                        progress(min(Double(frameCount) / Double(totalFrames), 0.99))
                    } else {
                        videoInput.markAsFinished()
                        lock.lock(); videoDone = true; lock.unlock()
                        finishIfNeeded()
                        return
                    }
                }
            }

            if let audioInput, let audioOutput {
                audioInput.requestMediaDataWhenReady(on: audioQueue) {
                    while audioInput.isReadyForMoreMediaData {
                        if let sample = audioOutput.copyNextSampleBuffer() {
                            if !audioInput.append(sample) {
                                audioInput.markAsFinished()
                                lock.lock(); audioDone = true; lock.unlock()
                                finishIfNeeded()
                                return
                            }
                        } else {
                            audioInput.markAsFinished()
                            lock.lock(); audioDone = true; lock.unlock()
                            finishIfNeeded()
                            return
                        }
                    }
                }
            }
        }

        if reader.status == .failed {
            throw LivePhotoEngineError.exportFailed(reader.error?.localizedDescription ?? "Reader failed")
        }
    }

    /// Insert exactly the planned segment — never loop or pad.
    private static func insertSegment(
        videoTrack: AVMutableCompositionTrack,
        audioTrack: AVMutableCompositionTrack?,
        sourceVideo: AVAssetTrack,
        sourceAudio: AVAssetTrack?,
        segment: LivePhotoSegment
    ) throws {
        let start = CMTime(seconds: max(segment.start, 0), preferredTimescale: 600)
        let duration = CMTime(seconds: max(segment.duration, 0.01), preferredTimescale: 600)
        let range = CMTimeRange(start: start, duration: duration)
        try videoTrack.insertTimeRange(range, of: sourceVideo, at: .zero)
        if let audioTrack, let sourceAudio {
            try? audioTrack.insertTimeRange(range, of: sourceAudio, at: .zero)
        }
    }

    private static func metadataForAssetID(_ assetIdentifier: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.key = "com.apple.quicktime.content.identifier" as NSString
        item.keySpace = AVMetadataKeySpace("mdta")
        item.value = assetIdentifier as NSString
        item.dataType = "com.apple.metadata.datatype.UTF-8"
        return item
    }

    private static func createMetadataAdaptorForStillImageTime() -> AVAssetWriterInputMetadataAdaptor {
        let spec: NSDictionary = [
            kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as NSString:
                "mdta/com.apple.quicktime.still-image-time",
            kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as NSString:
                "com.apple.metadata.datatype.int8"
        ]
        var desc: CMFormatDescription?
        CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
            allocator: kCFAllocatorDefault,
            metadataType: kCMMetadataFormatType_Boxed,
            metadataSpecifications: [spec] as CFArray,
            formatDescriptionOut: &desc
        )
        let input = AVAssetWriterInput(
            mediaType: .metadata,
            outputSettings: nil,
            sourceFormatHint: desc
        )
        input.expectsMediaDataInRealTime = true
        return AVAssetWriterInputMetadataAdaptor(assetWriterInput: input)
    }

    private static func metadataItemForStillImageTime() -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.key = "com.apple.quicktime.still-image-time" as NSString
        item.keySpace = AVMetadataKeySpace("mdta")
        item.value = Int8(-1) as NSNumber
        item.dataType = "com.apple.metadata.datatype.int8"
        return item
    }
}
