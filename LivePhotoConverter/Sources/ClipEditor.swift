import SwiftUI
import AVKit

private func mediaTime(_ seconds: Double) -> CMTime {
    CMTime(seconds: seconds, preferredTimescale: 60_000)
}

@MainActor
final class SegmentPlayer: ObservableObject {
    let player = AVPlayer()
    @Published private(set) var position = 0.0
    @Published private(set) var playing = false
    private var observer: Any?
    private var endObserver: NSObjectProtocol?
    private var seekID = 0

    func open(_ url: URL) {
        close()
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                                             object: item, queue: .main) { [weak self, weak item] _ in
            Task { @MainActor in
                guard let self, let item, self.player.currentItem === item else { return }
                self.playing = false
                self.position = item.currentTime().seconds
            }
        }
        observer = player.addPeriodicTimeObserver(forInterval: mediaTime(1 / 30), queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self, time.seconds.isFinite else { return }
                if self.player.rate != 0 || self.playing {
                    self.position = time.seconds
                    self.playing = self.player.rate != 0
                }
            }
        }
    }

    func close() {
        seekID += 1
        player.pause()
        if let observer { player.removeTimeObserver(observer) }
        observer = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player.replaceCurrentItem(with: nil)
        playing = false
    }

    func configure(_ segment: LivePhotoSegment, cover: Double) {
        player.currentItem?.forwardPlaybackEndTime = mediaTime(segment.end)
        player.currentItem?.reversePlaybackEndTime = mediaTime(segment.start)
        seek(cover)
    }

    func seek(_ seconds: Double, play: Bool = false) {
        seekID += 1
        let current = seekID
        player.pause()
        playing = false
        position = seconds
        player.seek(to: mediaTime(seconds), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor in
                guard let self, finished, self.seekID == current, play else { return }
                self.playing = true
                self.player.play()
            }
        }
    }

    func toggle(_ segment: LivePhotoSegment) {
        if playing {
            player.pause()
            playing = false
        } else {
            seek(segment.start, play: true)
        }
    }
}

private struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) { view.player = nil }
}

struct ClipEditor: View {
    let item: QueueItem
    @ObservedObject var model: ConverterViewModel
    @StateObject private var playback = SegmentPlayer()
    @State private var track: AVAssetTrack?

