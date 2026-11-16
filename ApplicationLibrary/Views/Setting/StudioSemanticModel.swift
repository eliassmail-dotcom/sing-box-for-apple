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
        let sources = definitions.map {
            StudioNodeGroupComposer.Definition(id: $0.id,
                                               members: $0.memberOrder,
                                               include: $0.includePatterns,
                                               exclude: $0.excludePatterns)
        }
        // Dynamic matching is over actual proxy/node names, never over
        // technical selector groups or DIRECT/BLOCK. Explicit destinations
        // remain available through the member list.
        let filterable = outbounds.compactMap { item -> String? in
            guard let tag = item["tag"] as? String else { return nil }
            let type = item["type"] as? String ?? ""
            return ["selector", "urltest", "direct", "block", "dns"].contains(type) ? nil : tag
        }
        groups = definitions.map { group in
            var result = group
            let resolved = StudioNodeGroupComposer.resolve(
                group: group.id, definitions: sources,
                knownTags: Array(knownTags), filterableNodes: filterable
            )
            result.resolvedNodes = resolved.nodes
            result.unresolvedReferences = resolved.missing
            result.cycles = resolved.cycles
            return result
        }
        strategies = definitions.map { group in
            let primary = group.raw["priority_outbounds"] as? [String] ?? []
            return Strategy(id: group.id,
                            kind: group.type == "selector" ? .manual : .automatic,
                            algorithm: group.raw["mode"] as? String,
                            participantGroups: group.memberGroups,
                            participantNodes: group.explicitNodes,
                            priorityOutbounds: primary,
                            fallbackOutbounds: group.memberOrder.filter { !primary.contains($0) },
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
            let response: Bool
            if let flag = rule["match_response"] as? Bool { response = flag }
            else if let tag = rule["match_response"] as? String { response = !tag.isEmpty }
            else { response = false }
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
        let labels: [(String, String)] = [
            ("domain", "точных доменов"),
            ("domain_suffix", "доменов и поддоменов"),
            ("rule_set", "списков адресов"),
            ("ip_cidr", "IP-подсетей"),
            ("domain_keyword", "ключевых слов")
        ]
        for (key, noun) in labels {
            if let values = conditions[key] as? [String], !values.isEmpty {
                if values.count == 1 { return values[0] }
                if key == "domain" {
                    return StudioDNSExplanation.countLabel(values.count,
                        one: "точный домен", few: "точных домена",
                        many: "точных доменов")
                }
                return "\(values.count) \(noun)"
            }
            if let value = conditions[key] as? String { return value }
        }
        return StudioDNSExplanation.conditionsDescription(conditions)
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
        let priorityOutbounds: [String]
        let fallbackOutbounds: [String]
        let verifiedPriorityLevels: [PriorityTier]
        let raw: [String: Any]

        var readableKind: String {
            if kind == .manual { return "Ручной выбор" }
            if !priorityOutbounds.isEmpty { return "Авто · приоритет и резерв" }
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
                         samples: [NodeSample],
                         allowQuarantine: Bool = false) -> Evaluation {
        var available: [String] = []
        var unknown: [String] = []
        for node in samples {
            // Quarantined candidates are tried only in the second pass, after
            // every clean tier has failed. EXCLUDE is strict even in fallback.
            if node.quarantined && (!allowQuarantine || tier.quarantine == .exclude) { continue }
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
                           samplesByGroup: [String: [NodeSample]],
                           currentTierID: String? = nil) -> String? {
        // Respect the current tier's explicit no-auto-return policy when it
        // is still healthy. There is no silent promotion to a recovered tier.
        if let currentTierID,
           let current = tiers.first(where: { $0.id == currentTierID }),
           !current.returnAfterRecovery,
           evaluate(tier: current, samples: samplesByGroup[current.group] ?? []).meetsMinimum {
            return currentTierID
        }
        // First prefer any non-quarantined eligible tier in configured order.
        for tier in tiers {
            if evaluate(tier: tier, samples: samplesByGroup[tier.group] ?? []).meetsMinimum {
                return tier.id
            }
        }
        // If every healthy tier has failed, obey user-selected quarantine
        // fallback policy. Never fabricate a DIRECT exit.
        for tier in tiers where tier.quarantine != .exclude {
            if evaluate(tier: tier, samples: samplesByGroup[tier.group] ?? [],
                        allowQuarantine: true).meetsMinimum {
                return tier.id
            }
        }
        return nil
    }
}
#endif
