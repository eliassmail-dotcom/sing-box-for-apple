#if os(iOS)
import Foundation
import Library
import SwiftUI

/// Config Studio 1.0: an immutable, lossless *reader* of the profile JSON.
/// Never writes to ProfileManager, subscription storage or NetworkExtension.
@MainActor
public struct ConfigStudioView: View {
    @EnvironmentObject private var environments: ExtensionEnvironments
    @State private var profileName = ""
    @State private var source: StudioDocument?
    @State private var effective: StudioDocument?
    @State private var running: StudioDocument?
    @State private var layer: StudioLayer = .effective
    @State private var errorMessage: String?
    @State private var isLoading = false

    public init() {}

    private var document: StudioDocument? {
        switch layer {
        case .source: source
        case .effective: effective
        case .running: running
        }
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                introduction
                if isLoading {
                    ProgressView("Читаем конфигурацию…")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 36)
                } else if let document {
                    summary(document)
                    layerSelector
                    if layer == .effective {
                        hint("Расчётный JSON: исходный профиль + текущие LX-переопределения. Он может отличаться от уже запущенного туннеля.")
                    } else if layer == .source {
                        hint("Исходный профиль без локальных изменений LX. Он не обязательно совпадает с работающим VPN.")
                    } else {
                        hint("Получен из ядра запущенного туннеля через GetRunningConfig. Это не реконструкция по подписке.")
                    }
                    categories(document)
                    NavigationLink {
                        StudioJSONView(title: "Весь JSON", content: document.raw)
                    } label: {
                        studioRow(icon: "curlybraces.square", title: "Полный JSON", subtitle: "Все поля, включая неизвестные · секреты скрыты", count: nil)
                    }
                    .buttonStyle(.plain)
                    NavigationLink {
                        StudioLocalVariablesView()
                    } label: {
                        studioRow(icon: "slider.horizontal.3", title: "Параметры генератора", subtitle: "Локальные переменные для новых профилей", count: nil)
                    }
                    .buttonStyle(.plain)
                } else if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(24)
                } else {
                    Label("Выберите профиль и повторите загрузку", systemImage: "doc.questionmark")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(24)
                }
                Text("Config Studio 1.0 · Только просмотр конфигурации. Изменения узлов, маршрутов, DNS и OpenConnect появятся в следующем релизе.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 24)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Config Studio")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await reload() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isLoading)
                .accessibilityLabel("Обновить конфигурацию")
            }
        }
        .task { await reload() }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.title2)
                    .foregroundStyle(.tint)
                Spacer()
                Text("READ ONLY")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.thinMaterial, in: Capsule())
            }
            Text("Конфигурация")
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
            Text(profileName.isEmpty ? "Выбранный профиль" : profileName)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22))
    }

    private func summary(_ data: StudioDocument) -> some View {
        let outbounds = data.array("outbounds")
        let groups = outbounds.filter { ["selector", "urltest"].contains($0["type"] as? String ?? "") }
        let endpoints = data.array("endpoints")
        let route = data.root["route"] as? [String: Any] ?? [:]
        let ruleSets = route["rule_set"] as? [Any] ?? []
        return VStack(spacing: 10) {
            HStack(spacing: 10) {
                metric("Узлы", count: outbounds.filter { !["selector", "urltest", "chain"].contains($0["type"] as? String ?? "") }.count, icon: "server.rack")
                metric("Группы", count: groups.count, icon: "rectangle.3.group")
                metric("Туннели", count: endpoints.count, icon: "shield.lefthalf.filled")
            }
            HStack(spacing: 10) {
                metric("Правила", count: (route["rules"] as? [Any] ?? []).count, icon: "arrow.triangle.branch")
                metric("Rule Sets", count: ruleSets.count, icon: "list.bullet.rectangle")
                metric("DNS-правила", count: ((data.root["dns"] as? [String: Any])?["rules"] as? [Any] ?? []).count, icon: "globe")
            }
        }
    }

    private func metric(_ title: String, count: Int, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(count.formatted())
                .font(.system(.title2, design: .rounded, weight: .semibold))
                .monospacedDigit()
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private var layerSelector: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ИСТОЧНИК ДАННЫХ")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Picker("Источник данных", selection: $layer) {
                Text("Исходный").tag(StudioLayer.source)
                Text("С LX").tag(StudioLayer.effective)
                if running != nil {
                    Text("Работает").tag(StudioLayer.running)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private func hint(_ value: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
            Text(value)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private func categories(_ document: StudioDocument) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("СОСТАВ ПРОФИЛЯ")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            ForEach(document.categories) { category in
                NavigationLink {
                    StudioCategoryView(category: category)
                } label: {
                    studioRow(icon: category.icon, title: category.title,
                              subtitle: category.subtitle, count: category.items.count)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func studioRow(icon: String, title: String, subtitle: String, count: Int?) -> some View {
        HStack(spacing: 13) {
            Image(systemName: icon)
                .font(.system(size: 19))
                .foregroundStyle(.tint)
                .frame(width: 38, height: 38)
                .background(Color.accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
            if let count {
                Text(count.formatted())
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        .contentShape(Rectangle())
    }

    private func reload() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        errorMessage = nil
        running = nil
        do {
            let id = await SharedPreferences.selectedProfileID.get()
            guard let profile = try await ProfileManager.get(id) else {
                source = nil
                effective = nil
                errorMessage = "Нет выбранного профиля"
                return
            }
            let profileJSON = try await profile.readAsync()
            let overrideJSON = await SharedPreferences.lxOverridesJSON.get()
            let effectiveJSON = try LXProfileOverrides.apply(profileJSON, profileID: id, storedJSON: overrideJSON)
            let original = try StudioDocument(content: profileJSON)
            let transformed = try StudioDocument(content: effectiveJSON)
            profileName = profile.name
            source = original
            effective = transformed

            // Do not claim that a calculated config is what the tunnel runs.
            if environments.extensionProfile?.status.isConnectedStrict == true,
               let client = try? await CommandTarget.standaloneClient(),
               let runtimeConfig = try? await client.getRunningConfig() {
                running = try? StudioDocument(content: runtimeConfig.content())
            }
            layer = running == nil ? .effective : .running
        } catch {
            source = nil
            effective = nil
            errorMessage = error.localizedDescription
        }
    }
}

private enum StudioLayer: Hashable {
    case source, effective, running
}

/// Lossless snapshot; all unknown keys survive in raw JSON and in sections.
struct StudioDocument {
    let raw: String
    let root: [String: Any]

    init(content: String) throws {
        guard let dictionary = try JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any] else {
            throw NSError(domain: "ConfigStudio", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Корень конфигурации не является JSON-объектом."])
        }
        self.raw = content
        self.root = dictionary
    }

    func array(_ key: String) -> [[String: Any]] {
        root[key] as? [[String: Any]] ?? []
    }

    var categories: [StudioCategory] {
        var categories: [StudioCategory] = []
        var covered: Set<String> = []
        func add(_ key: String, _ title: String, _ detail: String, _ icon: String) {
            guard let value = root[key] else { return }
            covered.insert(key)
            categories.append(StudioCategory(path: key, title: title, subtitle: detail, icon: icon, raw: value))
        }
        add("outbounds", "Все выходы", "Полный список outbounds без исключений", "server.rack")
        if let outbounds = root["outbounds"] as? [[String: Any]] {
            func list(_ path: String, _ name: String, _ subtitle: String, _ icon: String,
                      _ filter: ([String: Any]) -> Bool) {
                let items = outbounds.filter(filter)
                if !items.isEmpty {
                    categories.append(StudioCategory(path: path, title: name,
                                                     subtitle: subtitle, icon: icon, raw: items))
                }
            }
            list("groups", "Группы и селекторы", "Включая технические A–F, если есть", "rectangle.3.group") {
                ["selector", "urltest"].contains($0["type"] as? String ?? "")
            }
            list("chains", "Цепочки", "Native LX chain и связанные хопы", "point.3.connected.trianglepath.dotted") {
                ($0["type"] as? String) == "chain"
            }
            list("nodes", "Прокси-узлы", "VLESS и другие конечные выходы", "server.rack") {
                !["selector", "urltest", "chain", "direct", "block", "dns"].contains($0["type"] as? String ?? "")
            }
        }
        add("endpoints", "Корпоративные туннели", "OpenConnect, WireGuard и другие endpoints", "building.2.crop.circle")
        if let route = root["route"] as? [String: Any] {
            if let rules = route["rules"] {
                categories.append(StudioCategory(path: "route.rules", title: "Правила маршрутизации",
                                                 subtitle: "В точном порядке исполнения", icon: "arrow.triangle.branch", raw: rules))
            }
            if let sets = route["rule_set"] {
                categories.append(StudioCategory(path: "route.rule_set", title: "Списки адресов",
                                                 subtitle: "Локальные и удалённые SRS", icon: "list.bullet.rectangle", raw: sets))
            }
        }
        add("route", "Параметры маршрутизации", "Final, интерфейсы и исходный route JSON", "map")
        if let dns = root["dns"] as? [String: Any] {
            if let servers = dns["servers"] {
                categories.append(StudioCategory(path: "dns.servers", title: "DNS-серверы",
                                                 subtitle: "Адреса, группы, detour, cache", icon: "globe", raw: servers))
            }
            if let rules = dns["rules"] {
                categories.append(StudioCategory(path: "dns.rules", title: "DNS-правила",
                                                 subtitle: "DNS Race, evaluate, respond и маршруты", icon: "list.number", raw: rules))
            }
        }
        add("dns", "DNS · все параметры", "Полная политика DNS и кеширования", "globe")
        add("http_clients", "HTTP-клиенты", "Загрузка SRS и сетевые подключения", "network")
        add("inbounds", "Входящие подключения", "TUN и остальные входящие интерфейсы", "arrow.down.to.line")
        add("experimental", "API и экспериментальные функции", "Clash API, cache_file и другие параметры", "wrench.and.screwdriver")
        add("lx", "LX · расширения ядра", "Специфические параметры sing-box-lx", "bolt.horizontal.circle")
        add("log", "Логирование", "Уровень и направления вывода", "text.alignleft")
        // Unknown future/extension keys are never discarded.
        for key in root.keys.sorted() where !covered.contains(key) {
            categories.append(StudioCategory(path: key, title: key, subtitle: "Дополнительные параметры", icon: "curlybraces", raw: root[key]!))
        }
        return categories
    }
}

struct StudioCategory: Identifiable {
    let path: String
    let title: String
    let subtitle: String
    let icon: String
    let raw: Any
    var id: String { path }

    var items: [StudioItem] {
        if let list = raw as? [Any] {
            return list.enumerated().map { offset, value in
                let dictionary = value as? [String: Any] ?? [:]
                let name = dictionary["tag"] as? String ?? dictionary["name"] as? String
                let type = dictionary["type"] as? String ?? dictionary["action"] as? String ?? ""
                return StudioItem(id: "\(path)[\(offset)]",
                                  title: name ?? (type.isEmpty ? "Запись \(offset + 1)" : "\(offset + 1). \(type)"),
                                  subtitle: name == nil ? StudioDocumentFormatter.summary(value) : type,
                                  raw: value)
            }
        }
        if let object = raw as? [String: Any] {
            return object.keys.sorted().map { key in
                let value = object[key]!
                return StudioItem(id: "\(path).\(key)", title: key,
                                  subtitle: StudioDocumentFormatter.summary(value, key: key), raw: value)
            }
        }
        return [StudioItem(id: path, title: title, subtitle: "", raw: raw)]
    }
}

struct StudioItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let raw: Any
}

enum StudioDocumentFormatter {
    static func summary(_ value: Any, key: String = "") -> String {
        if let array = value as? [Any] { return "\(array.count) элементов" }
        if let object = value as? [String: Any] {
            return (object["type"] as? String) ?? (object["action"] as? String) ?? "\(object.count) полей"
        }
        if let text = value as? String {
            let safe = sanitized(text, key: key) as? String ?? "•••"
            return safe.count > 70 ? String(safe.prefix(70)) + "…" : safe
        }
        return String(describing: value)
    }

    static func sanitized(_ value: Any, key: String = "") -> Any {
        let normalized = key.lowercased().replacingOccurrences(of: "-", with: "_")
        let protected = ["password", "passwd", "token", "secret", "private_key", "uuid", "credential",
                         "authorization", "cookie", "client_secret", "api_key", "short_id"]
        if protected.contains(where: { normalized.contains($0) }) ||
            normalized == "key" || normalized.hasSuffix("_key") {
            return "••••••"
        }
        if let dictionary = value as? [String: Any] {
            var result: [String: Any] = [:]
            for (field, fieldValue) in dictionary {
                result[field] = sanitized(fieldValue, key: field)
            }
            return result
        }
        if let array = value as? [Any] {
            return array.map { sanitized($0) }
        }
        if let string = value as? String {
            if var url = URLComponents(string: string), url.scheme != nil, url.host != nil {
                if url.user != nil { url.user = "•••" }
                if url.password != nil { url.password = "•••" }
                if let items = url.queryItems {
                    url.queryItems = items.map { item in
                        let lower = item.name.lowercased()
                        let sensitive = ["token", "key", "password", "secret", "auth"].contains { lower.contains($0) }
                        return URLQueryItem(name: item.name, value: sensitive ? "•••" : item.value)
                    }
                }
                return url.string ?? string
            }
            return string
        }
        return value
    }

    static func pretty(_ value: Any) -> String {
        let redacted = sanitized(value)
        guard JSONSerialization.isValidJSONObject(redacted),
              let data = try? JSONSerialization.data(withJSONObject: redacted, options: [.prettyPrinted, .sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return String(describing: redacted)
        }
        return string
    }
}

private struct StudioCategoryView: View {
    let category: StudioCategory
    @State private var query = ""

    private var filtered: [StudioItem] {
        guard !query.isEmpty else { return category.items }
        return category.items.filter { $0.title.localizedCaseInsensitiveContains(query) ||
            $0.subtitle.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        List {
            Section {
                Text(category.subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Элементы · \(category.items.count)") {
                ForEach(filtered) { item in
                    NavigationLink {
                        StudioJSONView(title: item.title, content: StudioDocumentFormatter.pretty(item.raw), isSanitized: true)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title).font(.subheadline.weight(.medium))
                            if !item.subtitle.isEmpty {
                                Text(item.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            Section {
                NavigationLink("JSON раздела") {
                    StudioJSONView(title: category.title, content: StudioDocumentFormatter.pretty(category.raw), isSanitized: true)
                }
            }
        }
        .navigationTitle(category.title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Найти в разделе")
    }
}

private struct StudioJSONView: View {
    let title: String
    let content: String
    var isSanitized = false

    private var safeContent: String {
        if isSanitized { return content }
        guard let object = try? JSONSerialization.jsonObject(with: Data(content.utf8)) else {
            return "Не удалось прочитать JSON."
        }
        return StudioDocumentFormatter.pretty(object)
    }

    var body: some View {
        VStack(spacing: 8) {
            Label("Секретные поля и токены скрыты", systemImage: "lock.shield")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            ScrollView([.vertical, .horizontal]) {
                Text(safeContent)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(uiColor: .secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 14))
        }
        .padding(12)
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
#endif