    private var segment: LivePhotoSegment { item.segment(model.appDefaults) }
    private var cover: Double { segment.coverTime(at: item.keyframePercent) }
    private var mode: TrimMode { item.override?.trimMode ?? model.appDefaults.trimMode }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PlayerSurface(player: playback.player)
                .frame(maxWidth: .infinity).frame(height: 216).background(.black)
                .overlay {
                    if !playback.playing {
                        FrameThumbnail(url: item.url, seconds: min(playback.position, segment.coverTime(at: 1)),
                                       exact: true, maximumSize: CGSize(width: 1280, height: 720))
                            .allowsHitTesting(false)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("Selected segment preview")
            HStack {
                Button { playback.toggle(segment) } label: {
                    Label(playback.playing ? "Pause" : "Play selected segment", systemImage: playback.playing ? "pause.fill" : "play.fill")
                }
                Spacer()
                Text(String(format: "%.2f s", playback.position)).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { min(max(playback.position, segment.start), segment.end) },
                                  set: { playback.seek($0) }), in: segment.start...segment.end) {
                Text("Preview playhead")
            }.labelsHidden().accessibilityLabel("Preview playhead")

            if item.duration > LivePhotoEngine.maxLiveDuration {
                HStack {
                    Picker("Trim", selection: Binding(get: { mode }, set: { newMode in
                        model.updateTrim(TrimSettings(trimMode: newMode, customTrim: item.override?.customTrim ?? model.appDefaults.customTrim))
                    })) { ForEach(TrimMode.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented)
                    if item.override != nil { Button("Reset") { model.updateTrim(nil) }.help("Use default trim") }
                }
            } else {
                Label(String(format: "Using the full %.2f-second clip", item.duration), systemImage: "film")
                if segment.isShortWarning { Text("This short clip may have limited motion in Photos.").font(.caption) }
            }
            ClipTimeline(url: item.url, segment: segment, cover: cover, editable: mode == .custom && item.duration > 3,
                         onChange: edit, onPreview: { point in
                             dragPreview = point
                             if let point { playback.seek(point) }
                         })
            if mode == .custom && item.duration > 3 {
                HStack {
                    timeField("Start", value: segment.start) { edit($0, segment.duration) }
                    timeField("Duration", value: segment.duration) { edit(segment.start, $0) }
                }
            } else {
                Text(String(format: "%.2f – %.2f s of %.2f s", segment.start, segment.end, item.duration))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Divider()
            HStack(spacing: 12) {
                FrameThumbnail(url: item.url, seconds: cover, exact: true)
                    .frame(width: 84, height: 58).background(.black).clipShape(RoundedRectangle(cornerRadius: 4))
                    .accessibilityLabel("Cover image")
                VStack(alignment: .leading, spacing: 4) {
                    Text("Cover image").font(.headline)
                    Text(String(format: "%.2f s", cover)).font(.caption.monospacedDigit())
                }
                Spacer()
                Button("Use current frame as cover") {
                    let time = playback.playing ? playback.player.currentTime().seconds : playback.position
                    if time.isFinite { playback.seek(time); setCover(time) }
                }
            }
            HStack {
                Button { stepCover(-1) } label: { Image(systemName: "backward.frame") }
                    .accessibilityLabel("Previous cover frame").help("Previous cover frame")
                Slider(value: Binding(get: { item.keyframePercent }, set: model.updateKeyframe), in: 0...1) {
                    Text("Cover position")
                }.labelsHidden().accessibilityLabel("Cover position")
                Button { stepCover(1) } label: { Image(systemName: "forward.frame") }
                    .accessibilityLabel("Next cover frame").help("Next cover frame")
            }
        }
        .disabled(model.busy)
        .onAppear {
            playback.open(item.url)
            playback.configure(segment, cover: cover)
        }
        .task(id: item.id) { track = try? await AVURLAsset(url: item.url).loadTracks(withMediaType: .video).first }
        .onChange(of: segment) { next in
            // Keep the active edge visible during a drag. Ordinary preset edits return to the cover.
            let point = dragPreview.map { min(max($0, next.start), next.end) } ?? cover
            playback.configure(next, cover: point)
        }
        .onChange(of: item.keyframePercent) { _ in playback.seek(cover) }
        .onDisappear { playback.close() }
    }

    @State private var dragPreview: Double?

    private func edit(_ start: Double, _ length: Double) {
        guard start.isFinite, length.isFinite else { return }
        let window = min(max(length, LivePhotoEngine.minCustomWindow), LivePhotoEngine.maxLiveDuration)
        let offset = min(max(start, 0), item.duration - window)
        if abs(segment.start - offset) < 0.000001 && abs(segment.duration - window) < 0.000001 { return }
        model.updateTrim(TrimSettings(trimMode: .custom, customTrim: .init(startOffset: offset, windowLength: window)))
    }

    private func timeField(_ title: String, value: Double, set: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 5) {
            Text(title)
            TextField(title, value: Binding(get: { value }, set: set), format: .number.precision(.fractionLength(0...3)))
                .frame(width: 66).textFieldStyle(.roundedBorder).accessibilityLabel(title + " in seconds")
            Text("s").foregroundStyle(.secondary)
        }
    }

    private func setCover(_ time: Double) {
        model.updateKeyframe((time - segment.start) / segment.duration)
    }

    private func stepCover(_ count: Int64) {
        if let cursor = track?.makeSampleCursor(presentationTimeStamp: mediaTime(cover)) {
            _ = cursor.stepInPresentationOrder(byCount: count)
            setCover(cursor.presentationTimeStamp.seconds)
        } else {
            setCover(cover + Double(count) / item.nominalFrameRate)
        }
    }
}

