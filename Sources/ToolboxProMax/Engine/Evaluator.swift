import AppKit
import Foundation

/// Raised when a node can't run because something before it failed.
struct UpstreamError: LocalizedError {
    var errorDescription: String? { "Waiting on the node before this one" }
}

/// Runs a graph. Results are cached by a fingerprint of the node, its settings and everything upstream,
/// so moving one slider only recomputes the nodes after it.
final class Evaluator: @unchecked Sendable {
    private var cache: [Int: Value] = [:]
    private var order: [Int] = []
    private let lock = NSLock()
    private let limit: Int

    init(limit: Int = 160) { self.limit = limit }

    func invalidate() {
        lock.lock(); cache.removeAll(); order.removeAll(); lock.unlock()
    }

    func fingerprint(_ id: UUID, in graph: Graph, preview: Bool, seen: Set<UUID> = []) -> Int {
        var h = Hasher()
        h.combine(preview)
        guard let node = graph.node(id), let kind = NodeKind.named(node.kind), !seen.contains(id) else { return h.finalize() }
        h.combine(node.kind)
        for key in node.params.keys.sorted() { h.combine(key); h.combine(node.params[key]!.fingerprint) }
        for port in kind.inputs.indices {
            if let e = graph.edge(into: id, port: port) {
                h.combine(port)
                h.combine(fingerprint(e.from, in: graph, preview: preview, seen: seen.union([id])))
            }
        }
        return h.finalize()
    }

    private func lookup(_ key: Int) -> Value? {
        lock.lock(); defer { lock.unlock() }
        return cache[key]
    }

    private func store(_ key: Int, _ value: Value) {
        lock.lock(); defer { lock.unlock() }
        if cache[key] == nil { order.append(key) }
        cache[key] = value
        while order.count > limit { cache.removeValue(forKey: order.removeFirst()) }
    }

    func value(of id: UUID, in graph: Graph, preview: Bool, maxDimension: CGFloat,
               progress: @escaping (UUID, Double, String) -> Void = { _, _, _ in }) async throws -> Value {
        let key = fingerprint(id, in: graph, preview: preview)
        if let hit = lookup(key) { return hit }
        guard let node = graph.node(id), let kind = NodeKind.named(node.kind) else { throw ToolError("Unknown node") }

        var inputs: [Value?] = []
        for port in kind.inputs.indices {
            try Task.checkCancellation()
            guard let e = graph.edge(into: id, port: port) else { inputs.append(nil); continue }
            do {
                inputs.append(try await value(of: e.from, in: graph, preview: preview, maxDimension: maxDimension, progress: progress))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw UpstreamError()
            }
        }
        try Task.checkCancellation()
        let ctx = EvalContext(preview: preview, maxDimension: maxDimension, nodeID: id) { progress(id, $0, $1) }
        let result = try await kind.evaluate(inputs, Params(values: node.params, kind: kind), ctx)
        store(key, result)
        return result
    }
}

/// What the UI shows for a node's output.
struct PreviewPayload {
    enum Content {
        case image(NSImage)
        case images([NSImage], count: Int)
        case video(NSImage, duration: Double)
        case audio(waveform: [Float], clip: AudioClip)
        case pdf([NSImage], count: Int)
        case text(String)
    }

    var content: Content
    var info: String
    var type: PortType

    static func make(_ value: Value, maxDimension: CGFloat, fraction: Double, pages: Int = 1) async throws -> PreviewPayload {
        switch value {
        case .image(let i):
            guard let img = CI.thumbnail(i.image, maxDimension: maxDimension) else { throw ToolError("The picture is empty") }
            return PreviewPayload(content: .image(img), info: sizeText(i), type: .image)
        case .images(let list):
            let thumbs = list.prefix(max(pages, 4)).compactMap { CI.thumbnail($0.image, maxDimension: maxDimension / 2) }
            let info = list.count == 1 ? "1 image" : "\(list.count) images"
            return PreviewPayload(content: .images(thumbs, count: list.count), info: info + (list.first.map { " · " + sizeText($0) } ?? ""), type: .images)
        case .video(let clip):
            let (duration, _) = try await VideoOps.info(clip.url)
            let (s, e) = VideoOps.range(clip, duration: duration)
            let frame = try await VideoOps.frame(clip, fraction: fraction, maxDimension: maxDimension)
            guard let img = CI.thumbnail(frame.image, maxDimension: maxDimension) else { throw ToolError("No picture in this clip") }
            return PreviewPayload(content: .video(img, duration: e - s), info: "\(sizeText(frame)) · \(time(e - s))", type: .video)
        case .audio(let clip):
            let ch = clip.buffer.format.channelCount
            let info = "\(time(clip.duration)) · \(Int(clip.buffer.format.sampleRate / 1000)) kHz · \(ch == 1 ? "mono" : ch == 2 ? "stereo" : "\(ch) ch")"
            return PreviewPayload(content: .audio(waveform: AudioOps.waveform(clip, bins: 240), clip: clip), info: info, type: .audio)
        case .pdf(let doc, _):
            var thumbs: [NSImage] = []
            for i in 0..<min(doc.pageCount, pages) {
                if let page = doc.page(at: i) { thumbs.append(page.thumbnail(of: NSSize(width: maxDimension, height: maxDimension), for: .cropBox)) }
            }
            return PreviewPayload(content: .pdf(thumbs, count: doc.pageCount),
                                  info: doc.pageCount == 1 ? "1 page" : "\(doc.pageCount) pages", type: .pdf)
        case .text(let s):
            let words = s.split(whereSeparator: \.isWhitespace).count
            return PreviewPayload(content: .text(s), info: "\(words) words · \(s.count) characters", type: .text)
        }
    }

    static func sizeText(_ i: NamedImage) -> String {
        let s = max(i.scale, 0.0001)
        return "\(Int((i.image.extent.width / s).rounded())) × \(Int((i.image.extent.height / s).rounded()))"
    }

    static func time(_ t: Double) -> String {
        guard t.isFinite else { return "–" }
        let total = Int(t.rounded())
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }
}
