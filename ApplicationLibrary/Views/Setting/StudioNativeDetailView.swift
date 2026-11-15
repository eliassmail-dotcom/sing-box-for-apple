#if os(iOS)
import CoreFoundation
import Foundation
import SwiftUI

// Config Studio's view-only, schema-aware presentation layer.
// Unknown keys always fall back to typed fields, nested groups and lists;
// no user-facing object relies on an inline JSON editor.
enum StudioHumanFields {
    static let names: [String: String] = [
        "tag": "Название", "name": "Название", "type": "Тип",
        "server": "Сервер", "server_port": "Порт сервера", "port": "Порт",
        "outbound": "Маршрут", "outbounds": "Участники", "detour": "Через",
        "default": "По умолчанию", "final": "Маршрут по умолчанию",
        "mode": "Алгоритм", "action": "Действие",
        "interval": "Интервал проверки", "idle_timeout": "Простой",
        "tolerance": "Порог задержки", "url": "Адрес проверки или источника",
        "urls": "Адреса проверки", "interrupt_exist_connections": "Прерывать действующие соединения",
        "adaptive_tolerance_percent": "Адаптивный порог", "min_hold": "Минимальное удержание",
        "balancer": "Балансировка", "pool": "Размер пула",
        "pool_tolerance": "Порог пула", "sticky_hash": "Закрепление соединений",
        "domain": "Точный домен", "domain_suffix": "Домены и поддомены",
        "domain_keyword": "Ключевые слова доменов", "domain_regex": "Выражения доменов",
        "ip_cidr": "IP-адреса и подсети", "source_ip_cidr": "Исходные сети",
        "ip_is_private": "Частные IP-адреса", "rule_set": "Списки адресов",
        "rule_set_ip_cidr_match_source": "Списки: исходный IP",
        "network": "Сетевой протокол", "protocol": "Прикладной протокол",
        "network_type": "Тип подключения", "wifi_ssid": "Имя Wi-Fi", "wifi_bssid": "BSSID Wi-Fi",
        "port_range": "Диапазоны портов", "source_port": "Порт источника",
        "source_port_range": "Диапазоны портов источника",
        "inbound": "Входящие подключения", "ip_version": "Версия IP",
        "process_name": "Название процесса", "process_path": "Путь процесса",
        "package_name": "Приложения", "clash_mode": "Режим Clash",
        "sniff": "Распознавание протокола", "resolve": "Разрешение DNS",
        "rules": "Правила", "logical": "Логика",
        "enabled": "Включено", "disable_cache": "Отключить кеш",
        "disable_expire": "Не удалять устаревший кеш", "independent_cache": "Независимый кеш",
        "reverse_mapping": "Обратное сопоставление DNS",
        "strategy": "Стратегия IP", "cache_capacity": "Размер DNS-кеша",
        "servers": "Серверы", "address": "Адрес", "address_resolver": "DNS-резолвер адреса",
        "address_strategy": "Стратегия разрешения адреса",
        "client_subnet": "Клиентская подсеть",
        "tls": "Защищённое соединение TLS", "reality": "REALITY",
        "server_name": "Имя сервера TLS", "alpn": "ALPN", "insecure": "Не проверять сертификат",
        "utls": "uTLS", "fingerprint": "Отпечаток клиента",
        "transport": "Транспорт", "flow": "Поток", "uuid": "Идентификатор клиента",
        "password": "Пароль", "username": "Пользователь", "user": "Пользователь",
        "private_key": "Закрытый ключ", "public_key": "Открытый ключ",
        "short_id": "REALITY Short ID", "encryption": "Шифрование",
        "multiplex": "Мультиплексирование", "packet_encoding": "Формат пакетов",
        "headers": "HTTP-заголовки", "host": "Хост", "path": "Путь",
        "http_client": "HTTP-клиент", "http_clients": "HTTP-клиенты",
        "update_interval": "Обновление", "format": "Формат списка",
        "download_detour": "Маршрут загрузки", "cache_file": "Кеш конфигурации",
        "clash_api": "Clash API", "external_controller": "Контроллер",
        "secret": "Ключ доступа", "allow_external": "Внешние подключения",
        "auto_route": "Автоматическая маршрутизация",
        "auto_detect_interface": "Автоопределение интерфейса",
        "strict_route": "Строгая маршрутизация", "interface_name": "Сетевой интерфейс",
        "route_address": "Адреса для маршрутизации",
        "route_exclude_address": "Исключённые адреса",
        "mtu": "MTU", "stack": "Сетевой стек", "sniff_override_destination": "Подмена адреса по SNI",
        "udp_timeout": "Тайм-аут UDP", "tcp_fast_open": "TCP Fast Open",
        "connect_timeout": "Тайм-аут подключения",
        "dialer": "Параметры соединения", "domain_strategy": "Стратегия DNS",
        "endpoint": "Конечная точка", "endpoints": "Конечные точки",
        "routes": "Маршруты", "dns": "DNS", "response_rcode": "Код ответа DNS",
        "match_response": "Проверка ответа DNS", "ip_accept_any": "Принимать любые IP",
        "race": "Параллельная проверка", "speculative": "Предварительное разрешение",
        "cache": "Кеш", "timeout": "Тайм-аут",
        "inet4_address": "IPv4-адрес", "inet6_address": "IPv6-адрес",
        "redirect": "Перенаправление", "interface": "Интерфейс",
        "tun": "TUN", "log": "Журнал",
        "level": "Уровень журналирования",
    ]

