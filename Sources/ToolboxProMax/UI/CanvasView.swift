import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct CanvasView: View {
    @Environment(GraphStore.self) private var store
    @State private var panStart: CGSize?
    @State private var dropTargeted = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                DotGrid(offset: store.offset, zoom: store.zoom)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 2)
                            .onChanged { v in
                                if panStart == nil { panStart = store.offset }
                                store.offset = CGSize(width: panStart!.width + v.translation.width,
                                                      height: panStart!.height + v.translation.height)
                            }
                            .onEnded { _ in panStart = nil; store.pan(by: .zero) }
                    )
                    .onTapGesture { store.selection = nil }

                WiresLayer()
                    .allowsHitTesting(false)

                ForEach(store.graph.nodes) { node in
                    if let kind = store.kind(node) {
                        NodeView(node: node, kind: kind)
                            .frame(width: NodeLayout.width, height: NodeLayout(kind).height)
                            .scaleEffect(store.zoom, anchor: .topLeading)
                            .offset(x: node.position.x * store.zoom + store.offset.width,
                                    y: node.position.y * store.zoom + store.offset.height)
                            .zIndex(store.selection == node.id ? 1 : 0)
                    }
                }

                if store.graph.nodes.isEmpty {
                    EmptyCanvas()
                        .frame(width: geo.size.width, height: geo.size.height)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .coordinateSpace(.named("canvas"))
            .clipped()
            .background(ScrollAndPinch())
            .overlay {
                if dropTargeted {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                        .padding(10)
                        .allowsHitTesting(false)
                }
            }
            .onDrop(of: [.fileURL, .utf8PlainText, .plainText], isTargeted: $dropTargeted) { providers, location in
                handleDrop(providers, at: location)
            }
            .onAppear { store.canvasSize = geo.size }
            .onChange(of: geo.size) { _, s in store.canvasSize = s }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private func handleDrop(_ providers: [NSItemProvider], at location: CGPoint) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in store.addFiles([url], at: location) }
                }
            } else if provider.canLoadObject(ofClass: String.self) {
                handled = true
                _ = provider.loadObject(ofClass: String.self) { text, _ in
                    guard let text, text.hasPrefix("tpm-node:") else { return }
                    let id = String(text.dropFirst("tpm-node:".count))
                    Task { @MainActor in
                        let p = store.toCanvas(location)
                        store.add(id, at: CGPoint(x: p.x - NodeLayout.width / 2, y: p.y - 20))
                    }
                }
            }
        }
        return handled
    }
}

struct DotGrid: View {
    let offset: CGSize
    let zoom: CGFloat

    var body: some View {
        Canvas { ctx, size in
            var step = 24 * zoom
            while step < 12 { step *= 2 }
            let r: CGFloat = max(0.8, min(1.4, zoom * 1.1))
            let ox = offset.width.truncatingRemainder(dividingBy: step), oy = offset.height.truncatingRemainder(dividingBy: step)
            var path = Path()
            var y = oy - step
            while y < size.height + step {
                var x = ox - step
                while x < size.width + step {
                    path.addEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
                    x += step
                }
                y += step
            }
            ctx.fill(path, with: .color(.primary.opacity(0.13)))
        }
    }
}

struct WiresLayer: View {
    @Environment(GraphStore.self) private var store

    var body: some View {
        // Work out every path here in `body`, where Observation sees what we read. The Canvas closure runs
        // later, outside tracking, so reading the store in there would leave the wires stale after a zoom.
        let zoom = store.zoom
        let width = max(1.6, min(3.2, 2.6 * zoom))
        let wires: [(Path, Color)] = store.graph.edges.compactMap { edge in
            guard let from = store.graph.node(edge.from), let to = store.graph.node(edge.to) else { return nil }
            let a = store.toScreen(store.outputPoint(from)), b = store.toScreen(store.inputPoint(to, edge.toPort))
            return (wirePath(a, b, zoom: zoom), (store.outputType(edge.from) ?? .visual).color)
        }
        var pending: (Path, Color, Bool)?
        if let w = store.wire {
            let target = store.snapTarget().flatMap { t in store.graph.node(t.0).map { store.toScreen(store.inputPoint($0, t.1)) } }
            pending = (wirePath(w.start, target ?? w.current, zoom: zoom), w.type.color, target != nil)
        }
        return Canvas { ctx, _ in
            for (path, color) in wires {
                ctx.stroke(path, with: .color(color.opacity(0.25)), style: StrokeStyle(lineWidth: width * 3, lineCap: .round))
                ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round))
            }
            if let (path, color, snapped) = pending {
                ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, dash: snapped ? [] : [6, 5]))
            }
        }
    }

    private func wirePath(_ a: CGPoint, _ b: CGPoint, zoom: CGFloat) -> Path {
        var p = Path()
        p.move(to: a)
        let dx = max(50 * zoom, abs(b.x - a.x) * 0.5)
        p.addCurve(to: b, control1: CGPoint(x: a.x + dx, y: a.y), control2: CGPoint(x: b.x - dx, y: b.y))
        return p
    }
}

/// Two-finger scroll pans, pinch or ⌘-scroll zooms. SwiftUI has no scroll-wheel gesture on the Mac,
/// so this watches the events directly.
struct ScrollAndPinch: NSViewRepresentable {
    @Environment(GraphStore.self) private var store

    final class Watcher: NSView {
        var monitor: Any?
        var store: GraphStore?
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] event in
                guard let self, let store = self.store, event.window == self.window else { return event }
                let p = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(p) else { return event }
                MainActor.assumeIsolated {
                    if event.type == .magnify {
                        store.zoom(by: 1 + event.magnification, around: p)
                    } else if event.modifierFlags.contains(.command) {
                        store.zoom(by: exp(event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.01 : 0.08)), around: p)
                    } else {
                        let k: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
                        store.pan(by: CGSize(width: event.scrollingDeltaX * k, height: event.scrollingDeltaY * k))
                    }
                }
                return nil
            }
        }

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }

    func makeNSView(context: Context) -> Watcher {
        let v = Watcher()
        v.store = store
        return v
    }

    func updateNSView(_ nsView: Watcher, context: Context) { nsView.store = store }
}

struct EmptyCanvas: View {
    @Environment(GraphStore.self) private var store

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle().fill(LinearGradient(colors: [.indigo, .purple, .orange], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 84, height: 84)
                    .shadow(color: .purple.opacity(0.35), radius: 18, y: 8)
                Image(systemName: "wand.and.sparkles")
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(.white)
            }
            VStack(spacing: 6) {
                Text("Drop something in")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                Text("Drag photos, videos, sound or PDFs here, pick a tool from the sidebar,\nor start from one of these:")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 10)], spacing: 10) {
                ForEach(Workflow.all.prefix(4)) { w in
                    Button {
                        store.insert(w)
                    } label: {
                        Label(w.title, systemImage: w.symbol)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 2)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                }
            }
            .frame(maxWidth: 500)
        }
        .padding(40)
    }
}
