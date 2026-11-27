import Foundation

/// UI-only group presentation preferences. These never change sing-box outbounds.
public struct GroupPresentationSettings: Codable, Equatable {
    public var order: [String] = []
    public var hidden: Set<String> = []

    public init() {}

    public func orderedTags(available: [String]) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        let availableSet = Set(available)
        for tag in order where availableSet.contains(tag) {
            if seen.insert(tag).inserted { result.append(tag) }
        }
        for tag in available {
            if seen.insert(tag).inserted { result.append(tag) }
        }
        return result
    }

    public func visibleTags(available: [String]) -> [String] {
        orderedTags(available: available).filter { !hidden.contains($0) }
    }

    public func isVisible(_ tag: String) -> Bool {
        !hidden.contains(tag)
    }

    public mutating func setVisible(_ visible: Bool, for tag: String) {
        if visible { hidden.remove(tag) }
        else { hidden.insert(tag) }
    }

    public mutating func setOrder(_ tags: [String]) {
        var unique: [String] = []
        var seen = Set<String>()
        for tag in tags where seen.insert(tag).inserted {
            unique.append(tag)
        }
        // Preserve the relative order of saved tags absent from the current profile.
        for tag in order where seen.insert(tag).inserted {
            unique.append(tag)
        }
        order = unique
    }

    // Provider-generated logical nodes use a named URLTest with two numbered
    // VLESS variants. Require the exact generator parent graph as well as the
    // numbered leaves; never infer a pair from a name alone. This is UI-only:
    // raw groups remain available to routing, diagnostics and the command client.
    private static func providerPairTags(
        groups: [(tag: String, type: String, members: [String])],
        leafTypes: [String: String]
    ) -> Set<String> {
        let byTag = Dictionary(groups.map { ($0.tag, $0) }, uniquingKeysWith: { first, _ in first })
        func isVariant(_ member: String, of tag: String) -> Bool {
            let prefix = tag.lowercased() + " #"
            let normalized = member.lowercased()
            guard normalized.hasPrefix(prefix),
                  let number = Int(normalized.dropFirst(prefix.count)), number > 0 else { return false }
            return leafTypes[member]?.lowercased() == "vless"
        }
        return Set(groups.compactMap { group -> String? in
            guard group.type == "urltest", group.members.count == 2,
                  Set(group.members).count == 2,
                  group.members.allSatisfy({ isVariant($0, of: group.tag) }) else { return nil }
            let parents = group.tag.hasPrefix("Ru 🔗 ") ? ["Ru 🔗 Авто", "Ru 🔗 Ручной"] : ["Авто · Базовая", "Стратегия"]
            guard parents.allSatisfy({ parent in
                guard let members = byTag[parent]?.members else { return false }
                return members.contains(group.tag) && !group.members.contains(where: members.contains)
            }) else { return nil }
            return group.tag
        })
    }

    public static func providerPairTags(in groups: [OutboundGroup]) -> Set<String> {
        let leafTypes = Dictionary(groups.flatMap { $0.items.map { ($0.tag, $0.type) } }, uniquingKeysWith: { first, _ in first })
        return providerPairTags(groups: groups.map { ($0.tag, $0.type, $0.items.map(\.tag)) }, leafTypes: leafTypes)
    }

    /// Only the presentation is projected. A logical node keeps its real tag
    /// for selection and manual tests, with the selected variant's delay.
    public func displayedGroups(_ groups: [OutboundGroup]) -> [OutboundGroup] {
        let pairs = Self.providerPairTags(in: groups)
        let byTag = Dictionary(groups.map { ($0.tag, $0) }, uniquingKeysWith: { first, _ in first })
        let tags = visibleTags(available: groups.map(\.tag).filter { !pairs.contains($0) })
        return tags.compactMap { tag in
            guard var group = byTag[tag] else { return nil }
            group.items = group.items.map { item in
                guard pairs.contains(item.tag), let pair = byTag[item.tag] else { return item }
                let active = pair.items.first { $0.tag == pair.selected }
                return OutboundGroupItem(tag: item.tag, type: "vless",
                                         urlTestTime: active?.urlTestTime ?? item.urlTestTime,
                                         urlTestDelay: active?.urlTestDelay ?? item.urlTestDelay)
            }
            return group
        }
    }

    public static func providerPairTags(inConfigOutbounds outbounds: [[String: Any]]) -> Set<String> {
        let definitions = outbounds.compactMap { item -> (tag: String, type: String, members: [String])? in
            guard let tag = item["tag"] as? String, let type = item["type"] as? String else { return nil }
            return (tag, type, item["outbounds"] as? [String] ?? [])
        }
        let types = Dictionary(definitions.map { ($0.tag, $0.type) }, uniquingKeysWith: { first, _ in first })
        return providerPairTags(groups: definitions, leafTypes: types)
    }

    /// Offline fallback when CommandClient has not connected.
    public static func tagsFromConfig(_ source: String) -> [String] {
        guard let root = (try? JSONSerialization.jsonObject(with: Data(source.utf8))) as? [String: Any],
              let outbounds = root["outbounds"] as? [[String: Any]] else { return [] }
        let pairs = providerPairTags(inConfigOutbounds: outbounds)
        var result: [String] = []
        var seen = Set<String>()
        for outbound in outbounds {
            guard let type = outbound["type"] as? String,
                  ["selector", "urltest"].contains(type),
                  let tag = outbound["tag"] as? String, !tag.isEmpty, !pairs.contains(tag) else { continue }
            if seen.insert(tag).inserted { result.append(tag) }
        }
        return result
    }
}

public struct GroupPresentationStore: Codable, Equatable {
    public var profiles: [String: GroupPresentationSettings] = [:]
    public init() {}

    public static func decode(_ json: String) throws -> Self {
        guard !json.isEmpty else { return Self() }
        return try JSONDecoder().decode(Self.self, from: Data(json.utf8))
    }

    public func encode() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}

public extension Notification.Name {
    static let groupPresentationChanged = Notification.Name("groupPresentationChanged")
}
