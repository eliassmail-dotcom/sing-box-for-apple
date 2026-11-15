#if os(iOS)
import Foundation

/// Pure combinator for future user-defined node collections.
/// Preserves explicit order, expands nested collections, applies per-group
/// include/exclude filters and never mutates a sing-box config.
enum StudioNodeGroupComposer {
    struct Definition {
        let id: String
        let members: [String]       // explicit nodes or referenced group names
        let include: [String]       // case-insensitive fragments of node titles
        let exclude: [String]
    }
    struct Result {
        let nodes: [String]
        let missing: [String]
        let cycles: [String]
    }

    static func resolve(group: String, definitions: [Definition],
                        knownTags: [String], filterableNodes: [String]) -> Result {
        let byName = Dictionary(definitions.map { ($0.id, $0) },
                                uniquingKeysWith: { first, _ in first })
        let available = Set(knownTags)
        var missing = Set<String>()
        var cycles = Set<String>()

        func matches(_ node: String, patterns: [String]) -> Bool {
            patterns.contains { fragment in
                let normalized = fragment.trimmingCharacters(in: .whitespacesAndNewlines)
                return !normalized.isEmpty && node.range(of: normalized,
                      options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
        func unique(_ values: [String]) -> [String] {
            var seen = Set<String>()
            return values.filter { seen.insert($0).inserted }
        }
        func walk(_ id: String, path: Set<String>) -> [String] {
            if path.contains(id) {
                cycles.insert(id)
                return []
            }
            guard let item = byName[id] else {
                if available.contains(id) { return [id] }
                missing.insert(id)
                return []
            }
            let nextPath = path.union([id])
            var members: [String] = []
            for child in item.members {
                members.append(contentsOf: walk(child, path: nextPath))
            }
            if !item.include.isEmpty {
                members.append(contentsOf: filterableNodes.filter { matches($0, patterns: item.include) })
            }
            if !item.exclude.isEmpty {
                members.removeAll { matches($0, patterns: item.exclude) }
            }
            return unique(members)
        }
        return Result(nodes: walk(group, path: []),
                      missing: missing.sorted(), cycles: cycles.sorted())
    }
}
#endif
