import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

struct InspectorView: View {
    @Environment(GraphStore.self) private var store

    var body: some View {
        if let node = store.selectedNode, let kind = store.kind(node) {
            NodeInspector(node: node, kind: kind)
                .id(node.id)
        } else {
            ContentUnavailableView {
                Label("Nothing selected", systemImage: "cursorarrow.click.2")
            } description: {
                Text("Click a node to see its preview and settings.")
            }
        }
    }
}

struct NodeInspector: View {
    @Environment(GraphStore.self) private var store
    let node: Node
    let kind: NodeKind

    private var params: Params { Params(values: node.params, kind: kind) }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    IconTile(symbol: kind.symbol, color: kind.category.color, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(kind.title).font(.title3.weight(.semibold))
                        Text(kind.summary).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                PreviewPanel(node: node, kind: kind)
            }

            if kind.id == "download" { downloadSection }

            let visible = kind.params.filter { $0.visible?(params) ?? true }
            if !visible.isEmpty {
                Section("Settings") {
                    ForEach(visible, id: \.key) { spec in
                        ParamControl(node: node, spec: spec, params: params)
                    }
                }
            }

            if kind.isExport { exportSection }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private var downloadSection: some View {
        Section {
            if let d = store.downloads[node.id] {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: d.progress) { Text(d.status).font(.callout) }
                    Button("Cancel", role: .cancel) { store.cancelDownload(node.id) }
                }
            } else {
                Button {
                    store.startDownload(node.id)
                } label: {
                    Label("Download", systemImage: "arrow.down.circle.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(params.string("url").isEmpty)
            }
        } footer: {
            Text("Render downloads it too. Files are kept in a cache, so the same link isn't fetched twice.")
        }
    }

    @ViewBuilder private var exportSection: some View {
        Section("Saves to") {
            LabeledContent {
                Button("Change…") { chooseFolder() }
            } label: {
                Label(store.outputFolder.lastPathComponent, systemImage: "folder.fill")
                    .foregroundStyle(.primary)
            }
            if let urls = store.lastResults[node.id], !urls.isEmpty {
                ForEach(urls.prefix(6), id: \.self) { url in
                    LabeledContent {
                        Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    } label: {
                        Label(url.lastPathComponent, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                if urls.count > 6 { Text("and \(urls.count - 6) more").foregroundStyle(.secondary) }
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use This Folder"
        panel.directoryURL = store.outputFolder
        if panel.runModal() == .OK, let url = panel.url { store.outputFolder = url }
    }
}

// MARK: - Settings controls

struct ParamControl: View {
    @Environment(GraphStore.self) private var store
    let node: Node
    let spec: ParamSpec
    let params: Params

    var body: some View {
        switch spec.control {
        case .slider(let range, let step, let unit):
            let binding = Binding<Double>(get: { params.number(spec.key) },
                                          set: { store.setParam(node.id, spec.key, .number(($0 / step).rounded() * step)) })
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(spec.label)
                    Spacer()
                    TextField("", value: binding, format: .number.precision(.fractionLength(step < 1 ? (step < 0.1 ? 2 : 1) : 0)))
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .textFieldStyle(.plain)
                        .frame(width: 60)
                    if !unit.isEmpty { Text(unit).foregroundStyle(.secondary).frame(minWidth: 18, alignment: .leading) }
                }
                Slider(value: Binding(get: { min(max(binding.wrappedValue, range.lowerBound), range.upperBound) },
                                      set: { binding.wrappedValue = $0 }),
                       in: range)
                    .controlSize(.small)
            }
        case .toggle:
            Toggle(spec.label, isOn: Binding(get: { params.bool(spec.key) }, set: { store.setParam(node.id, spec.key, .bool($0)) }))
        case .field(let placeholder):
            TextField(spec.label, text: Binding(get: { params.string(spec.key) }, set: { store.setParam(node.id, spec.key, .text($0)) }),
                      prompt: Text(placeholder))
        case .secure(let placeholder):
            SecureField(spec.label, text: Binding(get: { params.string(spec.key) }, set: { store.setParam(node.id, spec.key, .text($0)) }),
                        prompt: Text(placeholder))
        case .textArea:
            VStack(alignment: .leading, spacing: 6) {
                Text(spec.label)
                TextEditor(text: Binding(get: { params.string(spec.key) }, set: { store.setParam(node.id, spec.key, .text($0)) }))
                    .font(.body)
                    .frame(minHeight: 120)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            }
        case .choice(let options):
            Picker(spec.label, selection: Binding(get: { params.string(spec.key) }, set: { store.setParam(node.id, spec.key, .text($0)) })) {
                ForEach(options, id: \.id) { Text($0.label).tag($0.id) }
            }
        case .files(let types, let multiple):
            FilesControl(node: node, spec: spec, urls: params.files(spec.key), types: types, multiple: multiple)
        }
    }
}

struct FilesControl: View {
    @Environment(GraphStore.self) private var store
    let node: Node
    let spec: ParamSpec
    let urls: [URL]
    let types: [UTType]
    let multiple: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if urls.isEmpty {
                Button { choose() } label: {
                    Label(multiple ? "Choose Images or a Folder…" : "Choose \(spec.label)…", systemImage: "folder.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                Text("…or drop files on the canvas.").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(urls.prefix(5), id: \.self) { url in
                    HStack(spacing: 8) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 22, height: 22)
                        Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Image(systemName: "magnifyingglass") }
                            .buttonStyle(.borderless).help("Show in Finder")
                    }
                }
                if urls.count > 5 { Text("and \(urls.count - 5) more").font(.caption).foregroundStyle(.secondary) }
                HStack {
                    Button(multiple ? "Add…" : "Replace…") { choose() }
                    if multiple { Button("Clear") { store.setParam(node.id, spec.key, .files([])) } }
                }
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = types.filter { $0 != .folder }
        panel.canChooseDirectories = types.contains(.folder)
        panel.allowsMultipleSelection = multiple
        guard panel.runModal() == .OK else { return }
        FileAccess.remember(panel.urls)
        let picked = panel.urls.map(\.path)
        store.setParam(node.id, spec.key, .files(multiple ? urls.map(\.path) + picked : picked))
    }
}

// MARK: - Preview

struct PreviewPanel: View {
    @Environment(GraphStore.self) private var store
    let node: Node
    let kind: NodeKind

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                if let error = store.errors[node.id] {
                    message(error, symbol: "exclamationmark.triangle.fill", tint: .orange)
                } else if store.waiting.contains(node.id) {
                    message("Fix the node before this one first.", symbol: "arrow.left.circle", tint: .secondary)
                } else if let p = store.large {
                    content(p)
                } else if !kind.inputs.isEmpty && store.graph.edge(into: node.id, port: 0) == nil {
                    message("Connect an input to see a preview.", symbol: "point.3.connected.trianglepath.dotted", tint: .secondary)
                } else {
                    ProgressView().frame(height: 160)
                }
            }
            .frame(maxWidth: .infinity)
            if let p = store.large, store.errors[node.id] == nil {
                Text(p.info).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func message(_ text: String, symbol: String, tint: Color) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 26)).foregroundStyle(tint)
            Text(text).multilineTextAlignment(.center).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 140)
    }

    @ViewBuilder private func content(_ p: PreviewPayload) -> some View {
        switch p.content {
        case .image(let img):
            picture(img)
        case .video(let img, let duration):
            VStack(spacing: 8) {
                picture(img)
                HStack(spacing: 8) {
                    Image(systemName: "film").foregroundStyle(.secondary)
                    @Bindable var store = store
                    Slider(value: $store.previewFraction, in: 0...1).controlSize(.small)
                    Text(PreviewPayload.time(duration * store.previewFraction)).monospacedDigit().foregroundStyle(.secondary).font(.caption)
                }
            }
        case .images(let list, _):
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 80), spacing: 6)], spacing: 6) {
                ForEach(Array(list.enumerated()), id: \.offset) { _, img in
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                        .frame(height: 80).clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }
        case .audio(let wave, let clip):
            AudioPreview(waveform: wave, clip: clip)
        case .pdf(let pages, _):
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { i, page in
                        VStack(spacing: 4) {
                            Image(nsImage: page).resizable().aspectRatio(contentMode: .fit)
                                .frame(height: pages.count == 1 ? 280 : 200)
                                .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
                            Text("\(i + 1)").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(4)
            }
        case .text(let s):
            VStack(alignment: .trailing, spacing: 6) {
                ScrollView {
                    Text(s.isEmpty ? "(empty)" : s)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(10)
                }
                .frame(height: 220)
                .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                Button("Copy", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(s, forType: .string)
                }
                .controlSize(.small)
            }
        }
    }

    private func picture(_ img: NSImage) -> some View {
        ZStack {
            Checkerboard()
            Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
        }
        .aspectRatio(img.size.width / max(1, img.size.height), contentMode: .fit)
        .frame(maxHeight: 300)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .frame(maxWidth: .infinity)
    }
}

