import SwiftUI

struct NodeView: View {
    @Environment(GraphStore.self) private var store
    let node: Node
    let kind: NodeKind
    @State private var dragStart: CGPoint?
    @State private var hovering = false

    private var layout: NodeLayout { NodeLayout(kind) }
    private var selected: Bool { store.selection == node.id }

    var body: some View {
        ZStack(alignment: .topLeading) {
            card
            ports
        }
        .frame(width: NodeLayout.width, height: layout.height, alignment: .topLeading)
        .onHover { hovering = $0 }
        .gesture(
            DragGesture(minimumDistance: 2, coordinateSpace: .named("canvas"))
                .onChanged { v in
                    if dragStart == nil {
                        dragStart = node.position
                        store.beginMove()
                        store.selection = node.id
                    }
                    store.move(node.id, to: CGPoint(x: dragStart!.x + v.translation.width / store.zoom,
                                                    y: dragStart!.y + v.translation.height / store.zoom))
                }
                .onEnded { _ in dragStart = nil }
        )
        .simultaneousGesture(TapGesture().onEnded { store.selection = node.id })
        .contextMenu {
            Button("Duplicate", systemImage: "plus.square.on.square") { store.duplicate(node.id) }
            Button("Disconnect Inputs", systemImage: "point.topleft.down.to.point.bottomright.curvepath") { store.disconnectInputs(node.id) }
                .disabled(!store.graph.edges.contains { $0.to == node.id })
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) { store.remove(node.id) }
        }
    }

    // MARK: Card

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                IconTile(symbol: kind.symbol, color: kind.category.color, size: 24)
                Text(kind.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                status
            }
            .padding(.horizontal, 10)
            .frame(height: NodeLayout.header)

            Rectangle().fill(.primary.opacity(0.07)).frame(height: 1)

            ZStack(alignment: .topLeading) {
                ForEach(Array(kind.inputs.enumerated()), id: \.offset) { i, port in
                    Text(port.label + (port.optional ? " (optional)" : ""))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(height: NodeLayout.rowHeight)
                        .offset(x: 14, y: NodeLayout.rowHeight * CGFloat(i))
                }
                if kind.output != nil {
                    Text((store.outputType(node.id) ?? kind.output!).label)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .frame(height: NodeLayout.rowHeight)
                        .padding(.trailing, 14)
                }
            }
            .frame(height: CGFloat(layout.rows) * NodeLayout.rowHeight, alignment: .topLeading)
            .padding(.top, 5)

            NodeThumbnail(payload: store.thumbs[node.id], error: store.errors[node.id],
                          waiting: store.waiting.contains(node.id), kind: kind, node: node)
                .frame(height: NodeLayout.thumbHeight)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .padding(.horizontal, 8)
                .padding(.top, 4)
        }
        .frame(width: NodeLayout.width, height: layout.height, alignment: .top)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : .primary.opacity(hovering ? 0.18 : 0.1), lineWidth: selected ? 2 : 1)
        }
        .shadow(color: .black.opacity(selected ? 0.28 : 0.13), radius: selected ? 16 : 7, y: selected ? 8 : 3)
        .animation(.snappy(duration: 0.2), value: selected)
    }

    @ViewBuilder private var status: some View {
        if store.busy.contains(node.id) || store.downloads[node.id] != nil {
            ProgressView().controlSize(.mini)
        } else if store.errors[node.id] != nil {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.system(size: 12))
        } else if kind.isExport, store.lastResults[node.id] != nil {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.system(size: 13))
        } else if kind.live, kind.output != nil, store.thumbs[node.id] != nil {
            Text("LIVE")
                .font(.system(size: 8.5, weight: .bold, design: .rounded))
                .tracking(0.6)
                .foregroundStyle(kind.category.color)
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(kind.category.color.opacity(0.14), in: Capsule())
        }
    }

    // MARK: Ports

    private var ports: some View {
        ZStack(alignment: .topLeading) {
            ForEach(kind.inputs.indices, id: \.self) { i in
                let accepts = kind.inputs[i].accepts
                PortDot(color: accepts.count == 1 ? accepts.first!.color : PortType.visual.color,
                        connected: store.graph.edge(into: node.id, port: i) != nil,
                        highlighted: store.snapTarget().map { $0 == (node.id, i) } ?? false)
                    .position(x: 0, y: layout.inputY(i))
                    .gesture(inputDrag(i))
            }
            if kind.output != nil {
                let type = store.outputType(node.id) ?? kind.possibleOutputs.first ?? .visual
                PortDot(color: type.color, connected: store.graph.edges.contains { $0.from == node.id }, highlighted: false)
                    .position(x: NodeLayout.width, y: layout.outputY)
                    .gesture(outputDrag(type))
            }
        }
        .frame(width: NodeLayout.width, height: layout.height, alignment: .topLeading)
    }

    private func outputDrag(_ type: PortType) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named("canvas"))
            .onChanged { v in
                let start = store.toScreen(store.outputPoint(node))
                let concrete = store.outputType(node.id) ?? (kind.possibleOutputs.count == 1 ? kind.possibleOutputs.first! : .visual)
                store.wire = WireDrag(from: node.id, start: start, current: v.location, type: concrete)
            }
            .onEnded { v in store.finishWire(at: v.location) }
    }

    /// Grabbing a connected input picks the wire up so it can be moved or dropped to disconnect.
    private func inputDrag(_ port: Int) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named("canvas"))
            .onChanged { v in
                if store.wire == nil {
                    guard let e = store.graph.edge(into: node.id, port: port), let src = store.graph.node(e.from) else { return }
                    let type = store.outputType(e.from) ?? .visual
                    store.disconnect(e)
                    store.wire = WireDrag(from: src.id, start: store.toScreen(store.outputPoint(src)), current: v.location, type: type)
                } else {
                    store.wire?.current = v.location
                }
            }
            .onEnded { v in store.finishWire(at: v.location) }
    }
}

