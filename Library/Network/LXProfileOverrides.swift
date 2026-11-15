import Foundation

public extension Notification.Name {
    static let lxResilienceSettingsChanged = Notification.Name("lxResilienceSettingsChanged")
}

// Configurable per-profile LX overrides. Remote subscription files are never modified.
public struct LXURLTestOverride: Codable, Equatable {
    public var mode: String = "profile"
    public var pool: Int = 3
    public var poolTolerance: Int = 0
    public var sticky: Bool = true
    public init() {}
}

/// Presets do not alter node pools, routes, DNS, selector interruption or the
/// source health URLs. They tune only the existing LX reliability controls.
public enum LXResiliencePreset: String, CaseIterable {
    case custom, economy, balance, antiblock
}

public struct LXProfileSettings: Codable, Equatable {
    // Common mode for every URLTest group inside this profile.
    // Per-group entries take precedence, including an explicit "profile" opt-out.
    public var urlTestDefault = LXURLTestOverride()
    public var urlTests: [String: LXURLTestOverride] = [:]
    public var dnsGroups: [String: String] = [:]
    public var wgIdle: String = "profile"
    // Global reliability controls. Zero/empty means inherit the source profile.
    public var adaptiveTolerancePercent: Int = 0
    public var minHoldSeconds: Int = 0
    public var probeURLs: String = ""
    // Experimental: passive watchdog/quarantine; off until explicitly enabled.
    public var passiveGuardEnabled: Bool = false
    /// Off by default: source Gemini+ still provides ordinary Gemini nodes.
    public var geminiChainsEnabled: Bool = false
    /// Existing saved settings are treated as Custom, never silently migrated.
    public var resiliencePreset: String = LXResiliencePreset.custom.rawValue

    public mutating func applyResiliencePreset(_ name: String) {
        resiliencePreset = name
        switch LXResiliencePreset(rawValue: name) ?? .custom {
        case .custom:
            break
        case .economy:
            adaptiveTolerancePercent = 0
            minHoldSeconds = 60
            passiveGuardEnabled = false
        case .balance:
            adaptiveTolerancePercent = 20
            minHoldSeconds = 30
            passiveGuardEnabled = false
        case .antiblock:
            adaptiveTolerancePercent = 35
            minHoldSeconds = 10
            passiveGuardEnabled = true
        }
        // Preserve probeURLs, URLTest mode, DNS, priorities and interrupt flag.
    }

    public init() {}

    // Backward-compatible with previously saved LX settings that lack urlTestDefault.
    private enum CodingKeys: String, CodingKey {
        case urlTestDefault, urlTests, dnsGroups, wgIdle, adaptiveTolerancePercent, minHoldSeconds, probeURLs, passiveGuardEnabled, geminiChainsEnabled, resiliencePreset
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        urlTestDefault = try container.decodeIfPresent(LXURLTestOverride.self, forKey: .urlTestDefault) ?? LXURLTestOverride()
        urlTests = try container.decodeIfPresent([String: LXURLTestOverride].self, forKey: .urlTests) ?? [:]
        dnsGroups = try container.decodeIfPresent([String: String].self, forKey: .dnsGroups) ?? [:]
        wgIdle = try container.decodeIfPresent(String.self, forKey: .wgIdle) ?? "profile"
        adaptiveTolerancePercent = try container.decodeIfPresent(Int.self, forKey: .adaptiveTolerancePercent) ?? 0
        minHoldSeconds = try container.decodeIfPresent(Int.self, forKey: .minHoldSeconds) ?? 0
        probeURLs = try container.decodeIfPresent(String.self, forKey: .probeURLs) ?? ""
        passiveGuardEnabled = try container.decodeIfPresent(Bool.self, forKey: .passiveGuardEnabled) ?? false
        geminiChainsEnabled = try container.decodeIfPresent(Bool.self, forKey: .geminiChainsEnabled) ?? false
        resiliencePreset = try container.decodeIfPresent(String.self, forKey: .resiliencePreset) ?? LXResiliencePreset.custom.rawValue
    }