struct AudioPreview: View {
    let waveform: [Float]
    let clip: AudioClip
    @State private var player = AudioPreviewPlayer.shared

    var body: some View {
        HStack(spacing: 12) {
            Button {
                player.toggle(clip)
            } label: {
                Image(systemName: player.isPlaying(clip) ? "pause.fill" : "play.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            WaveformShape(samples: waveform, color: .orange, progress: player.isPlaying(clip) ? player.progress : nil)
                .frame(height: 64)
        }
        .padding(.vertical, 6)
        .onDisappear { player.stop() }
    }
}

@Observable @MainActor
final class AudioPreviewPlayer {
    static let shared = AudioPreviewPlayer()
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var current: AVAudioPCMBuffer?
    private var timer: Timer?
    private var startedAt: Date?
    var progress: Double = 0

    init() { engine.attach(node) }

    func isPlaying(_ clip: AudioClip) -> Bool { current === clip.buffer }

    func toggle(_ clip: AudioClip) {
        if isPlaying(clip) { stop(); return }
        stop()
        engine.disconnectNodeOutput(node)
        engine.connect(node, to: engine.mainMixerNode, format: clip.buffer.format)
        do { try engine.start() } catch { return }
        current = clip.buffer
        let buffer = clip.buffer
        node.scheduleBuffer(buffer, at: nil, options: []) { [weak self] in
            Task { @MainActor in if self?.current === buffer { self?.stop() } }
        }
        node.play()
        startedAt = Date()
        let duration = clip.duration
        timer = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let s = self.startedAt else { return }
                self.progress = min(1, Date().timeIntervalSince(s) / max(0.01, duration))
            }
        }
    }

    func stop() {
        node.stop()
        timer?.invalidate()
        timer = nil
        current = nil
        progress = 0
    }
}
