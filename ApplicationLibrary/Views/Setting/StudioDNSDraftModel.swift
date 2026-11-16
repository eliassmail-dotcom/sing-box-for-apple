#if os(iOS)
import Foundation
import SwiftUI

/// Source-of-truth for the *draft UI only*. The running profile still comes
/// from the original JSON; no save/apply operation is available in v1.3.
enum StudioDNSRole: String, CaseIterable, Identifiable {
    case directTraffic
    case proxyTraffic
    case proxyHosts
    case dnsHosts

    var id: String { rawValue }

    var title: String {
        switch self {
        case .directTraffic: return "Direct DNS"
        case .proxyTraffic: return "Proxy DNS"
        case .proxyHosts: return "Адреса прокси-серверов"
        case .dnsHosts: return "Адреса DNS-серверов"
        }
    }
    var subtitle: String {
        switch self {
        case .directTraffic: return "DNS для прямого интернет-трафика"
        case .proxyTraffic: return "DNS для проксируемого трафика, включая Gemini"
        case .proxyHosts: return "DNS для подключения к узлам, до запуска прокси"
        case .dnsHosts: return "Начальное разрешение адресов DNS-серверов"
        }
    }
    var icon: String {
        switch self {
        case .directTraffic: return "globe"
        case .proxyTraffic: return "shield"
        case .proxyHosts: return "network"
        case .dnsHosts: return "server.rack"
        }
    }
    var isService: Bool {
        self == .proxyHosts || self == .dnsHosts
    }
}

struct StudioDNSCatalogEntry: Identifiable, Equatable {
    let id: String
    let name: String
    let uri: String
    let source: String
    let isConfigured: Bool

    /// Avoid guessing a DNS role from the transport detour: a DNS server
    /// connected DIRECT may still resolve domains routed through a proxy.
    static func catalog(document: StudioDocument) -> [StudioDNSCatalogEntry] {
        let dns = document.root["dns"] as? [String: Any] ?? [:]
        let configured = (dns["servers"] as? [[String: Any]] ?? []).enumerated().map { index, item in
            let name = item["tag"] as? String ?? "DNS №\(index + 1)"
            return StudioDNSCatalogEntry(
                id: "config:\(index)",
                name: name,
                uri: uri(item),
                source: "Из текущей конфигурации",
                isConfigured: true
            )
        }
        let customURI = Set(configured.map(\.uri))
        let suggested = presets.filter { !customURI.contains($0.uri) }
        return configured + suggested
    }

    /// Canonical *display* URI only. Do not serialize it back into the JSON:
    /// the existing DNS server object may contain TLS, dial and bootstrap data.
    static func uri(_ item: [String: Any]) -> String {
        let kind = item["type"] as? String ?? ""
        let host = item["server"] as? String ?? item["address"] as? String ?? ""
        let port = (item["server_port"] as? NSNumber)?.intValue
        if kind == "local" { return "local" }
        if kind == "dhcp" { return "dhcp://\(host.isEmpty ? "auto" : host)" }
        guard !host.isEmpty else { return kind.isEmpty ? "не указан" : kind }
        let schemes: [String: (String, Int)] = [
            "https": ("https", 443),
            "tls": ("tls", 853),
            "udp": ("udp", 53),
            "tcp": ("tcp", 53),
            "quic": ("quic", 853),
            "h3": ("h3", 443)
        ]
        guard let (scheme, standardPort) = schemes[kind] else {
            return "\(kind.isEmpty ? "dns" : kind)://\(host)"
        }
        let formattedHost = host.contains(":") && !host.hasPrefix("[") &&
            !host.contains("://") ? "[\(host)]" : host
        let portText = (port == nil || port == standardPort) ? "" : ":\(port!)"
        let path: String
        if kind == "https" || kind == "h3" {
            path = (item["path"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "/dns-query"
        } else {
            path = ""
        }
        return "\(scheme)://\(formattedHost)\(portText)\(path)"
    }

    static let presets: [StudioDNSCatalogEntry] = [
        .init(id: "preset:cf-doh1", name: "Cloudflare DNS", uri: "https://1.1.1.1/dns-query", source: "Каталог", isConfigured: false),
        .init(id: "preset:cf-doh2", name: "Cloudflare DNS", uri: "https://1.0.0.1/dns-query", source: "Каталог", isConfigured: false),
        .init(id: "preset:cf-dot", name: "Cloudflare DNS", uri: "tls://1.1.1.1", source: "Каталог", isConfigured: false),
        .init(id: "preset:g-doh1", name: "Google DNS", uri: "https://8.8.8.8/dns-query", source: "Каталог", isConfigured: false),
        .init(id: "preset:g-doh2", name: "Google DNS", uri: "https://8.8.4.4/dns-query", source: "Каталог", isConfigured: false),
        .init(id: "preset:quad9-doh", name: "Quad9 DNS", uri: "https://dns.quad9.net/dns-query", source: "Каталог", isConfigured: false),
        .init(id: "preset:adguard-doh", name: "AdGuard DNS", uri: "https://dns.adguard-dns.com/dns-query", source: "Каталог", isConfigured: false),
        .init(id: "preset:yandex-doh", name: "Яндекс DNS", uri: "https://common.dot.dns.yandex.net/dns-query", source: "Каталог", isConfigured: false)
    ]
}

struct StudioDNSDraftAssignment: Equatable {
    let entryID: String
    var priority: Int
}

struct StudioDNSPriorityGroup: Equatable, Identifiable {
    let priority: Int
    let entries: [StudioDNSDraftAssignment]
    var id: Int { priority }
    var isRace: Bool { entries.count > 1 }
}

/// The priority model is a proposed policy compiler input, not a modification
/// of dns.rules. Same level = parallel candidates; later level = fallback.
enum StudioDNSDraftLogic {
    static func groups(_ selections: [StudioDNSDraftAssignment]) -> [StudioDNSPriorityGroup] {
        let levels = Dictionary(grouping: selections, by: \.priority)
        return levels.keys.sorted().map { level in
            StudioDNSPriorityGroup(priority: level, entries: levels[level] ?? [])
        }
    }
}

@MainActor
final class StudioDNSDraftStore: ObservableObject {
    @Published private(set) var assignments: [StudioDNSRole: [StudioDNSDraftAssignment]] = [:]

    func rows(for role: StudioDNSRole) -> [StudioDNSDraftAssignment] {
        assignments[role] ?? []
    }

    func contains(_ id: String, in role: StudioDNSRole) -> Bool {
        rows(for: role).contains { $0.entryID == id }
    }

    func toggle(_ id: String, for role: StudioDNSRole) {
        var entries = rows(for: role)
        if let index = entries.firstIndex(where: { $0.entryID == id }) {
            entries.remove(at: index)
        } else {
            entries.append(.init(entryID: id, priority: 1))
        }
        assignments[role] = entries
    }

    func changePriority(_ id: String, for role: StudioDNSRole, to priority: Int) {
        guard (1...9).contains(priority) else { return }
        var entries = rows(for: role)
        guard let index = entries.firstIndex(where: { $0.entryID == id }) else { return }
        entries[index].priority = priority
        assignments[role] = entries
    }

    func clear(_ role: StudioDNSRole) {
        assignments[role] = []
    }
}
#endif