private struct FrameThumbnail: View {
    let url: URL
    let seconds: Double
    var exact = false
    var maximumSize = CGSize(width: 200, height: 160)
    @State private var image: CGImage?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                if let image {
                    Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: exact ? .fit : .fill)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }
            }.clipped()
        }
        .task(id: seconds) {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.maximumSize = maximumSize
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceAfter = exact ? .zero : mediaTime(0.3)
            generator.requestedTimeToleranceBefore = generator.requestedTimeToleranceAfter
            let frame = try? await generator.image(at: mediaTime(seconds))
            if !Task.isCancelled { image = frame?.image }
        }
    }
}

private struct ClipTimeline: View {
    let url: URL
    let segment: LivePhotoSegment
    let cover: Double
    let editable: Bool
    let onChange: (Double, Double) -> Void
    let onPreview: (Double?) -> Void
    private enum Part { case start, end, move }
    @State private var drag: (part: Part, start: Double, end: Double)?

    var body: some View {
        GeometryReader { geometry in
            let scale = geometry.size.width / segment.sourceDuration
            ZStack(alignment: .leading) {
                HStack(spacing: 1) {
                    ForEach(0..<10) { i in
                        FrameThumbnail(url: url, seconds: segment.sourceDuration * (Double(i) + 0.5) / 10)
                    }
                }.accessibilityHidden(true)
                Rectangle().fill(.black.opacity(0.48)).frame(width: segment.start * scale)
                Rectangle().fill(.black.opacity(0.48)).frame(width: max(0, (segment.sourceDuration - segment.end) * scale))
                    .offset(x: segment.end * scale)
                RoundedRectangle(cornerRadius: 3).strokeBorder(Color.accentColor, lineWidth: 3)
                    .frame(width: max(2, segment.duration * scale)).offset(x: segment.start * scale)
                Rectangle().fill(.white).frame(width: 2).shadow(radius: 1).offset(x: cover * scale)
                if editable {
                    grip("Trim start", at: segment.start, scale: scale, start: true)
                    grip("Trim end", at: segment.end, scale: scale, start: false)
                    Color.clear.contentShape(Rectangle()).gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let point = value.startLocation.x / scale
                                if drag == nil {
                                    let left = abs(point - segment.start), right = abs(point - segment.end)
                                    if min(left, right) * scale <= 9 {
                                        drag = (left <= right ? .start : .end, segment.start, segment.end)
                                    } else {
                                        let inside = point >= segment.start && point <= segment.end
                                        let origin = inside ? segment.start : min(max(point - segment.duration / 2, 0), segment.sourceDuration - segment.duration)
                                        drag = (.move, origin, origin + segment.duration)
                                    }
                                }
                                guard let drag else { return }
                                adjust(drag.part, start: drag.start, end: drag.end, delta: value.translation.width / scale)
                            }.onEnded { _ in drag = nil; onPreview(nil) }
                    ).accessibilityHidden(true)
                }
            }.clipShape(RoundedRectangle(cornerRadius: 5))
        }.frame(height: 46)
    }

    private func grip(_ label: String, at time: Double, scale: Double, start: Bool) -> some View {
        Capsule().fill(.white).frame(width: 6, height: 24).shadow(radius: 1)
            .offset(x: time * scale - 3)
            .accessibilityElement().accessibilityLabel(label)
            .accessibilityValue(String(format: "%.2f seconds", time))
            .accessibilityAdjustableAction { direction in
                adjust(start ? .start : .end, start: segment.start, end: segment.end,
                       delta: direction == .increment ? 0.05 : -0.05)
                onPreview(nil)
            }
    }

    private func adjust(_ part: Part, start: Double, end: Double, delta: Double) {
        let minLength = LivePhotoEngine.minCustomWindow, maxLength = LivePhotoEngine.maxLiveDuration
        switch part {
        case .start:
            let edge = min(max(start + delta, max(0, end - maxLength)), end - minLength)
            onChange(edge, end - edge)
            onPreview(edge)
        case .end:
            let edge = min(max(end + delta, start + minLength), min(segment.sourceDuration, start + maxLength))
            onChange(start, edge - start)
            onPreview(edge)
        case .move:
            let length = end - start
            let offset = min(max(start + delta, 0), segment.sourceDuration - length)
            onChange(offset, length)
            onPreview(offset + length / 2)
        }
    }
}
