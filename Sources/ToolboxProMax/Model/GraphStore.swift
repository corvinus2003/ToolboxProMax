import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// Geometry of a node card. Port positions come from here, so wires and cards always line up.
struct NodeLayout {
    static let width: CGFloat = 230
    static let header: CGFloat = 42
    static let rowHeight: CGFloat = 24
    static let thumbHeight: CGFloat = 118

    let rows: Int
    init(_ kind: NodeKind) { rows = max(1, kind.inputs.count) }

    var rowsTop: CGFloat { Self.header + 6 }
    var thumbTop: CGFloat { rowsTop + CGFloat(rows) * Self.rowHeight + 4 }
    var height: CGFloat { thumbTop + Self.thumbHeight + 10 }
    var size: CGSize { CGSize(width: Self.width, height: height) }
    func inputY(_ i: Int) -> CGFloat { rowsTop + Self.rowHeight * (CGFloat(i) + 0.5) }
    var outputY: CGFloat { rowsTop + Self.rowHeight * 0.5 }
}

struct WireDrag {
    var from: UUID
    var start: CGPoint   // screen space
    var current: CGPoint // screen space
    var type: PortType
}

struct RenderState {
    var running = false
    var progress: Double = 0
    var status = ""
    var saved: [URL] = []
    var failures: [String] = []
    var finished = false
}

@Observable @MainActor
final class GraphStore {
    static let shared = GraphStore()

    var graph = Graph()
    var selection: UUID? { didSet { if selection != oldValue { refresh(delay: 0) } } }
    var offset = CGSize(width: 60, height: 60)
    var zoom: CGFloat = 1
    var canvasSize: CGSize = CGSize(width: 900, height: 600)

    var thumbs: [UUID: PreviewPayload] = [:]
    var large: PreviewPayload?
    var errors: [UUID: String] = [:]
    var waiting: Set<UUID> = []
    var busy: Set<UUID> = []
    var previewFraction: Double = 0.25 { didSet { refresh(delay: 0) } }
    var downloads: [UUID: (progress: Double, status: String)] = [:]
    var wire: WireDrag?
    var render = RenderState()
    var lastResults: [UUID: [URL]] = [:]
    var showWelcome = false