    static func label(_ key: String) -> String {
        if let name = names[key] { return name }
        let words = key.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        return words.prefix(1).uppercased() + String(words.dropFirst())
    }

    static func kind(_ type: String) -> String {
        switch type {
        case "vless": return "VLESS · прокси-сервер"
        case "selector": return "Ручной выбор из группы"
        case "urltest": return "Автоматическая группа"
        case "chain": return "Цепочка узлов"
        case "direct": return "Прямое соединение"
        case "block": return "Блокировка"
        case "openconnect": return "Корпоративный OpenConnect"
        case "wireguard": return "WireGuard"
        case "tun": return "Системный TUN"
        case "remote": return "Внешний список"
        case "local": return "Локальный список"
        case "https": return "DNS через HTTPS"
        case "tls": return "DNS через TLS"
        case "udp": return "UDP"
        case "tcp": return "TCP"
        case "logical": return "Логическая группа условий"
        default: return type.isEmpty ? "Параметры конфигурации" : type
        }
    }

    static func mode(_ mode: String) -> String {
        switch mode {
        case "least_test": return "Самый быстрый доступный"
        case "failover": return "Резервирование"
        case "round_robin": return "Чередование узлов"
        case "and": return "Все условия (И)"
        case "or": return "Любое условие (ИЛИ)"
        default: return mode
        }
    }

    static func action(_ action: String) -> String {
        switch action {
        case "route": return "Направить в выбранный маршрут"
        case "reject": return "Заблокировать"
        case "hijack-dns": return "Перехватить DNS"
        case "sniff": return "Определить протокол"
        case "resolve": return "Разрешить домен"
        case "evaluate": return "Проверить DNS"
        case "respond": return "Ответить DNS"
        case "predefined": return "Заданный ответ"
        default: return action
        }
    }

    static func isBoolean(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    static func display(_ value: Any, key: String) -> String {
        let safe = StudioDocumentFormatter.sanitized(value, key: key)
        if isBoolean(safe) {
            return (safe as? NSNumber)?.boolValue == true ? "Включено" : "Выключено"
        }
        if let number = safe as? NSNumber {
            let str = number.stringValue
            switch key {
            case "interval", "idle_timeout", "timeout", "min_hold",
                 "update_interval", "connect_timeout", "udp_timeout":
                return str
            case "tolerance", "pool_tolerance": return "\(str) мс"
            case "adaptive_tolerance_percent": return "\(str)%"
            default: return str
            }
        }
        if let str = safe as? String {
            if key == "mode" { return mode(str) }
            if key == "action" { return action(str) }
            if key == "type" { return kind(str) }
            return str
        }
        if safe is NSNull { return "Не задано" }
        return String(describing: safe)
    }

    static func fieldIcon(_ key: String) -> String {
        if key.contains("domain") || key.contains("host") { return "globe" }
        if key.contains("ip") || key.contains("cidr") { return "network" }
        if key.contains("port") { return "number" }
        if key.contains("dns") { return "network.badge.shield.half.filled" }
        if key.contains("rule") { return "list.bullet.rectangle" }
        if key.contains("url") { return "link" }
        if key.contains("tls") || key.contains("cert") { return "lock.shield" }
        if key == "outbounds" || key == "servers" { return "rectangle.3.group" }
        return "slider.horizontal.3"
    }

    static let destinationFields: Set<String> = [
        "action", "outbound", "server", "disable_cache",
        "rewrite_ttl", "rcode", "response_rcode"
    ]
}

/// An ordinary iOS settings/detail screen for any sing-box/LX object.
/// All nested dictionaries and arrays remain navigable, with no JSON leaf.
struct StudioNativeDetailView: View {
    let title: String
    let path: String
    let value: Any

