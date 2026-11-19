import SwiftUI
import UniformTypeIdentifiers

enum Category: String, CaseIterable, Identifiable {
    case input, image, video, audio, pdf, text, export
    var id: String { rawValue }

    var title: String {
        switch self {
        case .input: "Inputs"
        case .image: "Image"
        case .video: "Video"
        case .audio: "Audio"
        case .pdf: "PDF"
        case .text: "Text"
        case .export: "Export"
        }
    }

    var color: Color {
        switch self {
        case .input: .blue
        case .image: .teal
        case .video: .purple
        case .audio: .orange
        case .pdf: .red
        case .text: .green
        case .export: .gray
        }
    }
}

struct PortSpec {
    let label: String
    let accepts: Set<PortType>
    var optional = false
}

struct ParamSpec {
    enum Control {
        case slider(ClosedRange<Double>, step: Double, unit: String)
        case toggle
        case field(placeholder: String)
        case secure(placeholder: String)
        case textArea
        case choice([(id: String, label: String)])
        case files(types: [UTType], multiple: Bool)
    }

    let key: String
    let label: String
    let control: Control
    let defaultValue: ParamValue
    /// Show this control only when the predicate holds (e.g. "width" only in "Exact size" mode).
    var visible: ((Params) -> Bool)? = nil

    static func slider(_ key: String, _ label: String, _ range: ClosedRange<Double>, step: Double = 1,
                       unit: String = "", _ value: Double, visible: ((Params) -> Bool)? = nil) -> ParamSpec {
        ParamSpec(key: key, label: label, control: .slider(range, step: step, unit: unit),
                  defaultValue: .number(value), visible: visible)
    }
    static func toggle(_ key: String, _ label: String, _ value: Bool, visible: ((Params) -> Bool)? = nil) -> ParamSpec {
        ParamSpec(key: key, label: label, control: .toggle, defaultValue: .bool(value), visible: visible)
    }
    static func field(_ key: String, _ label: String, placeholder: String = "", _ value: String = "",
                      visible: ((Params) -> Bool)? = nil) -> ParamSpec {
        ParamSpec(key: key, label: label, control: .field(placeholder: placeholder), defaultValue: .text(value), visible: visible)
    }
    static func secure(_ key: String, _ label: String, placeholder: String = "") -> ParamSpec {
        ParamSpec(key: key, label: label, control: .secure(placeholder: placeholder), defaultValue: .text(""))
    }
    static func textArea(_ key: String, _ label: String, _ value: String = "") -> ParamSpec {
        ParamSpec(key: key, label: label, control: .textArea, defaultValue: .text(value))
    }
    static func choice(_ key: String, _ label: String, _ options: [(String, String)], _ value: String,
                       visible: ((Params) -> Bool)? = nil) -> ParamSpec {
        ParamSpec(key: key, label: label, control: .choice(options.map { (id: $0.0, label: $0.1) }),
                  defaultValue: .text(value), visible: visible)
    }
    static func files(_ key: String, _ label: String, types: [UTType], multiple: Bool = false) -> ParamSpec {
        ParamSpec(key: key, label: label, control: .files(types: types, multiple: multiple), defaultValue: .files([]))
    }
}

struct EvalContext {
    let preview: Bool
    /// Longest side of working images in previews.
    let maxDimension: CGFloat
    let nodeID: UUID
    var progress: (Double, String) -> Void = { _, _ in }
}

struct ExportTarget {
    let folder: URL
    var progress: (Double) -> Void = { _ in }

    /// A file name in the output folder that doesn't overwrite anything.
    func uniqueURL(_ base: String, ext: String) -> URL {
        let clean = base.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        var url = folder.appendingPathComponent(clean).appendingPathExtension(ext)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(clean) \(n)").appendingPathExtension(ext)
            n += 1
        }
        return url
    }
}

struct NodeKind: Identifiable {
    typealias Evaluate = (_ inputs: [Value?], _ p: Params, _ ctx: EvalContext) async throws -> Value
    typealias Export = (_ value: Value, _ p: Params, _ target: ExportTarget) async throws -> [URL]

    let id: String
    let title: String
    let symbol: String
    let category: Category
    let summary: String
    var inputs: [PortSpec] = []
    /// nil for Export nodes: they end a chain and write files on Render.
    var output: PortType? = nil
    /// For nodes whose output type depends on a setting (Download: video or sound).
    var dynamicOutput: ((Params) -> PortType)? = nil
    var live = true
    var params: [ParamSpec] = []
    let evaluate: Evaluate
    var export: Export? = nil

    var isExport: Bool { export != nil }

    /// Types that can come out of the output port, before anything is connected.
    var possibleOutputs: Set<PortType> {
        guard let output else { return [] }
        if dynamicOutput != nil { return [.video, .audio] }
        if output == .visual, let first = inputs.first { return first.accepts }
        return output.concrete
    }

    func accepts(_ types: Set<PortType>, port: Int) -> Bool {
        guard inputs.indices.contains(port) else { return false }
        return !inputs[port].accepts.isDisjoint(with: types)
    }

    static func named(_ id: String) -> NodeKind? { Catalog.byID[id] }
}
