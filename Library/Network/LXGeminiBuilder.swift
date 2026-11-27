import Foundation

/// Builds the effective Gemini routing graph on-device. Yandex supplies only
/// the Gemini+ source pool; the imported subscription is never modified.
public enum LXGeminiBuilder {
    private static let sourceTag = "Gemini+"
    private static let rootTag = "Gemini"
    private static let directTag = "Gemini • Авто"
    private static let manualTag = "Gemini • Выбор"
    private static let mixedTag = "Gemini • Super • A"
    private static let chainGroupTag = "Gemini • Chain • A"
    private static let chainPrefix = "LX • Gemini • Chain • "
    private static let maxDepth = 12

    private static let eligibleLeafTypes: Set<String> = [
        "vless", "vmess", "trojan", "shadowsocks", "hysteria2", "tuic", "anytls",
        "shadowtls", "socks", "http", "ssh", "wireguard"
    ]

    /// True when this imported profile provides a source pool, independent of
    /// the Gemini selector/groups made by older versions of the generator.
    public static func hasSource(_ root: [String: Any]) -> Bool {
        guard let outbounds = root["outbounds"] as? [[String: Any]] else { return false }
        return outbounds.contains { ($0["tag"] as? String) == sourceTag &&
            ["urltest", "selector"].contains($0["type"] as? String ?? "") }
    }

    public static func hasSource(_ content: String) -> Bool {
        guard let data = content.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return false }
        return hasSource(root)
    }

    /// Returns false only for legacy profiles with no Gemini+ source.
    /// All generated names are stable; calling again replaces their definitions.
    @discardableResult
    public static func apply(to root: inout [String: Any], chainsEnabled: Bool) throws -> Bool {
        guard var outbounds = root["outbounds"] as? [[String: Any]],
              let source = outbounds.first(where: { ($0["tag"] as? String) == sourceTag &&
                  ["urltest", "selector"].contains($0["type"] as? String ?? "") })
        else {
            if chainsEnabled {
                throw LXProfileOverrides.OverrideError.invalidOption(
                    "Gemini Chains требует исходную группу Gemini+"
                )
            }
            return false
        }

        let byTag = Dictionary(outbounds.compactMap { item -> (String, [String: Any])? in
            guard let tag = item["tag"] as? String else { return nil }
            return (tag, item)
        }, uniquingKeysWith: { first, _ in first })
        var directNodes: [String] = []
        var seenLeaves: Set<String> = []
        try flattenMembers(of: source, byTag: byTag, ancestors: [sourceTag],
                           depth: 0, output: &directNodes, seen: &seenLeaves)
        guard !directNodes.isEmpty else {
            throw LXProfileOverrides.OverrideError.invalidOption(
                "в Gemini+ нет ни одного поддерживаемого конечного узла"
            )
        }

        if chainsEnabled && !outbounds.contains(where: {
            ($0["tag"] as? String) == "Стратегия" && ($0["type"] as? String) == "selector"
        }) {
            throw LXProfileOverrides.OverrideError.invalidOption(
                "Gemini Chains требует селектор Стратегия"
            )
        }

        // Preserve the health-check endpoints and timing from the source pool,
        // without introducing new public probe domains or touching the DNS tree.
        var healthFields: [String: Any] = [:]
        for key in ["url", "urls", "interval", "idle_timeout", "tolerance"] {
            if let value = source[key] { healthFields[key] = value }
        }

        func urlTest(_ tag: String, members: [String]) -> [String: Any] {
            var result = healthFields
            result["type"] = "urltest"
            result["tag"] = tag
            result["outbounds"] = members
            result["mode"] = "least_test"
            result["interrupt_exist_connections"] = false
            return result
        }

        var chainNames: [String] = []
        if chainsEnabled {
            for sourceLeaf in directNodes {
                let name = chainPrefix + sourceLeaf
                chainNames.append(name)
            }
        }

        let manualMembers = directNodes + chainNames
        var geminiRoot: [String: Any] = [
            "type": "selector",
            "tag": rootTag,
            "outbounds": [mixedTag, directTag, manualTag] +
                (chainsEnabled ? [chainGroupTag] : []),
            "default": mixedTag,
            "interrupt_exist_connections": false,
        ]
        // Preserve any unrelated selector metadata if it is already present.
        if let oldRoot = byTag[rootTag], oldRoot["type"] as? String == "selector" {
            for field in ["exclude", "include", "icon"] {
                if let value = oldRoot[field] { geminiRoot[field] = value }
            }
        }

        let generated: [[String: Any]] = [
            geminiRoot,
            urlTest(directTag, members: directNodes),
            urlTest(mixedTag, members: manualMembers),
            [
                "type": "selector",
                "tag": manualTag,
                "outbounds": manualMembers,
                "default": directNodes[0],
                "interrupt_exist_connections": false,
            ],
        ] + (chainsEnabled
            ? [urlTest(chainGroupTag, members: chainNames)]
            : []) + zip(chainNames, directNodes).map { name, leaf in
                [
                    "type": "chain",
                    "tag": name,
                    // The LX chain engine resolves the selected Strategy leaf
                    // at DIAL TIME. No fixed first-hop node or reload required.
                    "outbounds": ["Стратегия", leaf],
                    "idle_timeout": "5m",
                    "interrupt_exist_connections": false,
                ] as [String: Any]
            }

        // Replacing the old Gemini-facing groups makes the app authoritative,
        // while keeping generator-owned legacy groups that may be referenced
        // elsewhere. Unused LX-generated chain definitions are removed.
        let replacedTags: Set<String> = [rootTag, directTag, manualTag, mixedTag, chainGroupTag]
        outbounds.removeAll { item in
            guard let tag = item["tag"] as? String else { return false }
            return replacedTags.contains(tag) || tag.hasPrefix(chainPrefix)
        }
        let retainedTags = Set(outbounds.compactMap { $0["tag"] as? String })
        for item in generated {
            if let tag = item["tag"] as? String, retainedTags.contains(tag) {
                throw LXProfileOverrides.OverrideError.invalidOption(
                    "конфликт имени Gemini outbound: \(tag)"
                )
            }
        }
        outbounds.append(contentsOf: generated)
        root["outbounds"] = outbounds
        return true
    }

    private static func flattenMembers(
        of item: [String: Any],
        byTag: [String: [String: Any]],
        ancestors: Set<String>,
        depth: Int,
        output: inout [String],
        seen: inout Set<String>
    ) throws {
        guard depth < maxDepth else {
            throw LXProfileOverrides.OverrideError.invalidOption(
                "слишком глубокая вложенность Gemini+"
            )
        }
        guard let members = item["outbounds"] as? [String] else {
            throw LXProfileOverrides.OverrideError.invalidOption(
                "Gemini+ не содержит корректного списка узлов"
            )
        }
        for member in members {
            guard let node = byTag[member], let type = node["type"] as? String else {
                throw LXProfileOverrides.OverrideError.invalidOption(
                    "Gemini+: отсутствует outbound \(member)"
                )
            }
            if type == "urltest" || type == "selector" {
                guard !ancestors.contains(member) else {
                    throw LXProfileOverrides.OverrideError.invalidOption(
                        "Gemini+: цикл вложенных групп"
                    )
                }
                try flattenMembers(of: node, byTag: byTag,
                                   ancestors: ancestors.union([member]),
                                   depth: depth + 1, output: &output, seen: &seen)
            } else if eligibleLeafTypes.contains(type), seen.insert(member).inserted {
                output.append(member)
            }
        }
    }
}