    var outputFolder: URL {
        get {
            access(keyPath: \.outputFolder)
            if let path = UserDefaults.standard.string(forKey: "outputFolder") { return URL(fileURLWithPath: path) }
            return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].appendingPathComponent("Toolbox Pro Max")
        }
        set {
            withMutation(keyPath: \.outputFolder) { UserDefaults.standard.set(newValue.path, forKey: "outputFolder") }
        }
    }

    @ObservationIgnored private var undoStack: [Graph] = []
    @ObservationIgnored private var redoStack: [Graph] = []
    @ObservationIgnored private var lastCheckpoint: (key: String, time: Date)?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var renderTask: Task<Void, Never>?
    @ObservationIgnored private var downloadTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private let evaluator = Evaluator()
    @ObservationIgnored private var payloadCache: [Int: PreviewPayload] = [:]

    private let saveURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Toolbox Pro Max/graph.json")

    init() {
        if let data = try? Data(contentsOf: saveURL), let g = try? JSONDecoder().decode(Graph.self, from: data) {
            graph = Graph(nodes: g.nodes.filter { NodeKind.named($0.kind) != nil }, edges: g.edges)
        }
        if let data = UserDefaults.standard.data(forKey: "viewport"), let v = try? JSONDecoder().decode([Double].self, from: data), v.count == 3 {
            offset = CGSize(width: v[0], height: v[1]); zoom = v[2]
        }
        showWelcome = !UserDefaults.standard.bool(forKey: "welcomeSeen")
        if graph.nodes.contains(where: { $0.kind == "ocr" }) { VisionOps.warmUp() }
        refresh(delay: 0)
    }

    // MARK: Lookups

    func kind(_ node: Node) -> NodeKind? { NodeKind.named(node.kind) }
    var selectedNode: Node? { selection.flatMap { graph.node($0) } }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// What comes out of a node, following "same as input" transforms upstream.
    func outputType(_ id: UUID, depth: Int = 0) -> PortType? {
        guard depth < 64, let node = graph.node(id), let kind = kind(node), let out = kind.output else { return nil }
        if let dyn = kind.dynamicOutput { return dyn(Params(values: node.params, kind: kind)) }
        if out == .visual {
            guard let e = graph.edge(into: id, port: 0) else { return nil }
            return outputType(e.from, depth: depth + 1)
        }
        return out
    }

    func toScreen(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * zoom + offset.width, y: p.y * zoom + offset.height) }
    func toCanvas(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x - offset.width) / zoom, y: (p.y - offset.height) / zoom) }

    func inputPoint(_ node: Node, _ port: Int) -> CGPoint {
        guard let kind = kind(node) else { return node.position }
        return CGPoint(x: node.position.x, y: node.position.y + NodeLayout(kind).inputY(port))
    }

    func outputPoint(_ node: Node) -> CGPoint {
        guard let kind = kind(node) else { return node.position }
        return CGPoint(x: node.position.x + NodeLayout.width, y: node.position.y + NodeLayout(kind).outputY)
    }

    // MARK: Editing

    private func checkpoint(_ key: String = UUID().uuidString) {
        // Slider drags arrive as a stream of tiny edits: one undo step per gesture is enough.
        if let last = lastCheckpoint, last.key == key, Date().timeIntervalSince(last.time) < 1 {
            lastCheckpoint = (key, Date()); return
        }
        undoStack.append(graph)
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
        lastCheckpoint = (key, Date())
    }

    private func changed(reevaluate: Bool = true) {
        if reevaluate { refresh() }
        if graph.nodes.contains(where: { $0.kind == "ocr" }) { VisionOps.warmUp() }
        scheduleSave()
    }

    func undo() {
        guard let g = undoStack.popLast() else { return }
        redoStack.append(graph); graph = g; lastCheckpoint = nil
        if let s = selection, graph.node(s) == nil { selection = nil }
        changed()
    }

    func redo() {
        guard let g = redoStack.popLast() else { return }
        undoStack.append(graph); graph = g; lastCheckpoint = nil
        changed()
    }

    /// Somewhere visible that isn't on top of the last node added.
    private func freeSpot() -> CGPoint {
        let center = toCanvas(CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2))
        let size = CGSize(width: NodeLayout.width, height: 220)
        let taken = graph.nodes.compactMap { n in kind(n).map { CGRect(origin: n.position, size: NodeLayout($0).size).insetBy(dx: -20, dy: -20) } }
        // Spiral out from the middle of the view until there's a gap big enough for a card.
        let start = CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2)
        for ring in 0..<12 {
            let r = CGFloat(ring) * 130
            let steps = max(1, ring * 8)
            for i in 0..<steps {
                let a = Double(i) / Double(steps) * 2 * .pi
                let p = CGPoint(x: start.x + r * cos(a) * 1.6, y: start.y + r * sin(a))
                if !taken.contains(where: { $0.intersects(CGRect(origin: p, size: size)) }) { return p }
            }
        }
        return start
    }

    @discardableResult
    func add(_ kindID: String, at point: CGPoint? = nil, params: [String: ParamValue] = [:], select: Bool = true) -> UUID? {
        guard NodeKind.named(kindID) != nil else { return nil }
        checkpoint()
        let node = Node(kind: kindID, position: point ?? freeSpot(), params: params)
        graph.nodes.append(node)
        if select { selection = node.id }
        // If the selected node has a free output, wire the new one to it: the common "add the next step" move.
        changed()
        return node.id
    }

    /// Adds a node and connects it after the selected one when the types fit.
    func addAfterSelection(_ kindID: String) {
        guard let kind = NodeKind.named(kindID) else { return }
        if let sel = selectedNode, let outType = outputType(sel.id) ?? NodeKind.named(sel.kind)?.possibleOutputs.first,
           kind.accepts([outType], port: 0) {
            let pos = CGPoint(x: sel.position.x + NodeLayout.width + 70, y: sel.position.y)
            if let id = add(kindID, at: pos) { connect(from: sel.id, to: id, port: 0, checkpointing: false) }
        } else {
            add(kindID)
        }
    }

    func addFiles(_ urls: [URL], at screenPoint: CGPoint?) {
        var point = screenPoint.map(toCanvas) ?? freeSpot()
        let images = urls.filter { ImageOps.isImage($0) }
        if images.count > 1 {
            add("images", at: point, params: ["files": .files(images.map(\.path))])
            point.y += 300
        }
        for url in urls where !(images.count > 1 && ImageOps.isImage(url)) {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            let type = UTType(filenameExtension: url.pathExtension)
            let kindID: String? = if isDir.boolValue { "images" }
                else if type?.conforms(to: .image) == true { "image" }
                else if type?.conforms(to: .pdf) == true { "pdf" }
                else if type?.conforms(to: .audiovisualContent) == true && type?.conforms(to: .audio) != true { "video" }
                else if type?.conforms(to: .audio) == true { "audio" }
                else if type?.conforms(to: .plainText) == true { "text" }
                else { nil }
            guard let kindID else { continue }
            let params: [String: ParamValue] = switch kindID {
            case "images": ["files": .files([url.path])]
            case "text": ["text": .text((try? String(contentsOf: url, encoding: .utf8)) ?? "")]
            default: ["file": .files([url.path])]
            }
            add(kindID, at: point, params: params)
            point.y += 300
        }
    }

    func remove(_ id: UUID) {
        checkpoint()
        graph.nodes.removeAll { $0.id == id }
        graph.edges.removeAll { $0.from == id || $0.to == id }
        if selection == id { selection = nil }
        downloadTasks[id]?.cancel()
        changed()
    }

    func duplicate(_ id: UUID) {
        guard let node = graph.node(id) else { return }
        add(node.kind, at: CGPoint(x: node.position.x + 40, y: node.position.y + 40), params: node.params)
    }

    func disconnectInputs(_ id: UUID) {
        checkpoint()
        graph.edges.removeAll { $0.to == id }
        changed()
    }

    func connect(from: UUID, to: UUID, port: Int, checkpointing: Bool = true) {
        guard from != to, !graph.reaches(from: to, to: from) else { return }
        if checkpointing { checkpoint() }
        graph.edges.removeAll { $0.to == to && $0.toPort == port }
        graph.edges.append(Edge(from: from, to: to, toPort: port))
        changed()
    }

    func disconnect(_ edge: Edge) {
        checkpoint()
        graph.edges.removeAll { $0.id == edge.id }
        changed()
    }

    func setParam(_ id: UUID, _ key: String, _ value: ParamValue) {
        guard let i = graph.nodes.firstIndex(where: { $0.id == id }), graph.nodes[i].params[key] != value else { return }
        checkpoint("\(id)\(key)")
        graph.nodes[i].params[key] = value
        changed()
    }

    func beginMove() { checkpoint() }

    func move(_ id: UUID, to p: CGPoint) {
        guard let i = graph.nodes.firstIndex(where: { $0.id == id }) else { return }
        graph.nodes[i].position = p
        changed(reevaluate: false)
    }

    func clear() {
        guard !graph.nodes.isEmpty else { return }
        checkpoint()
        graph = Graph()
        selection = nil
        changed()
    }

    // MARK: Wires

    func finishWire(at screen: CGPoint) {
        defer { wire = nil }
        guard let w = wire else { return }
        var best: (UUID, Int, CGFloat)?
        for node in graph.nodes where node.id != w.from {
            guard let kind = kind(node) else { continue }
            for port in kind.inputs.indices where kind.accepts(w.type.concrete, port: port) {
                let d = hypot(toScreen(inputPoint(node, port)).x - screen.x, toScreen(inputPoint(node, port)).y - screen.y)
                if d < 28 * max(zoom, 0.6), d < (best?.2 ?? .infinity) { best = (node.id, port, d) }
            }
        }
        if let best { connect(from: w.from, to: best.0, port: best.1) }
    }

    /// The input port a wire being dragged would snap to, for highlighting.
    func snapTarget() -> (UUID, Int)? {
        guard let w = wire else { return nil }
        for node in graph.nodes where node.id != w.from {
            guard let kind = kind(node) else { continue }
            for port in kind.inputs.indices where kind.accepts(w.type.concrete, port: port) {
                let p = toScreen(inputPoint(node, port))
                if hypot(p.x - w.current.x, p.y - w.current.y) < 28 * max(zoom, 0.6) { return (node.id, port) }
            }
        }
        return nil
    }

    // MARK: Viewport

    func zoom(by factor: CGFloat, around point: CGPoint? = nil) {
        let p = point ?? CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        let newZoom = min(2.5, max(0.25, zoom * factor))
        let k = newZoom / zoom
        offset = CGSize(width: p.x - (p.x - offset.width) * k, height: p.y - (p.y - offset.height) * k)
        zoom = newZoom
        saveViewport()
    }

    func pan(by d: CGSize) {
        offset.width += d.width; offset.height += d.height
        saveViewport()
    }

    func zoomToFit() {
        guard !graph.nodes.isEmpty else { offset = CGSize(width: 60, height: 60); zoom = 1; return }
        var box = CGRect.null
        for n in graph.nodes {
            guard let k = kind(n) else { continue }
            box = box.union(CGRect(origin: n.position, size: NodeLayout(k).size))
        }
        let margin: CGFloat = 70
        let z = min(1.2, max(0.3, min((canvasSize.width - margin * 2) / box.width, (canvasSize.height - margin * 2) / box.height)))
        zoom = z
        offset = CGSize(width: (canvasSize.width - box.width * z) / 2 - box.minX * z,
                        height: (canvasSize.height - box.height * z) / 2 - box.minY * z)
        saveViewport()
    }

    func actualSize() { zoom(by: 1 / zoom) }

    private func saveViewport() {
        if let data = try? JSONEncoder().encode([offset.width, offset.height, zoom]) {
            UserDefaults.standard.set(data, forKey: "viewport")
        }
    }

    // MARK: Workflows

    func insert(_ workflow: Workflow) {
        checkpoint()
        let bottom = graph.nodes.compactMap { n in kind(n).map { n.position.y + NodeLayout($0).height } }.max()
        let left = graph.nodes.map(\.position.x).min() ?? 0
        let y = bottom.map { $0 + 70 } ?? 0
        var prev: UUID?
        var first: UUID?
        for (i, step) in workflow.steps.enumerated() {
            let node = Node(kind: step.kind, position: CGPoint(x: left + CGFloat(i) * (NodeLayout.width + 70), y: y), params: step.params)
            graph.nodes.append(node)
            if let prev { graph.edges.append(Edge(from: prev, to: node.id, toPort: 0)) }
            prev = node.id
            if first == nil { first = node.id }
        }
        selection = first
        changed()
        zoomToFit()
    }

    // MARK: Saving

    private func scheduleSave() {
        saveTask?.cancel()
        let g = graph, url = saveURL
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let data = try? JSONEncoder().encode(g) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: Live preview

    func refresh(delay: Int = 70) {
        refreshTask?.cancel()
        let graph = graph, selected = selection, fraction = previewFraction, evaluator = evaluator
        refreshTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .milliseconds(delay)) }
            guard let self, !Task.isCancelled else { return }
            var ids = graph.nodes.map(\.id)
            if let s = selected, let i = ids.firstIndex(of: s) { ids.remove(at: i); ids.insert(s, at: 0) }
            if selected == nil { large = nil }

            for id in ids {
                guard !Task.isCancelled else { return }
                var h = Hasher()
                h.combine(evaluator.fingerprint(id, in: graph, preview: true))
                if outputType(id) == .video || outputType(id) == nil { h.combine(fraction) }
                let fp = h.finalize()
                let thumbKey = fp &+ 1, largeKey = fp &+ 2
                let isSelected = id == selected
                let cachedThumb = payloadCache[thumbKey], cachedLarge = payloadCache[largeKey]
                if let cachedThumb, !isSelected || cachedLarge != nil {
                    thumbs[id] = cachedThumb
                    errors[id] = nil; waiting.remove(id)
                    if isSelected { large = cachedLarge }
                    continue
                }
                busy.insert(id)
                let needThumb = cachedThumb == nil, needLarge = isSelected && cachedLarge == nil
                let job = Task.detached(priority: .userInitiated) { () -> Result<(PreviewPayload?, PreviewPayload?), Error> in
                    do {
                        let v = try await evaluator.value(of: id, in: graph, preview: true, maxDimension: 1400)
                        let t = needThumb ? try await PreviewPayload.make(v, maxDimension: 420, fraction: fraction) : nil
                        let l = needLarge ? try await PreviewPayload.make(v, maxDimension: 1400, fraction: fraction, pages: 6) : nil
                        return .success((t, l))
                    } catch {
                        return .failure(error)
                    }
                }
                let result = await withTaskCancellationHandler { await job.value } onCancel: { job.cancel() }
                busy.remove(id)
                guard !Task.isCancelled else { return }
                switch result {
                case .success(let (t, l)):
                    if payloadCache.count > 300 { payloadCache.removeAll() }
                    if let t { payloadCache[thumbKey] = t }
                    if let l { payloadCache[largeKey] = l }
                    thumbs[id] = t ?? cachedThumb
                    errors[id] = nil; waiting.remove(id)
                    if isSelected { large = l ?? cachedLarge }
                case .failure(let error):
                    thumbs[id] = nil
                    if isSelected { large = nil }
                    if error is UpstreamError { waiting.insert(id); errors[id] = nil }
                    else if !(error is CancellationError) { errors[id] = error.localizedDescription; waiting.remove(id) }
                }
            }
            let live = Set(graph.nodes.map(\.id))
            thumbs = thumbs.filter { live.contains($0.key) }
            errors = errors.filter { live.contains($0.key) }
        }
    }

    // MARK: Download

    func startDownload(_ id: UUID) {
        guard let node = graph.node(id), let kind = kind(node) else { return }
        let p = Params(values: node.params, kind: kind)
        let url = p.string("url"), audioOnly = p.string("mode") == "audio", quality = p.string("quality")
        downloads[id] = (0, "Starting…")
        errors[id] = nil
        downloadTasks[id] = Task { [weak self] in
            do {
                _ = try await Downloader.shared.download(url: url, audioOnly: audioOnly, quality: quality) { progress, status in
                    Task { @MainActor in self?.downloads[id] = (progress, status) }
                }
                guard let self else { return }
                downloads[id] = nil
                evaluator.invalidate()
                payloadCache.removeAll()
                refresh(delay: 0)
            } catch {
                guard let self else { return }
                downloads[id] = nil
                if !(error is CancellationError) { errors[id] = error.localizedDescription }
            }
        }
    }

    func cancelDownload(_ id: UUID) {
        downloadTasks[id]?.cancel()
        downloads[id] = nil
    }

    // MARK: Render

    var exportNodes: [Node] { graph.nodes.filter { kind($0)?.isExport == true } }

    func startRender() {
        guard !render.running else { return }
        let exports = exportNodes
        guard !exports.isEmpty else {
            render = RenderState(status: "Add an Export node to choose what to save.", failures: ["No Export node"], finished: true)
            return
        }
        let folder = outputFolder, graph = graph
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        render = RenderState(running: true, status: "Starting…")
        renderTask = Task { [weak self] in
            let ev = Evaluator(limit: 24)
            var saved: [URL] = [], failures: [String] = []
            let n = Double(exports.count)
            for (i, node) in exports.enumerated() {
                guard let self, !Task.isCancelled, let kind = kind(node), let export = kind.export else { break }
                let title = kind.title
                render.status = exports.count > 1 ? "\(title) · \(i + 1) of \(exports.count)" : title
                let params = Params(values: node.params, kind: kind)
                let target = ExportTarget(folder: folder) { p in
                    Task { @MainActor in self.render.progress = (Double(i) + min(1, p)) / n }
                }
                let job = Task.detached(priority: .userInitiated) { () throws -> [URL] in
                    let v = try await ev.value(of: node.id, in: graph, preview: false, maxDimension: 0) { _, p, status in
                        Task { @MainActor in
                            self.render.status = status
                            self.render.progress = (Double(i) + min(1, p) * 0.5) / n
                        }
                    }
                    return try await export(v, params, target)
                }
                do {
                    let urls = try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
                    saved += urls
                    lastResults[node.id] = urls
                } catch is CancellationError {
                    break
                } catch is UpstreamError {
                    failures.append("\(title): a node before it has a problem")
                } catch {
                    failures.append("\(title): \(error.localizedDescription)")
                }
                render.progress = Double(i + 1) / n
            }
            guard let self else { return }
            let cancelled = Task.isCancelled
            render = RenderState(running: false, progress: 1,
                                 status: cancelled ? "Cancelled" : saved.isEmpty ? "Nothing saved" : "Saved \(saved.count) file\(saved.count == 1 ? "" : "s")",
                                 saved: saved, failures: failures, finished: true)
            renderTask = nil
            if !saved.isEmpty, UserDefaults.standard.bool(forKey: "revealAfterRender") {
                NSWorkspace.shared.activateFileViewerSelecting(saved)
            }
        }
    }

    func cancelRender() {
        renderTask?.cancel()
    }

    func dismissRenderResult() {
        if !render.running { render = RenderState() }
    }
}
