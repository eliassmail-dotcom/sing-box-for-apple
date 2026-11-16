#if os(iOS)
import Foundation
import SwiftUI

/// The DNS home is a read-only explanation of live JSON, not a writable editor.
struct StudioDNSHomeView: View {
    let model: StudioSemanticModel

    private var catalog: [StudioDNSCatalogEntry] {
        StudioDNSCatalogEntry.catalog(document: model.document).filter(\.isConfigured)
    }

    var body: some View {
        List {
            Section {
                Label("Действующая конфигурация · только чтение", systemImage: "doc.text.magnifyingglass")
                    .font(.subheadline.weight(.medium))
                Text("Серверы и последовательность DNS-правил загружены из выбранного JSON. Приоритеты, RACE и резервирование отображаются только там, где они реально описаны; ничего не выбирается и не сохраняется.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("DNS-схемы · из действующих правил") {
                NavigationLink {
                    StudioDNSSchemeListView(model: model)
                } label: {
                    HStack {
                        Label("DNS-схемы", systemImage: "point.3.connected.trianglepath.dotted")
                        Spacer()
                        Text("\(StudioDNSSchemeCatalog(document: model.document).schemes.count)")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                Text("Одинаковые последовательности DNS-проверок объединены в одну схему. Связанные группы адресов, исходные номера правил и порядок обработки сохраняются.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Для интернет-трафика") {
                roleLink(.directTraffic)
                roleLink(.proxyTraffic)
                roleLink(.geminiTraffic)
            }
            Section("Для подключения сервисов") {
                roleLink(.proxyHosts)
                roleLink(.dnsHosts)
            }
            Section("Серверы") {
                NavigationLink {
                    StudioDNSCatalogOverviewView(catalog: catalog)
                } label: {
                    Label("DNS-серверы из конфигурации", systemImage: "list.bullet")
                }
            }
            Section("Действующая конфигурация") {
                if let final = model.defaultDNS {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("DNS при отсутствии подходящего правила")
                            .font(.subheadline)
                        Text(final).font(.caption).foregroundStyle(.secondary)
                    }
                }
                NavigationLink {
                    StudioDNSAddressAreaListView(model: model)
                } label: {
                    Label("DNS-исключения и условия", systemImage: "shield.lefthalf.filled")
                }
                Text("Корпоративный DNS, специальные правила, настройки загрузки и fallback показаны из реального JSON. Редактор появится отдельно.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Дополнительно") {
                NavigationLink {
                    StudioDNSRuleFlowView(model: model, filteredIndexes: nil)
                } label: {
                    Label("Обзор DNS-механизмов", systemImage: "wrench.and.screwdriver")
                }
                Text("В этом релизе ничего не редактируется. Порядок evaluate, respond, route и race берётся из исходных правил, без моделирования будущей политики.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("DNS")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func roleLink(_ role: StudioDNSRole) -> some View {
        NavigationLink {
            StudioDNSConfiguredProfileView(model: model, role: role)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: role.icon).foregroundStyle(.tint).frame(width: 25)
                VStack(alignment: .leading, spacing: 4) {
                    Text(role.title).font(.subheadline.weight(.semibold))
                    Text(role.subtitle)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                let count = StudioDNSObservedProfile(document: model.document, role: role).servers.count
                Text("\(count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }
}

/// Read-only inspection of what the active JSON actually declares.
/// This deliberately does not present an empty editable DNS draft as current state.
private struct StudioDNSConfiguredProfileView: View {
    let model: StudioSemanticModel
    let role: StudioDNSRole

    private var observed: StudioDNSObservedProfile {
        StudioDNSObservedProfile(document: model.document, role: role)
    }

    var body: some View {
        let profile = observed
        List {
            Section {
                Text(role.subtitle)
                    .font(.subheadline.weight(.medium))
                Text("Список ниже отражает только реальную конфигурацию, без предлагаемых DNS-серверов и выдуманных приоритетов.")
                    .font(.footnote).foregroundStyle(.secondary)
                if role == .directTraffic || role == .proxyTraffic {
                    Text("Разделение Direct/Proxy здесь основано на пути подключения самого DNS (detour), а не на допущении, какие домены или сайты он обслуживает. Точные условия находятся в DNS-правилах.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if role == .geminiTraffic {
                    Text("Отдельный Gemini DNS появляется только при наличии явных Gemini-условий в dns.rules. Если DNS-сервер не указан в таком правиле, приложение не приписывает ему сервер по имени.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section("Серверы из dns.servers · \(profile.servers.count)") {
                if profile.servers.isEmpty {
                    Text("Для этого раздела нет явных DNS-серверов в загруженном JSON.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                ForEach(profile.servers) { server in
                    NavigationLink {
                        StudioDNSServerExplanationView(server: server)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(server.name).font(.subheadline.weight(.semibold))
                            Text(StudioDNSCatalogEntry.uri(server.object))
                                .font(.caption).foregroundStyle(.secondary)
                            Text(server.reason)
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            if !profile.unresolvedResolvers.isEmpty {
                Section("Ссылки, которых нет в dns.servers") {
                    ForEach(profile.unresolvedResolvers, id: \.self) { name in
                        Label(name, systemImage: "exclamationmark.triangle")
                    }
                }
            }
            Section("Правила и фактическая последовательность · \(profile.rules.count)") {
                if profile.rules.isEmpty {
                    Text("Прямых ссылок на эти DNS в правилах не найдено. Возможны наследование общего dns.final или служебные обращения, но отдельный порядок не задан.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(profile.rules) { step in
                    NavigationLink {
                        StudioNativeDetailView(title: "DNS-правило \(step.number)",
                                               path: "dns.rules[\(step.index)]",
                                               value: step.raw)
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(step.number).font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                Text(step.heading).font(.subheadline.weight(.medium))
                            }
                            if let name = step.server {
                                Text(name).font(.caption).foregroundStyle(.secondary)
                            }
                            Text(step.condition)
                                .font(.caption2).foregroundStyle(.tertiary)
                            if let concurrency = step.concurrency {
                                Text(concurrency).font(.caption2).foregroundStyle(.secondary)
                            }
                            if let timeout = step.raw["timeout"] as? String {
                                Text("Таймаут: \(timeout)")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            Section("Общий DNS при отсутствии подходящего правила") {
                Text(profile.finalServer ?? "Не задан")
                    .font(.subheadline)
                Text("dns.final действует при отсутствии более раннего подходящего правила. Это не назначение DNS конкретно для Direct, Proxy или Gemini.")
                    .font(.footnote).foregroundStyle(.secondary)
                NavigationLink {
                    StudioDNSRuleFlowView(model: model, filteredIndexes: nil)
                } label: {
                    Label("Все DNS-правила в исходном порядке", systemImage: "list.number")
                }
            }
        }
        .navigationTitle(role.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Read-only DNS scheme library; the JSON remains the single source of truth.
struct StudioDNSSchemeListView: View {
    let model: StudioSemanticModel
    private var catalog: StudioDNSSchemeCatalog {
        StudioDNSSchemeCatalog(document: model.document)
    }

    var body: some View {
        let items = catalog
        List {
            Section {
                Text("DNS-схема — общая последовательность реальных evaluate/respond/route правил. Она может использоваться несколькими группами адресов. Это представление JSON, а не отдельная настройка ядра.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Схемы · \(items.schemes.count)") {
                ForEach(items.schemes) { scheme in
                    NavigationLink {
                        StudioDNSSchemeDetailView(scheme: scheme)
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(scheme.title).font(.subheadline.weight(.semibold))
                            Text(scheme.serversInOrder.joined(separator: " → "))
                                .font(.caption).foregroundStyle(.secondary)
                                .lineLimit(3)
                            Text("Групп адресов: \(scheme.bindings.count) · \(scheme.hasExplicitRace ? "RACE присутствует в JSON" : "Без явного RACE")")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            Section("Остальные правила") {
                Text("\(items.ungroupedRuleIndexes.count) записей не объединены в схему: одиночные DNS-правила, блокировки, специальные условия или неполные последовательности. Все они доступны без потерь.")
                    .font(.footnote).foregroundStyle(.secondary)
                NavigationLink {
                    StudioDNSRuleFlowView(model: model, filteredIndexes: nil)
                } label: {
                    Label("Все DNS-правила в оригинальном порядке", systemImage: "list.number")
                }
            }
        }
        .navigationTitle("DNS-схемы")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct StudioDNSSchemeDetailView: View {
    let scheme: StudioDNSSchemeCatalog.Scheme

    var body: some View {
        List {
            Section {
                Text("Одинаковый DNS-порядок применяется в \(scheme.bindings.count) наборах условий. Отображаемый порядок этапов получен из dns.rules, а не задан отдельным вымышленным параметром priority.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("DNS-последовательность") {
                ForEach(scheme.template) { step in
                    NavigationLink {
                        StudioNativeDetailView(
                            title: "DNS-правило №\(step.index + 1)",
                            path: "dns.rules[\(step.index)]", value: step.raw
                        )
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 8) {
                                Text("№\(step.index + 1)")
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                Text(step.action == "evaluate" ? "Проверка DNS" :
                                     step.action == "respond" ? "Обработка ответа" :
                                     step.action == "route" ? "Резервный маршрут" : step.action)
                                    .font(.subheadline.weight(.medium))
                            }
                            if let server = step.server {
                                Text(server)
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                            if let responseTag = step.responseTag {
                                Text("Результат проверки: \(responseTag)")
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                            if let timeout = step.timeout {
                                Text("Таймаут: \(timeout)")
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                            if step.isRace {
                                Text("RACE: задано в правиле")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            if step.isSpeculative {
                                Text("Speculative: задано в правиле")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
            Section("Связанные группы адресов · \(scheme.bindings.count)") {
                ForEach(scheme.bindings) { binding in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(binding.description).font(.subheadline)
                        Text("Правила: " + binding.ruleIndexes.map { "#\($0 + 1)" }.joined(separator: ", "))
                            .font(.caption2).foregroundStyle(.secondary)
                        NavigationLink {
                            StudioNativeDetailView(title: "Условия DNS", path: "dns.scheme.conditions",
                                                   value: binding.conditions)
                        } label: {
                            Label("Условия и адреса", systemImage: "list.bullet.rectangle")
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle(scheme.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct StudioDNSProfileView: View {
    let model: StudioSemanticModel
    let profile: StudioDNSExplanation.Profile

    var body: some View {
        List {
            Section("Способ подключения к DNS") {
                Text(profile.summary)
                    .font(.subheadline)
                Text("Это группировка DNS-транспортов, а не подмена правил DNS. RACE и проверки ответов продолжают выполняться согласно общему порядку правил.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Серверы · \(profile.bindings.count)") {
                if profile.bindings.isEmpty {
                    Text("Нет серверов с однозначно установленным способом подключения.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(profile.bindings) { server in
                    NavigationLink {
                        StudioDNSServerExplanationView(server: server)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(server.name).font(.subheadline.weight(.semibold))
                            Text(server.reason)
                                .font(.caption).foregroundStyle(.secondary)
                                .lineLimit(3)
                        }
                    }
                }
            }
            Section("Где используются серверы") {
                NavigationLink {
                    StudioDNSRuleFlowView(model: model, filteredIndexes: profile.ruleIndexes)
                } label: {
                    HStack {
                        Text("Прямые обращения из DNS-правил")
                        Spacer()
                        Text("\(profile.ruleIndexes.count)").foregroundStyle(.secondary)
                    }
                }
                Text("Это только правила, прямо ссылающиеся на перечисленные серверы. Продолжение схемы через RACE, evaluate и respond смотрите в общем порядке обработки.")
                    .font(.footnote).foregroundStyle(.secondary)
                NavigationLink {
                    StudioDNSRuleFlowView(model: model, filteredIndexes: nil)
                } label: {
                    Label("Вся схема DNS по порядку", systemImage: "arrow.triangle.branch")
                }
            }
        }
        .navigationTitle(profile.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct StudioDNSServerExplanationView: View {
    let server: StudioDNSExplanation.ServerBinding

    var body: some View {
        List {
            Section("Подключение") {
                row("Название", server.name)
                row("Тип", StudioHumanFields.kind(server.kind))
                row("Сервер", StudioHumanFields.display(server.transport, key: "server"))
                row("Сетевой путь", server.reason)
            }
            if server.kind == "https", let path = server.object["path"] as? String {
                Section("DNS через HTTPS") {
                    row("Путь запроса DoH", path)
                    Text("Это часть адреса HTTPS-запроса к DNS-серверу, например /p0. Это не цепочка VPN и не приоритет. Произвольно изменять путь нельзя.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section("Все параметры сервера") {
                NavigationLink {
                    StudioNativeDetailView(title: server.name, path: "dns.servers",
                                           value: server.object)
                } label: {
                    Label("Технические настройки", systemImage: "slider.horizontal.3")
                }
            }
        }
        .navigationTitle(server.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer(minLength: 10)
            Text(value).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }
}

private struct StudioDNSServersListView: View {
    let model: StudioSemanticModel
    private var servers: [StudioDNSExplanation.ServerBinding] {
        StudioDNSExplanation.bindings(document: model.document)
    }
    var body: some View {
        List {
            ForEach(servers) { server in
                NavigationLink {
                    StudioDNSServerExplanationView(server: server)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(server.name).font(.subheadline.weight(.semibold))
                        Text("\(StudioHumanFields.kind(server.kind)) · \(server.family.title)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("DNS-серверы")
    }
}

private struct StudioDNSAddressAreaListView: View {
    let model: StudioSemanticModel
    private var areas: [StudioSemanticModel.AddressPolicy] {
        model.addressPolicies.filter { !$0.dnsRules.isEmpty }
    }
    var body: some View {
        List {
            Section {
                Text("Это наборы условий из DNS-правил, а не созданные вручную группы адресов. Внутри можно увидеть точные домены, источники списков и ссылки на исходные правила.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Условия DNS · \(areas.count)") {
                ForEach(areas) { policy in
                    NavigationLink {
                        StudioDNSAreaDetailView(model: model, policy: policy)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(policy.title).font(.subheadline.weight(.medium))
                            Text("\(policy.dnsRules.count) DNS-правил · \(policy.dnsTargets.isEmpty ? "без явного сервера" : policy.dnsTargets.joined(separator: ", "))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Области DNS")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct StudioDNSAreaDetailView: View {
    let model: StudioSemanticModel
    let policy: StudioSemanticModel.AddressPolicy
    var body: some View {
        List {
            Section("Когда совпадает") {
                ForEach(policy.conditions.keys.sorted(), id: \.self) { key in
                    if let value = policy.conditions[key] {
                        StudioValueRow(key: key, value: value, path: "dns.areas.\(key)")
                    }
                }
            }
            Section("Найденные назначения") {
                if !policy.destinations.isEmpty {
                    row("Правила маршрута", policy.destinations.joined(separator: ", "))
                } else {
                    Text("Точного соответствия условиям маршрутизации не обнаружено")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                row("DNS-серверы в правилах", policy.dnsTargets.isEmpty ?
                    "Явного сервера нет" : policy.dnsTargets.joined(separator: ", "))
            }
            Section("DNS-схема") {
                let linked = StudioDNSSchemeCatalog(document: model.document)
                    .linkedSchemes(forDNSRules: policy.dnsRules)
                if linked.isEmpty {
                    Text("Подтверждённой общей последовательности DNS-проверок нет. Используются исходные отдельные правила.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    ForEach(linked) { scheme in
                        NavigationLink {
                            StudioDNSSchemeDetailView(scheme: scheme)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(scheme.title).font(.subheadline.weight(.medium))
                                Text(scheme.serversInOrder.joined(separator: " → "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            Section("Исходные правила") {
                NavigationLink {
                    StudioDNSRuleFlowView(model: model, filteredIndexes: policy.dnsRules)
                } label: {
                    Text("Как обрабатываются эти DNS-условия")
                }
                Text("Это найденные совпадения условий в JSON. Нельзя утверждать, что они обязательно победят предшествующие правила или параллельные проверки.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(policy.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ name: String, _ value: String) -> some View {
        HStack {
            Text(name).font(.subheadline)
            Spacer(minLength: 12)
            Text(value).font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}

/// Compact, readable overview for both the whole DNS program and any
/// selected address condition. Never pretend that N matching rule records
/// equal N operations executed by a single lookup.
struct StudioDNSRuleFlowView: View {
    let model: StudioSemanticModel
    let filteredIndexes: [Int]?

    private var selectedRules: [StudioDNSExplanation.FlowStep] {
        let all = StudioDNSExplanation.steps(document: model.document)
        guard let filteredIndexes else { return all }
        let indices = Set(filteredIndexes)
        return all.filter { indices.contains($0.index) }
    }
    private var summary: StudioDNSExplanation.RuleSummary {
        StudioDNSExplanation.RuleSummary(rules: selectedRules)
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(filteredIndexes == nil
                         ? "Здесь показано, из чего состоит действующая DNS-схема."
                         : "Здесь собраны DNS-действия для выбранных условий.")
                        .font(.subheadline.weight(.medium))
                    Text("Сводка составлена по конфигурации. Она не показывает, какие правила сработали при конкретном запросе.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            Section("Обработка запросов") {
                summaryRow("Запросы к DNS", count: summary.routeCount + summary.evaluateCount,
                           detail: "Запрашивают сервер или получают ответ для проверки")
                summaryRow("Параллельные проверки", count: summary.raceCount,
                           detail: "Правила с RACE — допускают параллельную оценку")
                if summary.speculativeCount > 0 {
                    summaryRow("Предварительные запросы", count: summary.speculativeCount,
                               detail: "Speculative — могут выполняться до завершения RACE")
                }
                summaryRow("Возврат проверенного ответа", count: summary.respondCount,
                           detail: "Используют результат предыдущего запроса")
                if summary.otherCount > 0 {
                    summaryRow("Другие действия", count: summary.otherCount,
                               detail: "Блокировки, готовые ответы и прочие операции")
                }
            }
            Section("DNS-серверы в этих правилах") {
                if summary.servers.isEmpty {
                    Text("Прямые ссылки на серверы не найдены. Некоторые действия используют результат более ранних правил.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    ForEach(summary.servers, id: \.self) { server in
                        Text(server).font(.subheadline)
                    }
                }
            }
            Section("Исходная конфигурация") {
                NavigationLink {
                    StudioDNSRawRulesView(steps: selectedRules)
                } label: {
                    HStack(spacing: 10) {
                        Label("Посмотреть технические записи", systemImage: "list.bullet.rectangle")
                        Spacer(minLength: 4)
                        Text("\(selectedRules.count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Text("Все исходные правила сохранены в прежнем порядке. Полный список нужен для диагностики, а не для выбора DNS или настройки приоритетов.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Обработка DNS")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func summaryRow(_ title: String, count: Int, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            Text("\(count)")
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 5)
    }
}

/// A deliberate, second-level expert screen. Each record takes a short row;
/// expanded original fields remain accessible via the existing native view.
private struct StudioDNSRawRulesView: View {
    let steps: [StudioDNSExplanation.FlowStep]
    @State private var query = ""

    private var filtered: [StudioDNSExplanation.FlowStep] {
        guard !query.isEmpty else { return steps }
        return steps.filter {
            [$0.number, $0.heading, $0.server ?? "", $0.condition]
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    var body: some View {
        List {
            Section {
                Text("Технические записи из JSON. Номера показывают исходный порядок, но не означают, что каждый DNS-запрос выполняет все правила.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Записи · \(filtered.count)") {
                ForEach(filtered) { step in
                    NavigationLink {
                        StudioNativeDetailView(
                            title: "DNS-правило \(step.number)",
                            path: "dns.rules[\(step.index)]",
                            value: step.raw
                        )
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(step.number)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(step.heading)
                                    .font(.subheadline.weight(.medium))
                                if let server = step.server {
                                    Text(server)
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
        }
        .searchable(text: $query, prompt: "Номер, действие или сервер")
        .navigationTitle("Исходные DNS-правила")
        .navigationBarTitleDisplayMode(.inline)
    }
}
#endif
