#if os(iOS)
import Foundation
import SwiftUI

/// Config Studio 1.1: native semantic home backed by the actual profile.
/// No route or DNS edits are sent to Libbox, NetworkExtension or Yandex.
struct StudioSemanticHomeView: View {
    let document: StudioDocument
    private var model: StudioSemanticModel { StudioSemanticModel(document: document) }

    var body: some View {
        let info = model
        VStack(alignment: .leading, spacing: 13) {
            Text("ПОЛИТИКИ ПОДКЛЮЧЕНИЯ")
                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            NavigationLink {
                StudioDefaultPolicyView(model: info)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.triangle.branch")
                        .foregroundStyle(.tint)
                        .frame(width: 32)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("По умолчанию").font(.headline)
                        Text("Маршрут: \(info.defaultRoute ?? "не задан") · DNS: \(info.defaultDNS ?? "не задан")")
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
                .padding(14)
                .background(Color(uiColor: .secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 16))
            }
            .buttonStyle(.plain)

            Text("КОНФИГУРАЦИЯ ПО СМЫСЛУ")
                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.top, 5)
            entry(title: "Узлы", description: "Серверы и параметры подключения",
                  icon: "server.rack",
                  count: document.array("outbounds").filter {
                      !["selector", "urltest", "chain", "direct", "block", "dns"].contains($0["type"] as? String ?? "")
                  }.count) {
                StudioNativeDetailView(title: "Узлы", path: "outbounds",
                    value: document.array("outbounds").filter {
                        !["selector", "urltest", "chain", "direct", "block", "dns"].contains($0["type"] as? String ?? "")
                    })
            }
            entry(title: "Группы узлов", description: "Состав, вложенные группы и фильтры",
                  icon: "rectangle.3.group", count: info.groups.count) {
                StudioGroupListView(model: info)
            }
            entry(title: "Стратегии", description: "Ручной выбор, URLTest и приоритеты",
                  icon: "brain.head.profile", count: info.strategies.count) {
                StudioStrategyListView(model: info)
            }
            entry(title: "Группы адресов", description: "Совпадения, маршруты и связанные DNS-правила",
                  icon: "list.bullet.rectangle", count: info.addressPolicies.count) {
                StudioAddressPolicyListView(model: info)
            }
            entry(title: "DNS", description: "Серверы, политики и проверка ответов",
                  icon: "globe", count: info.dnsPolicies.count) {
                StudioDNSOverviewView(model: info)
            }
            entry(title: "Корпоративные подключения", description: "OpenConnect и другие endpoints",
                  icon: "building.2.crop.circle",
                  count: document.array("endpoints").count) {
                StudioNativeDetailView(title: "Корпоративные подключения", path: "endpoints",
                                       value: document.array("endpoints"))
            }
            entry(title: "Цепочки", description: "Хопы и порядок подключения",
                  icon: "point.3.connected.trianglepath.dotted",
                  count: document.array("outbounds").filter { ($0["type"] as? String) == "chain" }.count) {
                StudioNativeDetailView(title: "Цепочки", path: "outbounds",
                                       value: document.array("outbounds").filter {
                                           ($0["type"] as? String) == "chain"
                                       })
            }
            entry(title: "Параметры сети", description: "TUN, HTTP-клиенты, LX и расширения",
                  icon: "network", count: nil) {
                StudioAdditionalSettingsView(document: document)
            }
            Text("Техническая структура JSON доступна отдельно. Сетевой профиль при просмотре не меняется.")
                .font(.footnote).foregroundStyle(.secondary)
                .padding(.vertical, 8)
        }
    }

    private func entry<Destination: View>(
        title: String, description: String, icon: String,
        count: Int?, @ViewBuilder destination: () -> Destination
    ) -> some View {
        NavigationLink { destination() } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .foregroundStyle(.tint)
                    .frame(width: 34, height: 34)
                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.subheadline.weight(.semibold))
                    Text(description).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                if let count {
                    Text("\(count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(Color(uiColor: .secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 15))
        }
        .buttonStyle(.plain)
    }
}

