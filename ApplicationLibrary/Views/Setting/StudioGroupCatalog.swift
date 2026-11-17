#if os(iOS)
import Foundation

/// Categorizes existing outbound objects for Configuration Studio, without
/// manufacturing generator-side rules from the compiled sing-box JSON.
///
/// Selector / URLTest is also a strategy (a runtime choice algorithm). The
/// Groups screen only exposes the composition of its referenced outbounds.
struct StudioGroupCatalog {
    enum Kind: String, CaseIterable {
        case manual
        case dynamic
        case smart
        case chain
        case composite

        var title: String {
            switch self {
            case .manual: return "Группы узлов"
            case .dynamic: return "Динамические группы"
            case .smart: return "Умные группы"
            case .chain: return "Цепочки"
            case .composite: return "Составные группы"
            }
        }

        var subtitle: String {
            switch self {
            case .manual: return "Явно перечисленные участники"
            case .dynamic: return "Фильтры, реально сохранённые в JSON"
            case .smart: return "Анализ доступности и карантина · позже"
            case .chain: return "Последовательные хопы через detour"
            case .composite: return "Ссылки на другие группы и отдельные узлы"
            }
        }

        var icon: String {
            switch self {
            case .manual: return "list.bullet.rectangle"
            case .dynamic: return "line.3.horizontal.decrease.circle"
            case .smart: return "brain.head.profile"
            case .chain: return "point.3.connected.trianglepath.dotted"
            case .composite: return "rectangle.3.group"
            }
        }
    }

    struct Item: Identifiable {
        let index: Int
        let tag: String
        let type: String
        let raw: [String: Any]
        let kind: Kind
        let members: [String]
        let linkedGroups: [String]
        let detour: String?
        let isLegacyPool: Bool
        var id: Int { index }

        // For explicit type: chain the tag identifies the chain, not a hop.
        // For detoured protocol outbounds the tag identifies the final hop.
        var chainHopsLabel: String {
            if let detour { return "\(detour) → \(tag)" }
            return members.joined(separator: " → ")
        }
    }

    let entries: [Item]

    init(document: StudioDocument) {
        let outbounds = document.array("outbounds")
        let groupTags = Set(outbounds.filter {
            ["selector", "urltest"].contains($0["type"] as? String ?? "")
        }.compactMap { $0["tag"] as? String })
        let allTags = Set(outbounds.compactMap { $0["tag"] as? String })
        let legacyTags: Set<String> = ["Пул A", "Пул B", "Пул C", "Пул D"]
        var result: [Item] = []
        for (index, outbound) in outbounds.enumerated() {
            let type = outbound["type"] as? String ?? ""
            let tag = outbound["tag"] as? String ?? "Выход №\(index + 1)"
            let members = outbound["outbounds"] as? [String] ?? []
            let linkedGroups = members.filter { groupTags.contains($0) }
            let include = outbound["include"] as? [String] ?? []
            let exclude = outbound["exclude"] as? [String] ?? []
            let detour = outbound["detour"] as? String
            let kind: Kind
            if type == "chain" {
                kind = .chain
            } else if ["selector", "urltest"].contains(type) {
                if !include.isEmpty || !exclude.isEmpty {
                    kind = .dynamic
                } else if !linkedGroups.isEmpty {
                    kind = .composite
                } else {
                    kind = .manual
                }
            } else if ["vless", "vmess", "trojan", "shadowsocks",
                       "hysteria", "hysteria2", "tuic"].contains(type),
                      let detour, allTags.contains(detour),
                      detour != tag, detour.lowercased() != "direct" {
                // A detoured protocol outbound (e.g. C • Gemini through
                // Strategy) is a real chain even without type: chain.
                kind = .chain
            } else {
                continue
            }
            result.append(Item(index: index, tag: tag, type: type,
                               raw: outbound, kind: kind, members: members,
                               linkedGroups: linkedGroups, detour: detour,
                               isLegacyPool: legacyTags.contains(tag)))
        }
        entries = result
    }

    func items(_ kind: Kind) -> [Item] {
        entries.filter { $0.kind == kind }
    }

    var allCount: Int { entries.count }
    var legacyPools: [Item] { entries.filter(\.isLegacyPool) }
}
#endif
