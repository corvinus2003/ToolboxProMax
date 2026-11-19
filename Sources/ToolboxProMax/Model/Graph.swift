import Foundation
import CoreGraphics

enum ParamValue: Codable, Hashable {
    case number(Double)
    case bool(Bool)
    case text(String)
    case files([String])

    var fingerprint: String {
        switch self {
        case .number(let v): "n\(v)"
        case .bool(let v): "b\(v)"
        case .text(let v): "t\(v)"
        case .files(let v): "f\(v.joined(separator: "|"))"
        }
    }
}

struct Node: Codable, Identifiable, Hashable {
    var id = UUID()
    var kind: String
    var position: CGPoint
    var params: [String: ParamValue] = [:]
}

struct Edge: Codable, Identifiable, Hashable {
    var id = UUID()
    var from: UUID
    var to: UUID
    var toPort: Int
}

struct Graph: Codable, Hashable {
    var nodes: [Node] = []
    var edges: [Edge] = []

    func node(_ id: UUID) -> Node? { nodes.first { $0.id == id } }

    func edge(into node: UUID, port: Int) -> Edge? {
        edges.first { $0.to == node && $0.toPort == port }
    }

    /// True if `target` can be reached by walking downstream from `source`.
    func reaches(from source: UUID, to target: UUID) -> Bool {
        var stack = [source], seen = Set<UUID>()
        while let n = stack.popLast() {
            if n == target { return true }
            guard seen.insert(n).inserted else { continue }
            stack += edges.filter { $0.from == n }.map(\.to)
        }
        return false
    }
}

/// Typed access to a node's parameters, falling back to the defaults declared in its NodeKind.
struct Params {
    let values: [String: ParamValue]
    let kind: NodeKind

    private func raw(_ key: String) -> ParamValue? {
        values[key] ?? kind.params.first { $0.key == key }?.defaultValue
    }

    func number(_ key: String) -> Double {
        if case .number(let v) = raw(key) { return v }
        return 0
    }
    func int(_ key: String) -> Int { Int(number(key).rounded()) }
    func bool(_ key: String) -> Bool {
        if case .bool(let v) = raw(key) { return v }
        return false
    }
    func string(_ key: String) -> String {
        if case .text(let v) = raw(key) { return v }
        return ""
    }
    func files(_ key: String) -> [URL] {
        if case .files(let v) = raw(key) { return v.map { URL(fileURLWithPath: $0) } }
        return []
    }
}