    private var object: [String: Any]? { value as? [String: Any] }
    private var list: [Any]? { value as? [Any] }
    private var type: String { object?["type"] as? String ?? "" }
    private var isRule: Bool {
        path.hasPrefix("route.rules") || path.hasPrefix("dns.rules")
    }
    private var isChain: Bool { type == "chain" }
    private var isGroup: Bool { type == "selector" || type == "urltest" }

    var body: some View {
        List {
            if let object {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            Image(systemName: iconName)
                                .font(.title2)
                                .foregroundStyle(.tint)
                                .frame(width: 38)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(object["tag"] as? String ?? title)
                                    .font(.headline)
                                Text(StudioHumanFields.kind(type))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if isRule {
                            Text("Условия проверяются в порядке правил конфигурации.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 8)
                }
                if isRule { ruleSections(object) }
                else if isChain { chainSections(object) }
                else if isGroup { groupSections(object) }
                else { standardSections(object) }
            } else if let list {
                Section("\(list.count) элементов") {
                    ForEach(list.indices, id: \.self) { index in
                        StudioValueRow(key: "\(index + 1)", value: list[index],
                                       path: "\(path)[\(index)]")
                    }
                }
            } else {
                Section("Значение") {
                    StudioValueRow(key: title, value: value, path: path)
                }
            }
            Section {
                Label("Этот экран только отображает параметры действительной конфигурации. Ничего не меняется.", systemImage: "eye")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    NavigationLink {
                        StudioJSONView(title: title,
                                       content: StudioDocumentFormatter.pretty(value),
                                       isSanitized: true)
                    } label: {
                        Label("Технический JSON", systemImage: "curlybraces")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Дополнительно")
            }
        }
    }

    private var iconName: String {
        if isChain { return "link" }
        if isGroup { return "rectangle.3.group.fill" }
        if isRule { return "arrow.triangle.branch" }
        if type == "vless" { return "server.rack" }
        if type == "openconnect" { return "building.2.crop.circle" }
        if path.contains("rule_set") { return "list.bullet.rectangle" }
        if path.contains("dns") { return "globe" }
        return "slider.horizontal.3"
    }

    @ViewBuilder
    private func ruleSections(_ rule: [String: Any]) -> some View {
        let action = rule["action"] as? String ?? ""
        let route = rule["outbound"] as? String
        let dnsServer = rule["server"] as? String
        Section("Что происходит при совпадении") {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text(action.isEmpty ? (route == nil ? "DNS / действие из правила" : "Маршрутизация") :
                        StudioHumanFields.action(action))
                        .font(.subheadline.weight(.medium))
                    if let route { Text("Через: \(route)").foregroundStyle(.secondary).font(.footnote) }
                    if let dnsServer { Text("DNS: \(dnsServer)").foregroundStyle(.secondary).font(.footnote) }
                }
            } icon: {
                Image(systemName: action == "reject" ? "hand.raised.slash" : "arrow.turn.down.right")
            }
            if let mode = rule["mode"] as? String {
                Label(StudioHumanFields.mode(mode), systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.subheadline)
            }
        }
        let conditions = rule.keys.sorted().filter {
            !StudioHumanFields.destinationFields.contains($0) && $0 != "type" && $0 != "mode"
        }
        if !conditions.isEmpty {
            Section("Условия совпадения") {
                ForEach(conditions, id: \.self) { key in
                    StudioValueRow(key: key, value: rule[key]!, path: "\(path).\(key)")
                }
            }
        }
        let extras = rule.keys.sorted().filter {
            StudioHumanFields.destinationFields.contains($0) && $0 != "action" &&
            $0 != "outbound" && $0 != "server"
        }
        if !extras.isEmpty {
            Section("Дополнительные настройки действия") {
                ForEach(extras, id: \.self) { key in
                    StudioValueRow(key: key, value: rule[key]!, path: "\(path).\(key)")
                }
            }
        }
    }

