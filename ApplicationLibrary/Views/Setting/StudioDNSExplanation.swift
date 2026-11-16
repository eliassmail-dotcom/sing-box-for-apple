#if os(iOS)
import Foundation

/// Read-only projection of the ordered DNS program.
/// DNS final is a server used on fallthrough, not a per-route profile.
/// No rule reordering, write-back, or claim of runtime decisions.
enum StudioDNSExplanation {
    enum Family: String {
        case direct
        case proxy
        case other
        var title: String {
            switch self {
            case .direct: return "Direct DNS"
            case .proxy: return "Proxy DNS"
            case .other: return "Прочие и служебные DNS"
            }
        }
    }

    struct ServerBinding: Identifiable {
        let name: String
        let kind: String
        let transport: String
        let detour: String?
        let family: Family
        let reason: String
        let object: [String: Any]
        var id: String { name }
    }

    struct FlowStep: Identifiable {
        let index: Int
        let action: String
        let server: String?
        let condition: String
        let responseDependency: String?
        let race: Bool
        let speculative: Bool
        let raw: [String: Any]
        var id: Int { index }
        var number: String { "№\(index + 1)" }
        var heading: String {
            switch action {
            case "route": return "Запросить DNS-сервер"
            case "evaluate": return "Получить ответ для проверки"
            case "respond": return "Вернуть проверенный ответ"
            case "reject": return "Отклонить DNS-запрос"
            case "predefined": return "Вернуть заданный DNS-ответ"
            case "route-options": return "Изменить параметры DNS-запроса"
            default: return "Действие: \(action)"
            }
        }
        var result: String {
            switch action {
            case "route": return server.map { "DNS-запрос к \($0)" } ?? "DNS-сервер не указан"
            case "evaluate": return server.map { "Сохранить ответ от \($0) для проверки следующими правилами" } ?? "Получить ответ для следующих правил"
            case "respond": return "Вернуть ответ, полученный на предыдущем шаге evaluate"
            case "reject": return "Отклонить запрос"
            case "predefined": return "Вернуть ответ, указанный в правиле"
            case "route-options": return "Применить параметры и продолжить проверку"
            default: return "См. технические параметры"
            }
        }
        var concurrency: String? {
            if race { return "RACE: проверка ответа может выполняться параллельно со следующими правилами" }
            if speculative { return "Предварительный запрос во время ожидания RACE" }
            return nil
        }
    }

    struct Profile: Identifiable {
        let family: Family
        let bindings: [ServerBinding]
        let ruleIndexes: [Int]
        var id: String { family.rawValue }
        var title: String { family.title }
        var summary: String {
            switch family {
            case .direct: return "Серверы с прямым подключением"
            case .proxy: return "Серверы, подключающиеся через прокси"
            case .other: return "Неоднозначные или служебные подключения"
            }
        }
    }

    static func bindings(document: StudioDocument) -> [ServerBinding] {
        let outbounds = document.array("outbounds")
        let types = Dictionary(outbounds.compactMap { entry -> (String, String)? in
            guard let tag = entry["tag"] as? String, let type = entry["type"] as? String else { return nil }
            return (tag, type)
        }, uniquingKeysWith: { first, _ in first })
        let dns = document.root["dns"] as? [String: Any] ?? [:]
        let servers = dns["servers"] as? [[String: Any]] ?? []
        return servers.enumerated().map { i, entry in
            let tag = entry["tag"] as? String ?? "DNS №\(i + 1)"
            let type = entry["type"] as? String ?? "не указан"
            let detour = entry["detour"] as? String
            let family: Family
            let reason: String
            if let detour, !detour.isEmpty {
                let outboundType = types[detour]
                if outboundType == "direct" || detour.lowercased() == "direct" {
                    family = .direct
                    reason = "Подключение через DIRECT: \(detour)"
                } else if let outboundType,
                          !["block", "dns"].contains(outboundType) {
                    family = .proxy
                    reason = "Подключение через \(detour) (\(outboundType))"
                } else {
                    family = .other
                    reason = "Маршрут \(detour) не удалось классифицировать по outbounds"
                }
            } else if ["https", "tls", "tcp", "udp", "quic", "h3"].contains(type),
                      entry["http_client"] == nil {
                // New typed DNS servers use direct dial by default.
                // This describes DNS transport only, never matching queries.
                family = .direct
                reason = "Новый DNS-транспорт без detour: прямое соединение"
            } else {
                family = .other
                reason = "Путь DNS-соединения нельзя однозначно определить"
            }
            let host = entry["server"] as? String ?? entry["address"] as? String ?? "не указан"
            return ServerBinding(name: tag, kind: type, transport: host,
                                 detour: detour, family: family,
                                 reason: reason, object: entry)
        }
    }

