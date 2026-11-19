import SwiftUI

struct LibraryView: View {
    @Environment(GraphStore.self) private var store
    @State private var search = ""

    private func matches(_ text: String...) -> Bool {
        search.isEmpty || text.contains { $0.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        List {
            let flows = Workflow.all.filter { matches($0.title, $0.summary) }
            if !flows.isEmpty {
                Section("Workflows") {
                    ForEach(flows) { w in
                        LibraryRow(symbol: w.symbol, color: .pink, title: w.title, summary: w.summary)
                            .contentShape(Rectangle())
                            .onTapGesture { store.insert(w) }
                            .help(w.summary)
                    }
                }
            }
            ForEach(Category.allCases) { category in
                let kinds = Catalog.of(category).filter { matches($0.title, $0.summary) }
                if !kinds.isEmpty {
                    Section(category.title) {
                        ForEach(kinds) { kind in
                            LibraryRow(symbol: kind.symbol, color: category.color, title: kind.title, summary: kind.summary)
                                .contentShape(Rectangle())
                                .onTapGesture { store.addAfterSelection(kind.id) }
                                .draggable("tpm-node:\(kind.id)") {
                                    Label(kind.title, systemImage: kind.symbol)
                                        .padding(8)
                                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                                }
                                .help(kind.summary + "\nClick to add after the selected node, or drag onto the canvas.")
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $search, placement: .sidebar, prompt: "Search tools")
    }
}

struct LibraryRow: View {
    let symbol: String
    let color: Color
    let title: String
    let summary: String

    var body: some View {
        HStack(spacing: 10) {
            IconTile(symbol: symbol, color: color, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(summary).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}