    public var isEmpty: Bool {
        urlTestDefault.mode == "profile" &&
        urlTests.isEmpty &&
        dnsGroups.values.allSatisfy { $0 == "profile" } && wgIdle == "profile" &&
        adaptiveTolerancePercent == 0 && minHoldSeconds == 0 && !passiveGuardEnabled &&
        !geminiChainsEnabled && resiliencePreset == LXResiliencePreset.custom.rawValue &&
        probeURLs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public struct LXOverridesStore: Codable, Equatable {
    public var profiles: [String: LXProfileSettings] = [:]
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

public struct LXConfigGroup: Identifiable, Equatable {
    public let tag: String
    public let mode: String
    public var id: String { tag }
}

public struct LXConfigSummary: Equatable {
    public let urlTests: [LXConfigGroup]
    public let dnsGroups: [LXConfigGroup]
    public let wireGuardCount: Int
    public let chainCount: Int
    public let xhttpCount: Int
    public let encryptedVlessCount: Int
}

public enum LXProfileOverrides {
    public enum OverrideError: LocalizedError {
        case invalidJSON
        case invalidOption(String)
        public var errorDescription: String? {
            switch self {
            case .invalidJSON: return "Профиль не является JSON-объектом sing-box. LX-настройки не применены."
            case let .invalidOption(message): return "Некорректная LX-настройка: \(message)"
            }
        }
    }

    private static func document(_ content: String) throws -> [String: Any] {
        guard let value = try? JSONSerialization.jsonObject(with: Data(content.utf8)),
              let object = value as? [String: Any] else {
            throw OverrideError.invalidJSON
        }
        return object
    }

    public static func inspect(_ content: String) throws -> LXConfigSummary {
        let root = try document(content)
        let outbounds = root["outbounds"] as? [[String: Any]] ?? []
        let endpoints = root["endpoints"] as? [[String: Any]] ?? []
        let dns = root["dns"] as? [String: Any] ?? [:]
        let dnsServers = dns["servers"] as? [[String: Any]] ?? []

        let urlTests = outbounds.compactMap { item -> LXConfigGroup? in
            guard (item["type"] as? String) == "urltest",
                  let tag = item["tag"] as? String else { return nil }
            return LXConfigGroup(tag: tag, mode: item["mode"] as? String ?? "least_test")
        }
        let dnsGroups = dnsServers.compactMap { item -> LXConfigGroup? in
            guard (item["type"] as? String) == "group",
                  let tag = item["tag"] as? String else { return nil }
            return LXConfigGroup(tag: tag, mode: item["mode"] as? String ?? "stable")
        }

        return LXConfigSummary(
            urlTests: urlTests,
            dnsGroups: dnsGroups,
            wireGuardCount: (outbounds + endpoints).filter { ($0["type"] as? String) == "wireguard" }.count,
            chainCount: outbounds.filter { ($0["type"] as? String) == "chain" }.count,
            xhttpCount: outbounds.filter { ($0["transport"] as? [String: Any])?["type"] as? String == "xhttp" }.count,
            encryptedVlessCount: outbounds.filter {
                ($0["type"] as? String) == "vless" && !((($0["encryption"] as? String) ?? "").isEmpty)
            }.count
        )
    }

    public static let preferredFallbackTag = "Авто · База → Белые"
    private static let baseTags = ["Авто · Базовая", "Авто"]
    private static let whiteTags = ["Авто · Белые", "Авто · Только белые"]

    // This feature requires an LX kernel implementing priority_outbounds.
    // Smart is built as ONE flat URLTest pool: direct members from the Base tier
    // followed by White-only members. The Base leaf tags are the preferred tier.
    //
    // Do not nest the two source URLTest groups here. A parent priority group that
    // wraps URLTest children can see only each child's currently selected leaf;
    // that is not an aggregate health view of the child's full pool. In particular,
    // a stale selected leaf can make Smart fall back to White while other Base nodes
    // have successful probes. Flattening gives the Smart group direct health history
    // for every candidate and lets the core enforce Base -> White -> Base recovery.
    //
    // The source subscription and its original groups remain unchanged. The generated
    // Smart group is only selected when the user chooses it from the Dashboard.
    private static func flattenedURLTestMembers(
        _ rootTag: String,
        in outbounds: [[String: Any]]
    ) throws -> [String] {
        var byTag: [String: [String: Any]] = [:]
        for item in outbounds {
            if let tag = item["tag"] as? String {
                byTag[tag] = item
            }
        }

        var result: [String] = []
        var included = Set<String>()
        var expandedGroups = Set<String>()
        var activeGroups = Set<String>()

        func visit(_ tag: String) throws {
            guard let item = byTag[tag] else {
                throw OverrideError.invalidOption("группа \(rootTag) ссылается на отсутствующий outbound \(tag)")
            }
            if (item["type"] as? String) == "urltest" {
                guard !activeGroups.contains(tag) else {
                    throw OverrideError.invalidOption("цикл вложенных URLTest-групп: \(tag)")
                }
                guard !expandedGroups.contains(tag) else { return }
                activeGroups.insert(tag)
                guard let members = item["outbounds"] as? [String], !members.isEmpty else {
                    throw OverrideError.invalidOption("URLTest-группа \(tag) не содержит узлов")
                }
                for member in members {
                    try visit(member)
                }
                activeGroups.remove(tag)
                expandedGroups.insert(tag)
                return
            }
            // Keep selectors atomic: their current manual selection remains
            // authoritative. Chains and protocol outbounds are also leaf candidates.
            if included.insert(tag).inserted {
                result.append(tag)
            }
        }

        try visit(rootTag)
        return result
    }

    private static func smartMembers(
        base: String,
        white: String,
        in outbounds: [[String: Any]]
    ) throws -> (all: [String], preferred: [String]) {
        let preferred = try flattenedURLTestMembers(base, in: outbounds)
        let whiteMembers = try flattenedURLTestMembers(white, in: outbounds)
        let preferredSet = Set(preferred)
        let fallbackOnly = whiteMembers.filter { !preferredSet.contains($0) }
        guard !preferred.isEmpty, !fallbackOnly.isEmpty else {
            throw OverrideError.invalidOption("группы Базовая и Белые не содержат отдельных узлов для резервирования")
        }
        return (preferred + fallbackOnly, preferred)
    }

    // Every compatible profile gets a dormant Smart group automatically.
    public static func supportsWhiteFallback(_ source: String) -> Bool {
        guard let root = try? document(source),
              let outbounds = root["outbounds"] as? [[String: Any]] else { return false }
        let urltestTags = Set(outbounds.compactMap { item -> String? in
            guard (item["type"] as? String) == "urltest" else { return nil }
            return item["tag"] as? String
        })
        guard let base = baseTags.first(where: urltestTags.contains),
              let white = whiteTags.first(where: urltestTags.contains),
              outbounds.contains(where: { ($0["tag"] as? String) == "Стратегия" &&
                  ($0["type"] as? String) == "selector" }) else { return false }
        return (try? smartMembers(base: base, white: white, in: outbounds)) != nil
    }

    private static func addWhiteFallback(to root: inout [String: Any]) throws {
        guard var outbounds = root["outbounds"] as? [[String: Any]] else {
            throw OverrideError.invalidOption("список outbounds отсутствует")
        }
        let urltestTags = Set(outbounds.compactMap { item -> String? in
            guard (item["type"] as? String) == "urltest" else { return nil }
            return item["tag"] as? String
        })
        guard let base = baseTags.first(where: urltestTags.contains),
              let white = whiteTags.first(where: urltestTags.contains) else {
            throw OverrideError.invalidOption("для резервирования требуются группы Базовая и Белые")
        }
        let members = try smartMembers(base: base, white: white, in: outbounds)
        let expectedMembers = members.all
        let expectedPreferred = members.preferred

        // Rebuild the previous nested implementation in-place. This is a known
        // generated shape from earlier app versions, not a user-authored group.
        // Always rebuild it AFTER the ordinary URLTest override pass, so a global
        // round_robin/failover preference can never make this priority group invalid.
        if let existingIndex = outbounds.firstIndex(where: { ($0["tag"] as? String) == preferredFallbackTag }) {
            let existing = outbounds[existingIndex]
            let oldGeneratedShape =
                (existing["type"] as? String) == "urltest" &&
                (existing["outbounds"] as? [String]) == [base, white] &&
                (existing["priority_outbounds"] as? [String]) == [base]
            let newGeneratedShape =
                (existing["type"] as? String) == "urltest" &&
                (existing["outbounds"] as? [String]) == expectedMembers &&
                (existing["priority_outbounds"] as? [String]) == expectedPreferred
            guard oldGeneratedShape || newGeneratedShape else {
                throw OverrideError.invalidOption("существующая резервная группа имеет несовместимую конфигурацию")
            }
            outbounds.remove(at: existingIndex)
        }

        guard let rootIndex = outbounds.firstIndex(where: {
            ($0["tag"] as? String) == "Стратегия" &&
            ($0["type"] as? String) == "selector"
        }), var rootTags = outbounds[rootIndex]["outbounds"] as? [String] else {
            throw OverrideError.invalidOption("Стратегия не содержит список outbounds")
        }
            throw OverrideError.invalidOption("Стратегия не содержит список outbounds")
        }
        if !rootTags.contains(preferredFallbackTag) {
            rootTags.append(preferredFallbackTag)
        }
        outbounds[rootIndex]["outbounds"] = rootTags

        let baseConfig = outbounds.first(where: { ($0["tag"] as? String) == base }) ?? [:]
        let whiteConfig = outbounds.first(where: { ($0["tag"] as? String) == white }) ?? [:]
        var fallback: [String: Any] = [
            "type": "urltest",
            "tag": preferredFallbackTag,
            "outbounds": expectedMembers,
            "mode": "least_test",
            "priority_outbounds": expectedPreferred,
            "interrupt_exist_connections": false,
        ]

        // Use the Base group's timing and thresholds. Probe URLs from both tiers
        // are merged (up to the core's three-endpoint limit) so neither tier is
        // judged by an endpoint that existed only in the other tier.
        for field in ["interval", "idle_timeout", "tolerance", "tolerance_percent", "min_hold", "passive_guard"] {
            if let value = baseConfig[field] { fallback[field] = value }
        }
        var probeURLs: [String] = []
        for config in [baseConfig, whiteConfig] {
            let urls = config["urls"] as? [String] ?? (config["url"] as? String).map { [$0] } ?? []
            for url in urls where !probeURLs.contains(url) && probeURLs.count < 3 {
                probeURLs.append(url)
            }
        }
        if probeURLs.count == 1 {
            fallback["url"] = probeURLs[0]
        } else if !probeURLs.isEmpty {
            fallback["urls"] = probeURLs
        }

        outbounds.append(fallback)
        root["outbounds"] = outbounds
    }

    public static func apply(_ source: String, profileID: Int64, storedJSON: String) throws -> String {
        let store = try LXOverridesStore.decode(storedJSON)
        let settings = store.profiles[String(profileID)] ?? LXProfileSettings()
        // No user overrides and no compatible base/white groups: byte-identical.
        // The fallback group's presence no longer depends on a separate toggle.
        let injectFallback = supportsWhiteFallback(source)
        let injectGemini = LXGeminiBuilder.hasSource(source)
        guard !settings.isEmpty || injectFallback || injectGemini else { return source }

        var root = try document(source)
        var changed = false
        // Build on-device BEFORE applying URLTest health overrides so the
        // locally created Gemini groups inherit the same resilience settings.
        if try LXGeminiBuilder.apply(to: &root, chainsEnabled: settings.geminiChainsEnabled) {
            changed = true
        }

        guard LXResiliencePreset(rawValue: settings.resiliencePreset) != nil,
              (0...100).contains(settings.adaptiveTolerancePercent),
              (0...600).contains(settings.minHoldSeconds) else {
            throw OverrideError.invalidOption("порог адаптации / время удержания")
        }
        let healthURLs = settings.probeURLs.split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if healthURLs.count > 3 || Set(healthURLs).count != healthURLs.count ||
            healthURLs.contains(where: { value in
                guard let url = URLComponents(string: value) else { return true }
                return !["https", "http"].contains(url.scheme ?? "") || (url.host ?? "").isEmpty
            }) {
            throw OverrideError.invalidOption("проверочные URL: 1–3 разных HTTP(S)-адреса")
        }

        if var outbounds = root["outbounds"] as? [[String: Any]] {
            for index in outbounds.indices {
                guard (outbounds[index]["type"] as? String) == "urltest",
                      let tag = outbounds[index]["tag"] as? String else { continue }
                let setting = settings.urlTests[tag] ?? settings.urlTestDefault
                var group = outbounds[index]
                var groupChanged = false
                if setting.mode != "profile" {
                    guard ["least_test", "failover", "round_robin"].contains(setting.mode) else {
                        throw OverrideError.invalidOption("urltest \(tag): mode")
                    }
                    group["mode"] = setting.mode
                    if setting.mode == "round_robin" {
                        guard (1...32).contains(setting.pool), (0...2000).contains(setting.poolTolerance) else {
                            throw OverrideError.invalidOption("urltest \(tag): pool / pool_tolerance")
                        }
                        group["balancer"] = [
                            "pool": setting.pool,
                            "pool_tolerance": setting.poolTolerance,
                            "sticky_hash": setting.sticky ? ["process", "domain"] : ["none"],
                        ] as [String: Any]
                    } else {
                        group.removeValue(forKey: "balancer")
                        if setting.mode == "failover" { group.removeValue(forKey: "tolerance") }
                    }
                    groupChanged = true
                }
                let effectiveMode = group["mode"] as? String ?? "least_test"
                if effectiveMode == "least_test" {
                    if settings.adaptiveTolerancePercent > 0 {
                        group["tolerance_percent"] = settings.adaptiveTolerancePercent
                        groupChanged = true
                    }
                    if settings.minHoldSeconds > 0 {
                        group["min_hold"] = "\(settings.minHoldSeconds)s"
                        groupChanged = true
                    }
                }
                // Passport of the feature follows the actual effective mode;
                // round_robin has per-flow selection and rejects passive_guard.
                if settings.passiveGuardEnabled && effectiveMode != "round_robin" {
                    group["passive_guard"] = true
                    groupChanged = true
                }
                if effectiveMode == "round_robin" && group["passive_guard"] != nil {
                    group.removeValue(forKey: "passive_guard")
                    groupChanged = true
                }
                if !healthURLs.isEmpty {
                    group.removeValue(forKey: "url")
                    group["urls"] = healthURLs
                    groupChanged = true
                }
                if groupChanged {
                    outbounds[index] = group
                    changed = true
                }
            }
            root["outbounds"] = outbounds
        }

        if var dns = root["dns"] as? [String: Any], var servers = dns["servers"] as? [[String: Any]] {
            for index in servers.indices {
                guard (servers[index]["type"] as? String) == "group",
                      let tag = servers[index]["tag"] as? String,
                      let mode = settings.dnsGroups[tag], mode != "profile" else { continue }
                guard ["stable", "fastest", "parallel"].contains(mode) else {
                    throw OverrideError.invalidOption("DNS \(tag): mode")
                }
                servers[index]["mode"] = mode
                changed = true
            }
            dns["servers"] = servers
            root["dns"] = dns
        }

        if settings.wgIdle != "profile" {
            guard ["on", "off"].contains(settings.wgIdle) else {
                throw OverrideError.invalidOption("wgIdle")
            }
            let outbounds = root["outbounds"] as? [[String: Any]] ?? []
            let endpoints = root["endpoints"] as? [[String: Any]] ?? []
            if (outbounds + endpoints).contains(where: { ($0["type"] as? String) == "wireguard" }) {
                var lx = root["lx"] as? [String: Any] ?? [:]
                var wg = lx["wg"] as? [String: Any] ?? [:]
                if settings.wgIdle == "on" {
                    wg["idle_suspend"] = "30s"
                    wg["idle_suspend_reachable"] = "5m"
                    wg["idle_teardown"] = "10m"
                } else {
                    for key in ["idle_suspend", "idle_suspend_reachable", "idle_teardown", "lazy_build", "build_max", "build_overflow"] {
                        wg.removeValue(forKey: key)
                    }
                }
                if wg.isEmpty { lx.removeValue(forKey: "wg") } else { lx["wg"] = wg }
                if lx.isEmpty { root.removeValue(forKey: "lx") } else { root["lx"] = lx }
                changed = true
            }
        }

        if injectFallback {
            try addWhiteFallback(to: &root)
            // The generated smart fallback group is appended after the normal
            // URLTest override pass. Apply the same reliability controls to it.
            if var outbounds = root["outbounds"] as? [[String: Any]],
               let index = outbounds.firstIndex(where: { ($0["tag"] as? String) == preferredFallbackTag }) {
                if settings.adaptiveTolerancePercent > 0 {
                    outbounds[index]["tolerance_percent"] = settings.adaptiveTolerancePercent
                }
                if settings.minHoldSeconds > 0 {
                    outbounds[index]["min_hold"] = "\(settings.minHoldSeconds)s"
                }
                if settings.passiveGuardEnabled {
                    outbounds[index]["passive_guard"] = true
                }
                if !healthURLs.isEmpty {
                    outbounds[index].removeValue(forKey: "url")
                    outbounds[index]["urls"] = healthURLs
                }
                root["outbounds"] = outbounds
            }
            changed = true
        }

        guard changed else { return source }
        guard JSONSerialization.isValidJSONObject(root),
              let data = try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]),
              let transformed = String(data: data, encoding: .utf8) else {
            throw OverrideError.invalidJSON
        }
        return transformed
    }
}
