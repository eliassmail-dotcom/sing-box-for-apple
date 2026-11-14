import Foundation

// Configurable per-profile LX overrides. Remote subscription files are never modified.
public struct LXURLTestOverride: Codable, Equatable {
    public var mode: String = "profile"
    public var pool: Int = 3
    public var poolTolerance: Int = 0
    public var sticky: Bool = true
    public init() {}
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

    public init() {}

    // Backward-compatible with previously saved LX settings that lack urlTestDefault.
    private enum CodingKeys: String, CodingKey {
        case urlTestDefault, urlTests, dnsGroups, wgIdle, adaptiveTolerancePercent, minHoldSeconds, probeURLs
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
    }

    public var isEmpty: Bool {
        urlTestDefault.mode == "profile" &&
        urlTests.isEmpty &&
        dnsGroups.values.allSatisfy { $0 == "profile" } && wgIdle == "profile" &&
        adaptiveTolerancePercent == 0 && minHoldSeconds == 0 && probeURLs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
    // Every compatible profile gets a dormant fallback group automatically.
    // It is used ONLY when the user selects the mode from the Dashboard.
    // The source subscription and the user's previous selector choice stay intact.
    public static func supportsWhiteFallback(_ source: String) -> Bool {
        guard let root = try? document(source),
              let outbounds = root["outbounds"] as? [[String: Any]] else { return false }
        let urltestTags = Set(outbounds.compactMap { item -> String? in
            guard (item["type"] as? String) == "urltest" else { return nil }
            return item["tag"] as? String
        })
        return baseTags.contains(where: urltestTags.contains) &&
               whiteTags.contains(where: urltestTags.contains) &&
               outbounds.contains(where: { ($0["tag"] as? String) == "Стратегия" &&
                   ($0["type"] as? String) == "selector" })
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
              let white = whiteTags.first(where: urltestTags.contains),
              let rootIndex = outbounds.firstIndex(where: {
                  ($0["tag"] as? String) == "Стратегия" &&
                  ($0["type"] as? String) == "selector"
              }) else {
            throw OverrideError.invalidOption("для резервирования требуются группы Базовая, Белые и селектор Стратегия")
        }
        // Profiles which already contain the generated group must not get duplicates.
        if let existing = outbounds.first(where: { ($0["tag"] as? String) == preferredFallbackTag }) {
            guard (existing["type"] as? String) == "urltest",
                  (existing["outbounds"] as? [String]) == [base, white],
                  (existing["priority_outbounds"] as? [String]) == [base] else {
                throw OverrideError.invalidOption("существующая резервная группа имеет несовместимую конфигурацию")
            }
            return
        }
        guard var rootTags = outbounds[rootIndex]["outbounds"] as? [String] else {
            throw OverrideError.invalidOption("Стратегия не содержит список outbounds")
        }
        // Keep original selection and route rules intact. The user opts into the new
        // strategy from the Dashboard when the new group is visible.
        rootTags.append(preferredFallbackTag)
        outbounds[rootIndex]["outbounds"] = rootTags
        let baseConfig = outbounds.first(where: { ($0["tag"] as? String) == base }) ?? [:]
        var fallback: [String: Any] = [
            "type": "urltest",
            "tag": preferredFallbackTag,
            "outbounds": [base, white],
            "mode": "least_test",
            "priority_outbounds": [base],
            "interrupt_exist_connections": false,
        ]
        for field in ["url", "interval", "idle_timeout"] {
            if let value = baseConfig[field] { fallback[field] = value }
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
        guard !settings.isEmpty || injectFallback else { return source }

        var root = try document(source)
        var changed = false

        guard (0...100).contains(settings.adaptiveTolerancePercent),
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