    static func steps(document: StudioDocument) -> [FlowStep] {
        let dns = document.root["dns"] as? [String: Any] ?? [:]
        let rules = dns["rules"] as? [[String: Any]] ?? []
        return rules.enumerated().map { index, rule in
            FlowStep(index: index, action: rule["action"] as? String ?? "route",
                     server: rule["server"] as? String,
                     condition: conditionsDescription(rule),
                     responseDependency: responseMatchDescription(rule["match_response"]),
                     race: rule["race"] as? Bool == true,
                     speculative: rule["speculative"] as? Bool == true,
                     raw: rule)
        }
    }

    static func profiles(document: StudioDocument) -> [Profile] {
        let allBindings = bindings(document: document)
        let flow = steps(document: document)
        return [Family.direct, .proxy, .other].map { family in
            let matching = allBindings.filter { $0.family == family }
            let tags = Set(matching.map(\.name))
            return Profile(family: family, bindings: matching,
                           ruleIndexes: flow.filter {
                               $0.server.map { tags.contains($0) } ?? false
                           }.map(\.index))
        }
    }

    /// Suggested profile family for the future editor. A selector or urltest
    /// generally serves proxy traffic; it may contain a DIRECT member, so the
    /// mapping remains a suggestion, not a statement of actual DNS routing.
    static func suggestedFamily(forRoute route: String,
                                document: StudioDocument) -> Family? {
        if route.lowercased() == "direct" { return .direct }
        guard let outbound = document.array("outbounds").first(where: {
            ($0["tag"] as? String) == route
        }) else { return nil }
        switch outbound["type"] as? String ?? "" {
        case "direct": return .direct
        case "selector", "urltest", "vless", "vmess", "trojan",
             "shadowsocks", "hysteria", "hysteria2", "tuic", "chain":
            return .proxy
        default: return nil
        }
    }

    /// Human-readable conditions, not an independently editable address group.
    static func conditionsDescription(_ object: [String: Any]) -> String {
        let keys: [(String, String)] = [
            ("domain", "точных доменов"), ("domain_suffix", "доменов и поддоменов"),
            ("domain_keyword", "ключевых слов"), ("domain_regex", "шаблонов доменов"),
            ("rule_set", "списков адресов"), ("ip_cidr", "IP-подсетей"),
            ("clash_mode", "режимов маршрутизации"),
            ("query_type", "типов DNS-запроса"),
            ("network_type", "типов сети"),
            ("ip_version", "версий IP"),
            ("inbound", "входящих соединений")
        ]
        var terms: [String] = []
        for (key, description) in keys {
            if let list = object[key] as? [Any], !list.isEmpty {
                terms.append("\(list.count) \(description)")
            } else if object[key] != nil {
                terms.append("условие: \(StudioHumanFields.label(key).lowercased())")
            }
        }
        if let subrules = object["rules"] as? [Any], !subrules.isEmpty {
            let mode = object["mode"] as? String ?? "and"
            terms.append("\(subrules.count) вложенных условий (\(mode == "or" ? "ИЛИ" : "И"))")
        }
        if responseMatchDescription(object["match_response"]) != nil {
            terms.append("условие по полученному ответу")
        }
        if terms.isEmpty {
            return "Если предыдущие правила не завершили обработку"
        }
        return terms.joined(separator: " · ")
    }

    static func exactDomainCount(_ object: [String: Any]) -> Int {
        (object["domain"] as? [Any])?.count ?? (object["domain"] == nil ? 0 : 1)
    }

    static func responseMatchDescription(_ raw: Any?) -> String? {
        if let enabled = raw as? Bool {
            return enabled ? "Ответ последней проверки без тега" : nil
        }
        if let reference = raw as? String, !reference.isEmpty {
            return "Результат проверки «\(reference)»"
        }
        return nil
    }
}
#endif
