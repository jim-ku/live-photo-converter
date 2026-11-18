import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var model: ConverterViewModel

    init(model: ConverterViewModel? = nil) {
        _model = StateObject(wrappedValue: model ?? ConverterViewModel())
    }
    @State private var showDefaults = false
    @State private var showHelp = false
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 0) {
            if model.items.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "livephoto").font(.system(size: 42, weight: .light)).foregroundStyle(.tint)
                    Text("Drop videos or a folder").font(.title2.bold())
                    Text("MP4, MOV, M4V").font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Button("Choose videos…") { pick(folder: false) }.buttonStyle(.borderedProminent)
                        Button("Choose folder…") { pick(folder: true) }
                    }
                    if model.isImporting { ProgressView().controlSize(.small) }
                    if !model.statusMessage.isEmpty { Text(model.statusMessage).font(.callout) }
                }
                .padding(36)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { geometry in
                    if geometry.size.width >= 770 {
                        HSplitView {
                            queue.frame(minWidth: 190, idealWidth: 240, maxWidth: 350)
                            editor.frame(minWidth: 440, maxWidth: .infinity)
                        }
                    } else {
                        VStack(spacing: 0) {
                            queue.frame(height: min(145, geometry.size.height * 0.28))
                            Divider()
                            editor
                        }
                    }
                }
                Divider()
                footer
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay { if targeted { RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor, lineWidth: 3).allowsHitTesting(false) } }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !model.isBatchRunning, !files.isEmpty else { return false }
            Task { await model.loadURLs(files) }
            return true
        } isTargeted: { targeted = $0 }
        .toolbar {
            ToolbarItemGroup {
                Menu {
                    Button("Add videos…") { pick(folder: false) }.keyboardShortcut("o")
                    Button("Add folder…") { pick(folder: true) }
                    if !model.items.isEmpty {
                        Divider()
                        Button("Clear queue") { model.clear() }
                    }
                } label: { Label("Add videos", systemImage: "plus") }
                .disabled(model.busy)
                Button { showDefaults = true } label: { Label("Trim defaults", systemImage: "slider.horizontal.3") }
                    .help("Trim defaults").disabled(model.busy)
                Button { showHelp = true } label: { Label("Help", systemImage: "questionmark.circle") }.help("Help")
            }
        }
        .sheet(isPresented: $showDefaults) { DefaultsView(model: model) }
        .sheet(isPresented: $showHelp) {
            VStack(alignment: .leading, spacing: 14) {
                Text("How to use Video to Live Photo").font(.title2.bold())
                Text("Add videos or drop a folder. Select a clip in the queue to edit its motion and cover.")
                Text("For clips over three seconds, choose a preset or use Custom to set the start and duration. Reset returns the clip to your trim defaults.")
                Text("Play the selection or scrub the playhead, then choose Use current frame as cover. The arrow buttons step the cover one frame.")
                Text("Choose a Photos album or folder and start the batch. You can send the same clips to another destination afterward.")
                HStack {
                    Button("Reveal diagnostic log") { DropLog.revealInFinder() }
                    Spacer()
                    Button("Done") { showHelp = false }.keyboardShortcut(.defaultAction)
                }
            }.padding(24).frame(width: 440)
        }
    }

    private var queue: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Videos").font(.headline)
                Spacer()
                Text("\(model.items.count)").foregroundStyle(.secondary)
            }.padding(.horizontal, 14).padding(.vertical, 8)
            List(selection: $model.selectedID) {
                ForEach(model.items) { item in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.filename).lineLimit(1).truncationMode(.middle)
                            Text(rowDetail(item)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer()
                        Button { model.removeItem(item.id) } label: { Image(systemName: "xmark.circle") }
                            .buttonStyle(.borderless).accessibilityLabel("Remove " + item.filename)
                            .disabled(model.busy)
                    }
                    .tag(item.id)
                }
            }
            .onDeleteCommand { if let id = model.selectedID { model.removeItem(id) } }
            .listStyle(.sidebar)
        }
    }

    private func rowDetail(_ item: QueueItem) -> String {
        if item.importError != nil { return "Unreadable" }
        if model.activeID == item.id { return "Processing…" }
        if let target = model.target {
            if item.delivered.contains(target) { return model.kind == .photos ? "Saved to album" : "Exported" }
            if item.failures[target] != nil { return "Delivery failed" }
        }
        return String(format: "%.1f s · %@", item.duration, item.override == nil ? "Default trim" : "Custom settings")
    }

    @ViewBuilder private var editor: some View {
        if let item = model.selectedItem {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(item.filename).font(.title2.bold()).textSelection(.enabled)
                    if let error = item.importError {
                        Label(error, systemImage: "exclamationmark.triangle")
                        Button("Reveal diagnostic log") { DropLog.revealInFinder() }
                    } else {
                        ClipEditor(item: item, model: model).id(item.id)
                        if let target = model.target, let error = item.failures[target] {
                            Label(error, systemImage: "exclamationmark.triangle").textSelection(.enabled)
                            Button("Reveal diagnostic log") { DropLog.revealInFinder() }
                        }
                    }
                }.padding(18).frame(maxWidth: .infinity, alignment: .topLeading)
            }
        } else { Text("Select a video").frame(maxWidth: .infinity, maxHeight: .infinity) }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Destination", selection: $model.kind) {
                    ForEach(OutputKind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.labelsHidden().fixedSize().accessibilityLabel("Destination")
                if model.kind == .photos {
                    TextField("Album name", text: $model.albumName).accessibilityLabel("Photos album name")
                } else {
                    Button(model.exportDirectory?.lastPathComponent ?? "Choose folder…") {
                        if let url = chooseExportFolder() { model.setExportFolder(url) }
                    }
                        .lineLimit(1).truncationMode(.middle).help(model.exportDirectory?.path ?? "Choose export folder")
                }
                Spacer(minLength: 2)
                Button(actionTitle) {
                    Task { await model.startDelivery(chooseFolder: chooseExportFolder) }
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: .command)
                .disabled(model.eligible(for: model.target).isEmpty || (model.kind == .photos && model.target == nil))
            }.disabled(model.busy)
            if model.isBatchRunning {
                ProgressView(value: Double(model.batchFinished) + model.progress, total: Double(max(model.batchTotal, 1)))
                    .accessibilityLabel("Batch progress")
            }
            HStack {
                Text(model.statusMessage).font(.callout).lineLimit(2).truncationMode(.middle)
                    .help(model.statusMessage).textSelection(.enabled)
                Spacer()
                if model.isBatchRunning {
                    Button(model.cancelRequested ? "Stopping…" : "Stop after this clip") { model.cancelBatch() }
                        .disabled(model.cancelRequested)
                } else if !model.isImporting {
                    if !model.eligible(for: model.target, failedOnly: true).isEmpty {
                        Button("Retry failed") { Task { await model.runBatch(failedOnly: true) } }
                    }
                    if let result = model.resultTarget {
                        switch result {
                        case .album:
                            Button("Open Photos") {
                                if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Photos") {
                                    NSWorkspace.shared.open(app)
                                }
                            }
                        case .folder(let url):
                            Button("Reveal in Finder") { NSWorkspace.shared.open(url) }
                        }
                    }
                }
            }.controlSize(.small)
        }.padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var actionTitle: String {
        let count = model.eligible(for: model.target).count
        if model.kind == .photos { return "Save \(count) Live Photo" + (count == 1 ? "" : "s") }
        return "Export \(count) pair" + (count == 1 ? "" : "s")
    }

    private func pick(folder: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = folder
        panel.canChooseFiles = !folder
        panel.allowsMultipleSelection = true
        if !folder { panel.allowedContentTypes = [.movie] }
        if panel.runModal() == .OK {
            let urls = panel.urls
            Task { await model.loadURLs(urls) }
        }
    }

    private func chooseExportFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = model.exportDirectory
        panel.prompt = "Choose"
        return panel.runModal() == .OK ? panel.url : nil
    }
}

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

                    Text("Applies to new clips and clips using the default trim.")
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
                        Text("Each clip uses the part of this range that fits within its duration.")
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
