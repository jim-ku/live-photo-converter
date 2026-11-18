import AVFoundation
import XCTest

/// Build a small moving clip locally so media tests also run on a clean Mac.
enum MediaFixture {
    static func make(in directory: URL, portrait: Bool = false, audio: Bool = false) async throws -> URL {
        let movie = directory.appendingPathComponent("Camera.mov")
        let writer = try AVAssetWriter(outputURL: movie, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 160, AVVideoHeightKey: 96
        ])
        if portrait { input.transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 96, ty: 0) }
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 160, kCVPixelBufferHeightKey as String: 96
        ])
        writer.add(input)
        guard writer.startWriting() else { throw try XCTUnwrap(writer.error) }
        writer.startSession(atSourceTime: .zero)
        let pool = try XCTUnwrap(adaptor.pixelBufferPool)
        for frame in 0..<48 {
            while !input.isReadyForMoreMediaData {
                if let error = writer.error { throw error }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            var buffer: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer), kCVReturnSuccess)
            let pixels = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(pixels)
            for y in 0..<96 {
                for x in 0..<160 {
                    let i = y * stride + x * 4
                    base[i] = UInt8(x)
                    base[i + 1] = UInt8(y * 2)
                    base[i + 2] = UInt8(frame * 5)
                    base[i + 3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            guard adaptor.append(pixels, withPresentationTime: CMTime(value: Int64(frame), timescale: 12)) else {
                throw try XCTUnwrap(writer.error)
            }
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: 4, timescale: 1))
        await writer.finishWriting()
        if let error = writer.error { throw error }
        guard audio else { return movie }

        let sound = directory.appendingPathComponent("Tone.caf")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 88_200))
        buffer.frameLength = buffer.frameCapacity
        for i in 0..<Int(buffer.frameLength) {
            buffer.floatChannelData![0][i] = sin(Float(i) * 0.05) * 0.1
        }
        do {
            let file = try AVAudioFile(forWriting: sound, settings: format.settings)
            try file.write(from: buffer)
        }

        let composition = AVMutableComposition()
        let range = CMTimeRange(start: .zero, duration: CMTime(value: 2, timescale: 1))
        for (type, url) in [(AVMediaType.video, movie), (.audio, sound)] {
            let source = AVURLAsset(url: url)
            let tracks = try await source.loadTracks(withMediaType: type)
            let original = try XCTUnwrap(tracks.first)
            let track = try XCTUnwrap(composition.addMutableTrack(withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid))
            try track.insertTimeRange(range, of: original, at: .zero)
            if type == .video { track.preferredTransform = try await original.load(.preferredTransform) }
        }
        let result = directory.appendingPathComponent("Camera with audio.mov")
        let exporter = try XCTUnwrap(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough))
        exporter.outputURL = result
        exporter.outputFileType = .mov
        await exporter.export()
        guard exporter.status == .completed else { throw try XCTUnwrap(exporter.error) }
        return result
    }
}