private struct StudioGroupListView: View {
    let model: StudioSemanticModel
    @State private var query = ""
    private var filtered: [StudioSemanticModel.NodeGroup] {
        query.isEmpty ? model.groups : model.groups.filter {
            $0.id.localizedCaseInsensitiveContains(query) ||
            $0.memberOrder.contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    var body: some View {
        List {
            Section {
                Text("Группа отвечает только за состав участников. Способ выбора и переключения настраивается стратегией.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Состав групп") {
                ForEach(filtered) { group in
                    NavigationLink {
                        StudioGroupDetailsView(group: group)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(group.id).font(.subheadline.weight(.medium))
                            Text("\(group.composition) · \(group.explicitNodes.count) узлов · \(group.memberGroups.count) вложенных групп")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .searchable(text: $query, prompt: "Узел или группа")
        .navigationTitle("Группы узлов")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct StudioGroupDetailsView: View {
    let group: StudioSemanticModel.NodeGroup

    var body: some View {
        List {
            Section {
                StudioLabelValue("Состав", value: group.composition)
                StudioLabelValue("Узлов после раскрытия", value: "\(group.resolvedNodes.count)")
            }
            if !group.explicitNodes.isEmpty {
                Section("Выбраны вручную") {
                    ForEach(group.explicitNodes, id: \.self) { tag in
                        Label(tag, systemImage: "server.rack")
                    }
                }
            }
            if !group.memberGroups.isEmpty {
                Section("Вложенные группы") {
                    ForEach(group.memberGroups, id: \.self) { groupName in
                        Label(groupName, systemImage: "rectangle.3.group")
                    }
                }
            }
            if !group.includePatterns.isEmpty || !group.excludePatterns.isEmpty {
                Section("Динамические фильтры") {
                    ForEach(group.includePatterns, id: \.self) { name in
                        Label("Include: \(name)", systemImage: "plus.circle")
                    }
                    ForEach(group.excludePatterns, id: \.self) { name in
                        Label("Exclude: \(name)", systemImage: "minus.circle")
                    }
                }
            }
            if !group.resolvedNodes.isEmpty {
                Section("Итоговые участники") {
                    ForEach(group.resolvedNodes, id: \.self) { name in
                        Text(name)
                    }
                }
            }
            if !group.unresolvedReferences.isEmpty || !group.cycles.isEmpty {
                Section("Обнаруженные зависимости") {
                    ForEach(group.unresolvedReferences, id: \.self) {
                        Label("Нет ссылки на узел: \($0)", systemImage: "exclamationmark.triangle")
                    }
                    ForEach(group.cycles, id: \.self) {
                        Label("Циклическая ссылка: \($0)", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
            }
            Section {
                Text("Динамические фильтры показываются, только если они действительно есть в источнике. Логика будущего редактора сможет смешивать фильтры и вложенные группы.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(group.id)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct StudioStrategyListView: View {
    let model: StudioSemanticModel
    var body: some View {
        List {
            Section {
                Text("Стратегия отвечает за выбор узла из одной или нескольких групп. Технический selector не требуется настраивать вручную.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Стратегии текущего профиля") {
                ForEach(model.strategies) { strategy in
                    NavigationLink {
                        StudioStrategyDetailsView(strategy: strategy)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(strategy.id).font(.subheadline.weight(.medium))
                            Text(strategy.readableKind).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section("Многоуровневое резервирование") {
                Text("Модель поддерживает произвольное количество уровней с проверками URLTest, реальной доступности и учётом карантина. Если конфигурация не описывает уровни явно, приложение не выдумывает их порядок.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Стратегии")
        .navigationBarTitleDisplayMode(.inline)
    }
}
private struct StudioStrategyDetailsView: View {
    let strategy: StudioSemanticModel.Strategy
    var body: some View {
        List {
            Section("Способ выбора") {
                StudioLabelValue("Алгоритм", value: strategy.readableKind)
                if let algorithm = strategy.algorithm, !strategy.priorityOutbounds.isEmpty {
                    StudioLabelValue("Внутри уровня", value: StudioHumanFields.mode(algorithm))
                }
            }
            if !strategy.priorityOutbounds.isEmpty {
                Section("Очередь резервирования · 2 уровня LX") {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("1 · Приоритетные").font(.subheadline.weight(.semibold))
                        Text(strategy.priorityOutbounds.joined(separator: ", "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text("2 · Резервные").font(.subheadline.weight(.semibold))
                        Text(strategy.fallbackOutbounds.isEmpty ? "Не указаны" :
                                strategy.fallbackOutbounds.joined(separator: ", "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Это реальные уровни из priority_outbounds. При восстановлении доступного основного узла ядро возвращается к первому уровню.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            if !strategy.participantGroups.isEmpty {
                Section("Используемые группы") {
                    ForEach(strategy.participantGroups, id: \.self) {
                        Label($0, systemImage: "rectangle.3.group")
                    }
                }
            }
            if !strategy.participantNodes.isEmpty {
                Section("Прямые участники") {
                    ForEach(strategy.participantNodes, id: \.self) {
                        Label($0, systemImage: "server.rack")
                    }
                }
            }
            if strategy.verifiedPriorityLevels.isEmpty && strategy.priorityOutbounds.isEmpty {
                Section {
                    Text("Отдельная очередь резервирования здесь не задана. Обычный порядок участников selector/urltest не означает N уровней приоритета.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section("Дополнительные параметры") {
                NavigationLink {
                    StudioNativeDetailView(title: strategy.id, path: "strategy",
                                           value: strategy.raw)
                } label: {
                    Label("Все параметры стратегии", systemImage: "slider.horizontal.3")
                }
            }
        }
        .navigationTitle(strategy.id)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct StudioDNSOverviewView: View {
    let model: StudioSemanticModel
    var body: some View {
        List {
            Section("DNS по умолчанию") {
                StudioLabelValue("Сервер", value: model.defaultDNS ?? "Не задан")
            }
            Section("DNS-серверы · \(model.dnsServers.count)") {
                ForEach(model.dnsServers) { server in
                    NavigationLink {
                        StudioNativeDetailView(title: server.name, path: "dns.servers",
                                               value: server.raw)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(server.name).font(.subheadline.weight(.medium))
                            Text([StudioHumanFields.kind(server.type), server.host, server.detour.map { "через \($0)" }]
                                .compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section("Политики DNS · \(model.dnsPolicies.count)") {
                ForEach(model.dnsPolicies) { policy in
                    NavigationLink {
                        StudioDNSPolicyDetailsView(model: model, policy: policy)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(policy.summary).font(.subheadline.weight(.medium))
                            Text("\(policy.indices.count) правил · №\(policy.indices.first.map { $0 + 1 } ?? 0) и далее")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section {
                Text("Правила сгруппированы по DNS-серверу, действию и обработке ответов. Исходные номера сохранены; порядок исполнения не меняется.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("DNS")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct StudioDNSPolicyDetailsView: View {
    let model: StudioSemanticModel
    let policy: StudioSemanticModel.DNSPolicy

    private var rules: [[String: Any]] {
        (model.document.root["dns"] as? [String: Any])?["rules"] as? [[String: Any]] ?? []
    }
    var body: some View {
        List {
            Section("Назначение") {
                StudioLabelValue("Действие", value: StudioHumanFields.action(policy.action))
                if let server = policy.server { StudioLabelValue("DNS-сервер", value: server) }
                if policy.race { Label("Параллельная обработка ответов", systemImage: "arrow.triangle.branch") }
                if policy.speculative { Label("Предварительное разрешение", systemImage: "bolt") }
                if policy.matchesEvaluatedResponse { Label("Проверка ответа DNS", systemImage: "checkmark.shield") }
            }
            Section("Исходные правила · \(policy.indices.count)") {
                ForEach(policy.indices, id: \.self) { index in
                    if rules.indices.contains(index) {
                        NavigationLink {
                            StudioNativeDetailView(title: "DNS-правило №\(index + 1)",
                                                   path: "dns.rules[\(index)]",
                                                   value: rules[index])
                        } label: {
                            Text("Правило №\(index + 1)")
                        }
                    }
                }
            }
        }
        .navigationTitle(policy.server ?? "DNS-политика")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct StudioAddressPolicyListView: View {
    let model: StudioSemanticModel
    @State private var search = ""
    private var filtered: [StudioSemanticModel.AddressPolicy] {
        search.isEmpty ? model.addressPolicies : model.addressPolicies.filter {
            $0.title.localizedCaseInsensitiveContains(search)
        }
    }
    var body: some View {
        List {
            Section("Общие настройки") {
                StudioLabelValue("Маршрут", value: model.defaultRoute ?? "Не указан")
                StudioLabelValue("DNS", value: model.defaultDNS ?? "Не указан")
            }
            Section("Группы адресов и исключения") {
                ForEach(filtered) { item in
                    NavigationLink {
                        StudioAddressPolicyDetailsView(model: model, policy: item)
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(item.title).font(.subheadline.weight(.medium))
                            Text("Маршруты: \(item.destinations.isEmpty ? "наследуют общие" : item.destinations.joined(separator: ", "))")
                                .font(.caption).foregroundStyle(.secondary)
                            Text("DNS: \(item.dnsTargets.isEmpty ? "отдельная политика не выявлена" : item.dnsTargets.joined(separator: ", "))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section {
                Text("Совпадающие условия из DNS и Route не гарантируют итоговый маршрут: порядок, предварительные проверки и более ранние правила по-прежнему имеют значение.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .searchable(text: $search)
        .navigationTitle("Группы адресов")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct StudioAddressPolicyDetailsView: View {
    let model: StudioSemanticModel
    let policy: StudioSemanticModel.AddressPolicy
    var body: some View {
        List {
            Section("Условия") {
                ForEach(policy.conditions.keys.sorted(), id: \.self) { key in
                    StudioValueRow(key: key, value: policy.conditions[key]!,
                                   path: "address.\(key)")
                }
            }
            Section("Маршрутизация") {
                StudioLabelValue("Указанные назначения",
                               value: policy.destinations.isEmpty ? "Не найдены" : policy.destinations.joined(separator: ", "))
                StudioLabelValue("Правила №",
                               value: policy.routeRules.map { String($0 + 1) }.joined(separator: ", "))
            }
            Section("DNS") {
                StudioLabelValue("Указанные серверы",
                               value: policy.dnsTargets.isEmpty ? "Нет точного совпадения условий" : policy.dnsTargets.joined(separator: ", "))
                StudioLabelValue("DNS-правила №",
                               value: policy.dnsRules.map { String($0 + 1) }.joined(separator: ", "))
            }
            Section("Будущая связь маршрута и DNS") {
                NavigationLink {
                    StudioRouteDNSPreviewView(
                        model: model, addressTitle: policy.title,
                        currentRoute: policy.destinations.count == 1 ? policy.destinations[0] : nil,
                        currentDNS: policy.dnsTargets.count == 1 ? policy.dnsTargets[0] : nil,
                        dnsHasExplicitOverride: !policy.dnsTargets.isEmpty
                    )
                } label: {
                    Label("Проверить автопереключение DNS", systemImage: "arrow.left.arrow.right")
                }
                Text("Демонстрация расчёта: без применения настроек к VPN.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(policy.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct StudioDefaultPolicyView: View {
    let model: StudioSemanticModel
    @State private var selectedRoute = ""
    @State private var mappings: [String: String] = [:]

    private var availableRoutes: [String] {
        let routeTags = model.document.array("outbounds").compactMap { $0["tag"] as? String }
        return Array(Set(routeTags + ["direct"])).sorted()
    }
    private var association: StudioDNSFollowRoute.Assignment {
        StudioDNSFollowRoute.resolve(route: selectedRoute, choice: .automatic,
                                     association: mappings, defaultDNS: model.defaultDNS)
    }

    var body: some View {
        Form {
            Section("Фактическая конфигурация") {
                StudioLabelValue("Маршрут по умолчанию", value: model.defaultRoute ?? "Не указан")
                StudioLabelValue("DNS по умолчанию", value: model.defaultDNS ?? "Не указан")
                if let client = model.defaultHTTPClient {
                    StudioLabelValue("Служебная загрузка", value: client)
                }
            }
            Section {
                Label("Ниже — проверка будущей логики Route → DNS. Настройки не сохраняются и не меняют VPN.",
                      systemImage: "eye")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Предпросмотр привязки DNS") {
                Picker("Маршрут", selection: $selectedRoute) {
                    ForEach(availableRoutes, id: \.self) { tag in Text(tag).tag(tag) }
                }
                if !selectedRoute.isEmpty {
                    Picker("DNS для маршрута", selection: Binding(
                        get: { mappings[selectedRoute] ?? "" },
                        set: { if $0.isEmpty { mappings.removeValue(forKey: selectedRoute) }
                               else { mappings[selectedRoute] = $0 } }
                    )) {
                        Text("Нет привязки").tag("")
                        ForEach(model.dnsServers) { server in
                            Text(server.name).tag(server.name)
                        }
                    }
                }
                StudioLabelValue("Будет использован DNS",
                               value: association.dns ?? "Не определён")
                if association.source == .unmapped {
                    Text("Для этого выхода DNS не сопоставлен. Пока используется общий DNS; это не подтверждение корректной связки.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section {
                Text("При реализации редактора смена маршрута будет пересчитывать DNS по этой таблице, кроме корпоративных и явно защищённых переопределений. Сейчас это только локальный просмотр алгоритма.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("По умолчанию")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if selectedRoute.isEmpty { selectedRoute = model.defaultRoute ?? availableRoutes.first ?? "" }
        }
    }
}

private struct StudioAdditionalSettingsView: View {
    let document: StudioDocument
    var body: some View {
        List {
            Section("Служебные параметры") {
                ForEach(["inbounds", "http_clients", "experimental", "log", "lx", "route", "dns"],
                        id: \.self) { key in
                    if let value = document.root[key] {
                        NavigationLink {
                            StudioNativeDetailView(title: StudioHumanFields.label(key),
                                                   path: key, value: value)
                        } label: {
                            Label(StudioHumanFields.label(key),
                                  systemImage: "slider.horizontal.3")
                        }
                    }
                }
            }
            Section("Остальные поля") {
                let standard = Set(["inbounds", "http_clients", "experimental",
                                    "log", "lx", "route", "dns", "outbounds", "endpoints"])
                ForEach(document.root.keys.sorted().filter { !standard.contains($0) }, id: \.self) { key in
                    NavigationLink {
                        StudioNativeDetailView(title: StudioHumanFields.label(key),
                                               path: key, value: document.root[key]!)
                    } label: {
                        Label(StudioHumanFields.label(key), systemImage: "list.bullet")
                    }
                }
            }
        }
        .navigationTitle("Дополнительно")
        .navigationBarTitleDisplayMode(.inline)
    }
}
private struct StudioLabelValue: View {
    let title: String
    let value: String
    init(_ title: String, value: String) {
        self.title = title
        self.value = value
    }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title).font(.subheadline)
            Spacer(minLength: 10)
            Text(value).font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .padding(.vertical, 3)
    }
}
#endif
