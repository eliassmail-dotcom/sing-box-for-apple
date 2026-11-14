import Foundation

/// Counts unique leaf outbounds with a successful recorded URLTest delay.
/// Group outbounds (selector / urltest) are containers, never counted as nodes.
/// The result describes the last known probe results, not an active connectivity check.
public struct ModeLatencyItem: Hashable {
    public let tag: String
    public let delayMs: UInt16

    public init(tag: String, delayMs: UInt16) {
        self.tag = tag
        self.delayMs = delayMs
    }
}

public struct ModeLatencyGroup: Hashable {
    public let tag: String
    public let members: [ModeLatencyItem]

    public init(tag: String, members: [ModeLatencyItem]) {
        self.tag = tag
        self.members = members
    }
}

public enum ModeRespondingNodeCounter {
    public static func count(rootTag: String, groups: [ModeLatencyGroup]) -> Int {
        let groupsByTag = Dictionary(groups.map { ($0.tag, $0) }, uniquingKeysWith: { first, _ in first })
        var visitedGroups = Set<String>()
        var respondingNodes = Set<String>()

        func visit(_ tag: String) {
            guard visitedGroups.insert(tag).inserted,
                  let group = groupsByTag[tag] else { return }
            for item in group.members {
                if groupsByTag[item.tag] != nil {
                    visit(item.tag)
                } else if item.delayMs > 0 {
                    respondingNodes.insert(item.tag)
                }
            }
        }

        visit(rootTag)
        return respondingNodes.count
    }
}
