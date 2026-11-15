#if os(iOS)
import Foundation

/// Read-only projection of the loaded sing-box/LX profile.
/// Keeps original rule indices; does not infer unsupported fallback priorities.
struct StudioSemanticModel {
    let document: StudioDocument
    let groups: [NodeGroup]
    let strategies: [Strategy]
    let dnsServers: [DNSServer]
    let dnsPolicies: [DNSPolicy]
    let addressPolicies: [AddressPolicy]
    let defaultRoute: String?
    let defaultDNS: String?
    let defaultHTTPClient: String?

    init(document: StudioDocument) {
        self.document = document
        let root = document.root
        let outbounds = root["outbounds"] as? [[String: Any]] ?? []
        let route = root["route"] as? [String: Any] ?? [:]
        let dns = root["dns"] as? [String: Any] ?? [:]
        defaultRoute = route["final"] as? String
        defaultHTTPClient = route["default_http_client"] as? String
        defaultDNS = dns["final"] as? String

        let grouped = outbounds.filter { ["selector", "urltest"].contains($0["type"] as? String ?? "") }
        let groupNames = Set(grouped.compactMap { $0["tag"] as? String })
        let knownTags = Set(outbounds.compactMap { $0["tag"] as? String })
        let definitions = grouped.map { item -> NodeGroup in
            let name = item["tag"] as? String ?? "Без названия"
            let members = item["outbounds"] as? [String] ?? []
            return NodeGroup(id: name, type: item["type"] as? String ?? "",
                             explicitNodes: members.filter { !groupNames.contains($0) },
                             memberGroups: members.filter { groupNames.contains($0) },
                             memberOrder: members,
                             includePatterns: Self.stringList(item["include"]),
                             excludePatterns: Self.stringList(item["exclude"]),
                             raw: item)
        }
        let groupIndex = Dictionary(definitions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        groups = definitions.map { group in
            var result = group
            var emitted = Set<String>()
            var missing = Set<String>()
            var cyclic = Set<String>()
            func expand(_ tag: String, path: Set<String>) {
                if path.contains(tag) { cyclic.insert(tag); return }
                if let nested = groupIndex[tag] {
                    for member in nested.memberOrder {
                        expand(member, path: path.union([tag]))
                    }
                } else if knownTags.contains(tag) {
                    if emitted.insert(tag).inserted { result.resolvedNodes.append(tag) }
                } else {
                    missing.insert(tag)
                }
            }
            expand(group.id, path: [])
            result.unresolvedReferences = missing.sorted()
            result.cycles = cyclic.sorted()
            return result
        }
        strategies = definitions.map { group in
            Strategy(id: group.id,
                     kind: group.type == "selector" ? .manual : .automatic,
                     algorithm: group.raw["mode"] as? String,
                     participantGroups: group.memberGroups,
                     participantNodes: group.explicitNodes,
                     verifiedPriorityLevels: [], raw: group.raw)
        }

        let servers = dns["servers"] as? [[String: Any]] ?? []
        dnsServers = servers.enumerated().map { index, item in
            let type = item["type"] as? String ?? ""
            let host = item["server"] as? String ?? item["address"] as? String
            let tag = item["tag"] as? String
            return DNSServer(id: String(index),
                             name: tag ?? host ?? "DNS \(index + 1)",
                             type: type, host: host, detour: item["detour"] as? String,
                             raw: item)
        }

        let dnsRules = dns["rules"] as? [[String: Any]] ?? []
        var buckets: [String: DNSPolicy] = [:]
        var order: [String] = []
        for (index, rule) in dnsRules.enumerated() {
            let action = rule["action"] as? String ?? "route"
            let server = rule["server"] as? String
            let race = rule["race"] as? Bool ?? false
            let speculative = rule["speculative"] as? Bool ?? false
            let response = rule["match_response"] != nil
            let key = "\(action)|\(server ?? "")|\(race)|\(speculative)|\(response)"
            if buckets[key] == nil {
                order.append(key)
                buckets[key] = DNSPolicy(id: key, action: action, server: server,
                                        race: race, speculative: speculative,
                                        matchesEvaluatedResponse: response, indices: [])
            }
            buckets[key]?.indices.append(index)
        }
        dnsPolicies = order.compactMap { buckets[$0] }

        let routeRules = route["rules"] as? [[String: Any]] ?? []
        let matchKeys = ["domain", "domain_suffix", "domain_keyword", "domain_regex",
                         "ip_cidr", "source_ip_cidr", "rule_set", "ip_is_private",
                         "network", "network_type", "wifi_ssid", "wifi_bssid",
                         "port", "port_range", "process_name", "package_name",
                         "clash_mode", "inbound", "protocol"]
        var addressGroups: [String: AddressPolicy] = [:]
        var addressOrder: [String] = []
        func signature(_ rule: [String: Any]) -> (String, [String: Any])? {
            let conditions = rule.filter { matchKeys.contains($0.key) }
            guard !conditions.isEmpty,
                  let data = try? JSONSerialization.data(withJSONObject: conditions, options: [.sortedKeys]),
                  let key = String(data: data, encoding: .utf8) else { return nil }
            return (key, conditions)
        }
        for (index, rule) in routeRules.enumerated() {
            guard let (key, conditions) = signature(rule) else { continue }
            if addressGroups[key] == nil {
                addressOrder.append(key)
                addressGroups[key] = AddressPolicy(id: key, title: Self.addressTitle(conditions),
                                                   conditions: conditions, routeRules: [],
                                                   dnsRules: [], destinations: [], dnsTargets: [])
            }
            addressGroups[key]?.routeRules.append(index)
            if let target = rule["outbound"] as? String,
               !(addressGroups[key]?.destinations.contains(target) ?? false) {
                addressGroups[key]?.destinations.append(target)
            }
        }
        for (index, rule) in dnsRules.enumerated() {
            guard let (key, conditions) = signature(rule) else { continue }
            if addressGroups[key] == nil {
                addressOrder.append(key)
                addressGroups[key] = AddressPolicy(id: key, title: Self.addressTitle(conditions),
                                                   conditions: conditions, routeRules: [],
                                                   dnsRules: [], destinations: [], dnsTargets: [])
            }
            addressGroups[key]?.dnsRules.append(index)
            if let server = rule["server"] as? String,
               !(addressGroups[key]?.dnsTargets.contains(server) ?? false) {
                addressGroups[key]?.dnsTargets.append(server)
            }
        }
        addressPolicies = addressOrder.compactMap { addressGroups[$0] }
    }

    private static func stringList(_ raw: Any?) -> [String] {
        if let list = raw as? [String] { return list }
        if let value = raw as? String, !value.isEmpty { return [value] }
        return []
    }

    private static func addressTitle(_ conditions: [String: Any]) -> String {
        for key in ["domain", "domain_suffix", "rule_set", "ip_cidr", "domain_keyword", "network_type"] {
            if let values = conditions[key] as? [String], let first = values.first {
                return values.count == 1 ? first : "\(first) +\(values.count - 1)"
            }
            if let value = conditions[key] as? String { return value }
        }
        let labels = conditions.keys.sorted().prefix(2).map(StudioHumanFields.label)
        return labels.isEmpty ? "Условия" : labels.joined(separator: " · ")
    }

    struct NodeGroup: Identifiable {
        let id: String
        let type: String
        let explicitNodes: [String]
        let memberGroups: [String]
        let memberOrder: [String]
        let includePatterns: [String]
        let excludePatterns: [String]
        let raw: [String: Any]
        var resolvedNodes: [String] = []
        var unresolvedReferences: [String] = []
        var cycles: [String] = []

        var composition: String {
            if !includePatterns.isEmpty || !excludePatterns.isEmpty {
                return memberOrder.isEmpty ? "Динамическая" : "Комбинированная"
            }
            return memberGroups.isEmpty ? "Простая" : "Комбинированная"
        }
    }
    struct Strategy: Identifiable {
        enum Kind { case manual, automatic }
        let id: String
        let kind: Kind
        let algorithm: String?
        let participantGroups: [String]
        let participantNodes: [String]
        let verifiedPriorityLevels: [PriorityTier]
        let raw: [String: Any]

        var readableKind: String {
            if kind == .manual { return "Ручной выбор" }
            guard let algorithm else { return "Автоматический выбор · режим ядра" }
            return StudioHumanFields.mode(algorithm)
        }
    }
    struct DNSServer: Identifiable {
        let id: String
        let name: String
        let type: String
        let host: String?
        let detour: String?
        let raw: [String: Any]
    }
    struct DNSPolicy: Identifiable {
        let id: String
        let action: String
        let server: String?
        let race: Bool
        let speculative: Bool
        let matchesEvaluatedResponse: Bool
        var indices: [Int]
        var summary: String {
            "\(StudioHumanFields.action(action)) · \(server ?? "без назначения")"
        }
    }
    struct AddressPolicy: Identifiable {
        let id: String
        let title: String
        let conditions: [String: Any]
        var routeRules: [Int]
        var dnsRules: [Int]
        var destinations: [String]
        var dnsTargets: [String]
        var isRouteExplicit: Bool { !destinations.isEmpty }
        var isDNSExplicit: Bool { !dnsTargets.isEmpty }
    }

    /// Future editor metadata: unlimited ordered tiers, independent health
    /// gates. A list of outbound members is NOT automatically a priority queue.
    struct PriorityTier: Identifiable, Equatable {
        enum Check: String { case urlTest, realDial, combined }
        enum Quarantine: String { case exclude, deprioritize, lastResort }
        let id: String
        let group: String
        let check: Check
        let minimumHealthy: Int
        let quarantine: Quarantine
        let returnAfterRecovery: Bool
    }
}

enum StudioDNSFollowRoute {
    enum DNSChoice: Equatable {
        case automatic, inherit, explicit(String)
    }
    struct Assignment: Equatable {
        enum Source: Equatable { case protectedOverride, explicit, associated, inherited, unmapped }
        let route: String
        let dns: String?
        let source: Source
    }
    static func resolve(route: String, choice: DNSChoice,
                        association: [String: String], defaultDNS: String?,
                        protectedDNS: String? = nil) -> Assignment {
        if let protectedDNS {
            return Assignment(route: route, dns: protectedDNS, source: .protectedOverride)
        }
        switch choice {
        case .explicit(let server):
            return Assignment(route: route, dns: server, source: .explicit)
        case .inherit:
            return Assignment(route: route, dns: defaultDNS, source: .inherited)
        case .automatic:
            if let server = association[route] {
                return Assignment(route: route, dns: server, source: .associated)
            }
            return Assignment(route: route, dns: defaultDNS, source: .unmapped)
        }
    }
}

enum StudioTierEligibility {
    struct NodeSample {
        let tag: String
        let urlTestOK: Bool?
        let realDialOK: Bool?
        let quarantined: Bool
    }
    struct Evaluation {
        let eligible: [String]
        let unknown: [String]
        let meetsMinimum: Bool
    }

    static func evaluate(tier: StudioSemanticModel.PriorityTier,
                         samples: [NodeSample]) -> Evaluation {
        var available: [String] = []
        var unknown: [String] = []
        for node in samples {
            if node.quarantined && tier.quarantine == .exclude { continue }
            let passes: Bool?
            switch tier.check {
            case .urlTest: passes = node.urlTestOK
            case .realDial: passes = node.realDialOK
            case .combined:
                if node.urlTestOK == false || node.realDialOK == false { passes = false }
                else if node.urlTestOK == true && node.realDialOK == true { passes = true }
                else { passes = nil }
            }
            if passes == true { available.append(node.tag) }
            else if passes == nil { unknown.append(node.tag) }
        }
        return Evaluation(eligible: available, unknown: unknown,
                          meetsMinimum: available.count >= max(1, tier.minimumHealthy))
    }

    static func activeTier(tiers: [StudioSemanticModel.PriorityTier],
                           samplesByGroup: [String: [NodeSample]]) -> String? {
        for tier in tiers {
            if evaluate(tier: tier, samples: samplesByGroup[tier.group] ?? []).meetsMinimum {
                return tier.id
            }
        }
        return nil
    }
}
#endif
