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

    /// Offline fallback when CommandClient has not connected.
    public static func tagsFromConfig(_ source: String) -> [String] {
        guard let root = (try? JSONSerialization.jsonObject(with: Data(source.utf8))) as? [String: Any],
              let outbounds = root["outbounds"] as? [[String: Any]] else { return [] }
        var result: [String] = []
        var seen = Set<String>()
        for outbound in outbounds {
            guard let type = outbound["type"] as? String,
                  ["selector", "urltest"].contains(type),
                  let tag = outbound["tag"] as? String, !tag.isEmpty else { continue }
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