    @ViewBuilder
    private func chainSections(_ chain: [String: Any]) -> some View {
        if let hops = chain["outbounds"] as? [String] {
            Section("Порядок хопов") {
                ForEach(hops.indices, id: \.self) { index in
                    HStack(spacing: 12) {
                        Text("\(index + 1)")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.tint)
                            .frame(width: 26, height: 26)
                            .background(Color.accentColor.opacity(0.11), in: Circle())
                        Text(hops[index]).font(.subheadline.weight(.medium))
                        Spacer()
                        if index == hops.count - 1 {
                            Text("Выход").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        settingsSection(chain, excluding: ["outbounds", "tag"])
    }

    @ViewBuilder
    private func groupSections(_ group: [String: Any]) -> some View {
        if let members = group["outbounds"] as? [String] {
            Section("Участники · \(members.count)") {
                ForEach(members.indices, id: \.self) { index in
                    HStack(spacing: 10) {
                        Image(systemName: "circle.grid.2x2")
                            .foregroundStyle(.secondary)
                        Text(members[index]).font(.subheadline)
                        Spacer()
                        if members[index] == group["default"] as? String {
                            Text("По умолчанию")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        if type == "urltest" {
            Section("Механизм выбора") {
                StudioValueRow(key: "mode", value: group["mode"] ?? "least_test",
                               path: "\(path).mode")
                if let interval = group["interval"] {
                    StudioValueRow(key: "interval", value: interval, path: "\(path).interval")
                }
                if let tolerance = group["tolerance"] {
                    StudioValueRow(key: "tolerance", value: tolerance, path: "\(path).tolerance")
                }
            }
        }
        settingsSection(group, excluding: ["outbounds", "tag", "mode", "interval", "tolerance"])
    }

    @ViewBuilder
    private func standardSections(_ value: [String: Any]) -> some View {
        settingsSection(value, excluding: [])
    }

    @ViewBuilder
    private func settingsSection(_ object: [String: Any], excluding skipped: Set<String>) -> some View {
        let keys = object.keys.sorted().filter { !skipped.contains($0) }
        if !keys.isEmpty {
            Section("Параметры") {
                ForEach(keys, id: \.self) { key in
                    StudioValueRow(key: key, value: object[key]!,
                                   path: "\(path).\(key)")
                }
            }
        }
    }
}

/// A field stays a native row: scalar status, boolean indicator, or navigation
/// into the next structured object/list. In particular, it never opens JSON.
struct StudioValueRow: View {
    let key: String
    let value: Any
    let path: String

    var body: some View {
        if let array = value as? [Any] {
            NavigationLink {
                StudioNativeDetailView(title: StudioHumanFields.label(key),
                                       path: path, value: array)
            } label: {
                HStack(spacing: 11) {
                    Image(systemName: StudioHumanFields.fieldIcon(key))
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(StudioHumanFields.label(key))
                            .font(.subheadline)
                        if let preview = array.first {
                            Text(StudioHumanFields.display(preview, key: key))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    Text("\(array.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
        } else if let object = value as? [String: Any] {
            NavigationLink {
                StudioNativeDetailView(title: StudioHumanFields.label(key),
                                       path: path, value: object)
            } label: {
                HStack(spacing: 11) {
                    Image(systemName: StudioHumanFields.fieldIcon(key))
                        .foregroundStyle(.tint)
                    Text(StudioHumanFields.label(key)).font(.subheadline)
                    Spacer()
                    Text("\(object.count) полей")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(StudioHumanFields.label(key))
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                if StudioHumanFields.isBoolean(value) {
                    let state = (value as? NSNumber)?.boolValue == true
                    Label(state ? "Включено" : "Выключено",
                          systemImage: state ? "checkmark.circle.fill" : "circle")
                        .font(.footnote)
                        .foregroundStyle(state ? Color.green : Color.secondary)
                        .labelStyle(.titleAndIcon)
                } else {
                    Text(StudioHumanFields.display(value, key: key))
                        .font(.subheadline)
                        .multilineTextAlignment(.trailing)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .padding(.vertical, 5)
        }
    }
}
#endif
