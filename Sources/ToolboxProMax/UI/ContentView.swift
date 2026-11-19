import SwiftUI

struct ContentView: View {
    @Environment(GraphStore.self) private var store
    @State private var showInspector = true
    @State private var columns = NavigationSplitViewVisibility.all

    var body: some View {
        @Bindable var store = store
        NavigationSplitView(columnVisibility: $columns) {
            LibraryView()
                .navigationSplitViewColumnWidth(min: 230, ideal: 270, max: 340)
        } detail: {
            CanvasView()
                .overlay(alignment: .bottomLeading) { ZoomControls().padding(16) }
                .overlay(alignment: .bottom) { RenderHUD().padding(.bottom, 18) }
                .inspector(isPresented: $showInspector) {
                    InspectorView()
                        .inspectorColumnWidth(min: 300, ideal: 350, max: 520)
                }
        }
        .navigationTitle("Toolbox Pro Max")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    ForEach(Workflow.all) { w in
                        Button(w.title, systemImage: w.symbol) { store.insert(w) }
                    }
                } label: {
                    Label("Workflows", systemImage: "square.stack.3d.down.right")
                }
                .help("Drop a ready-made chain into the graph")

                if store.render.running {
                    Button(role: .cancel) { store.cancelRender() } label: {
                        Label("Cancel", systemImage: "stop.fill")
                    }
                    .help("Stop rendering (⌘.)")
                } else {
                    Button { store.startRender() } label: {
                        Label("Render", systemImage: "play.fill")
                    }
                    .buttonStyle(.glassProminent)
                    .help("Run everything at full size and save the files (⌘R)")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button { showInspector.toggle() } label: {
                    Label("Inspector", systemImage: "sidebar.trailing")
                }
                .help("Show or hide the inspector")
            }
        }
        .sheet(isPresented: $store.showWelcome) {
            WelcomeView()
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleInspector)) { _ in showInspector.toggle() }
    }

    private var subtitle: String {
        let n = store.graph.nodes.count
        if n == 0 { return "Empty graph" }
        let e = store.exportNodes.count
        return "\(n) node\(n == 1 ? "" : "s") · \(e) export\(e == 1 ? "" : "s")"
    }
}

extension Notification.Name {
    static let toggleInspector = Notification.Name("toggleInspector")
}

struct ZoomControls: View {
    @Environment(GraphStore.self) private var store

    var body: some View {
        HStack(spacing: 2) {
            Button { store.zoom(by: 1 / 1.25) } label: { Image(systemName: "minus") }
                .help("Zoom out (⌘−)")
            Button { store.actualSize() } label: {
                Text("\(Int((store.zoom * 100).rounded()))%").monospacedDigit().frame(minWidth: 44)
            }
            .help("Actual size (⌘0)")
            Button { store.zoom(by: 1.25) } label: { Image(systemName: "plus") }
                .help("Zoom in (⌘+)")
            Divider().frame(height: 16).padding(.horizontal, 4)
            Button { store.zoomToFit() } label: { Image(systemName: "arrow.up.left.and.down.right.magnifyingglass") }
                .help("Zoom to fit (⌘9)")
        }
        .buttonStyle(.borderless)
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .glassEffect(.regular, in: .capsule)
    }
}

struct RenderHUD: View {
    @Environment(GraphStore.self) private var store

    var body: some View {
        Group {
            if store.render.running {
                HStack(spacing: 14) {
                    ProgressView(value: store.render.progress)
                        .frame(width: 180)
                    Text(store.render.status)
                        .font(.callout)
                        .lineLimit(1)
                        .frame(maxWidth: 260, alignment: .leading)
                    Button("Cancel") { store.cancelRender() }
                        .buttonStyle(.glass)
                }
                .padding(.horizontal, 18).padding(.vertical, 12)
                .glassEffect(.regular, in: .capsule)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if store.render.finished {
                HStack(spacing: 12) {
                    Image(systemName: store.render.failures.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.title2)
                        .foregroundStyle(store.render.failures.isEmpty ? .green : .orange)
                        .symbolEffect(.bounce, value: store.render.finished)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(store.render.status).font(.headline)
                        if let f = store.render.failures.first {
                            Text(f).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        } else if let first = store.render.saved.first {
                            Text(first.deletingLastPathComponent().path(percentEncoded: false)).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.head)
                        }
                    }
                    .frame(maxWidth: 320, alignment: .leading)
                    if !store.render.saved.isEmpty {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(store.render.saved) }
                            .buttonStyle(.glassProminent)
                    }
                    Button { withAnimation(.snappy) { store.dismissRenderResult() } } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 18).padding(.vertical, 12)
                .glassEffect(.regular, in: .capsule)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: store.render.saved) {
                    try? await Task.sleep(for: .seconds(12))
                    withAnimation(.snappy) { store.dismissRenderResult() }
                }
            }
        }
        .animation(.snappy, value: store.render.running)
        .animation(.snappy, value: store.render.finished)
    }
}