struct PortDot: View {
    let color: Color
    let connected: Bool
    let highlighted: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(connected ? color : Color(nsColor: .windowBackgroundColor))
                .overlay(Circle().strokeBorder(color, lineWidth: 2.5))
                .frame(width: highlighted ? 17 : 13, height: highlighted ? 17 : 13)
                .shadow(color: color.opacity(highlighted ? 0.7 : 0), radius: 6)
        }
        .frame(width: 26, height: 26)
        .contentShape(Circle())
        .animation(.snappy(duration: 0.15), value: highlighted)
    }
}

struct NodeThumbnail: View {
    @Environment(GraphStore.self) private var store
    let payload: PreviewPayload?
    let error: String?
    let waiting: Bool
    let kind: NodeKind
    let node: Node

    var body: some View {
        ZStack {
            Rectangle().fill(.primary.opacity(0.045))
            if let download = store.downloads[node.id] {
                VStack(spacing: 6) {
                    ProgressView(value: download.progress).frame(width: 150)
                    Text(download.status).font(.caption2).foregroundStyle(.secondary)
                }
            } else if let error {
                placeholder(error, symbol: "exclamationmark.triangle", tint: .orange)
            } else if waiting {
                placeholder("Waiting on the node before", symbol: "ellipsis", tint: .secondary)
            } else if let payload {
                content(payload)
            } else if kind.inputs.isEmpty == false && store.graph.edge(into: node.id, port: 0) == nil {
                placeholder("Connect an input", symbol: "point.3.connected.trianglepath.dotted", tint: .secondary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }

    private func placeholder(_ text: String, symbol: String, tint: Color) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 18)).foregroundStyle(tint)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .padding(.horizontal, 10)
        }
    }

    @ViewBuilder private func content(_ p: PreviewPayload) -> some View {
        switch p.content {
        case .image(let img), .video(let img, _):
            ZStack {
                Checkerboard(square: 6)
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
            }
            .overlay(alignment: .bottomLeading) { badge(p.info) }
        case .images(let list, let count):
            HStack(spacing: 3) {
                ForEach(Array(list.prefix(3).enumerated()), id: \.offset) { _, img in
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                        .frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
                }
            }
            .overlay(alignment: .bottomLeading) { badge("\(count) images") }
        case .audio(let wave, _):
            WaveformShape(samples: wave, color: .orange).padding(10)
                .overlay(alignment: .bottomLeading) { badge(p.info) }
        case .pdf(let pages, _):
            ZStack {
                if let first = pages.first {
                    Image(nsImage: first).resizable().aspectRatio(contentMode: .fit)
                        .shadow(color: .black.opacity(0.2), radius: 3, y: 1).padding(8)
                }
            }
            .overlay(alignment: .bottomLeading) { badge(p.info) }
        case .text(let s):
            Text(s.isEmpty ? "(empty)" : s)
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(.primary.opacity(0.8))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(8)
                .overlay(alignment: .bottomLeading) { badge(p.info) }
        }
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .medium))
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(6)
    }
}
