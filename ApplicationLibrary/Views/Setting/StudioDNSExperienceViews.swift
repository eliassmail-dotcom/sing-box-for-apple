#if os(iOS)
import Foundation
import SwiftUI

/// The DNS home is a read-only explanation of live JSON, not a writable editor.
struct StudioDNSHomeView: View {
    let model: StudioSemanticModel
    @StateObject private var draft = StudioDNSDraftStore()

    private var catalog: [StudioDNSCatalogEntry] {
        StudioDNSCatalogEntry.catalog(document: model.document)
    }

    var body: some View {
        List {
            Section {
                Label("Редактор DNS · черновик", systemImage: "pencil.and.list.clipboard")
                    .font(.subheadline.weight(.medium))
                Text("Выбор DNS-серверов и приоритетов пока действует только на этом экране. Текущие DNS и VPN не изменяются.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Для интернет-трафика") {
                roleLink(.directTraffic)
                roleLink(.proxyTraffic)
            }
            Section("Для подключения сервисов") {
                roleLink(.proxyHosts)
                roleLink(.dnsHosts)
            }
            Section("Серверы") {
                NavigationLink {
                    StudioDNSCatalogOverviewView(catalog: catalog)
                } label: {
                    Label("Каталог DNS-серверов", systemImage: "list.bullet")
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
                Text("Корпоративный DNS, специальные правила и DNS для служебной загрузки остаются под управлением исходной конфигурации.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Дополнительно") {
                NavigationLink {
                    StudioDNSRuleFlowView(model: model, filteredIndexes: nil)
                } label: {
                    Label("Техническая диагностика DNS-правил", systemImage: "wrench.and.screwdriver")
                }
                Text("Исходный порядок правил доступен для диагностики, но не используется как основной способ настройки DNS.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("DNS")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func roleLink(_ role: StudioDNSRole) -> some View {
        NavigationLink {
            StudioDNSDraftProfileView(role: role, catalog: catalog, draft: draft)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: role.icon).foregroundStyle(.tint).frame(width: 25)
                VStack(alignment: .leading, spacing: 4) {
                    Text(role.title).font(.subheadline.weight(.semibold))
                    Text(role.subtitle)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                let count = draft.rows(for: role).count
                if count > 0 {
                    Text("\(count)")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
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
            Section("Исходные правила") {
                NavigationLink {
                    StudioDNSRuleFlowView(model: model, filteredIndexes: policy.dnsRules)
                } label: {
                    Text("Посмотреть \(policy.dnsRules.count) DNS-правил")
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

struct StudioDNSRuleFlowView: View {
    let model: StudioSemanticModel
    let filteredIndexes: [Int]?
    @State private var query = ""
    @State private var mode = "all"

    private var allSteps: [StudioDNSExplanation.FlowStep] {
        StudioDNSExplanation.steps(document: model.document)
    }
    private var steps: [StudioDNSExplanation.FlowStep] {
        let allowed = filteredIndexes.map(Set.init)
        return allSteps.filter { step in
            if let allowed, !allowed.contains(step.index) { return false }
            if mode == "checks" && step.action != "evaluate" && step.responseDependency == nil { return false }
            if mode == "race" && !step.race && !step.speculative { return false }
            if mode == "answers" && step.action != "respond" && step.action != "route" { return false }
            if query.isEmpty { return true }
            return [step.condition, step.heading, step.server ?? "", step.number]
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    var body: some View {
        List {
            Section {
                Text("Правила показаны в исходном порядке. Evaluate получает результат для последующих проверок; RACE может параллельно проверять ответы. Номер — место в исходном JSON, а не отдельный профиль DNS.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Picker("Показать", selection: $mode) {
                    Text("Все").tag("all")
                    Text("Проверки").tag("checks")
                    Text("RACE").tag("race")
                    Text("Ответы").tag("answers")
                }
                .pickerStyle(.segmented)
            }
            Section("Шаги · \(steps.count)") {
                ForEach(steps) { step in
                    NavigationLink {
                        StudioDNSRuleStepView(step: step)
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 6) {
                                Text(step.number).font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                Text(step.heading).font(.subheadline.weight(.semibold))
                            }
                            Text("Когда: \(step.condition)")
                                .font(.caption).foregroundStyle(.secondary)
                                .lineLimit(2)
                            Text(step.result).font(.caption).lineLimit(2)
                            if let concurrent = step.concurrency {
                                Text(concurrent).font(.caption2)
                                    .foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                        .padding(.vertical, 5)
                    }
                }
            }
        }
        .searchable(text: $query, prompt: "Сервер, условие или номер")
        .navigationTitle("Порядок обработки DNS")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct StudioDNSRuleStepView: View {
    let step: StudioDNSExplanation.FlowStep

    var body: some View {
        List {
            Section("Когда выполняется") {
                Text(step.condition)
            }
            Section("Что делает") {
                Text(step.heading).font(.subheadline.weight(.semibold))
                Text(step.result).font(.subheadline)
                if let dependency = step.responseDependency {
                    Text("Используется \(dependency.lowercased())")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let concurrency = step.concurrency {
                    Text(concurrency).font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section("Техническая запись") {
                NavigationLink {
                    StudioNativeDetailView(title: "DNS-правило \(step.number)",
                                           path: "dns.rules[\(step.index)]",
                                           value: step.raw)
                } label: {
                    Label("Показать все условия и параметры", systemImage: "slider.horizontal.3")
                }
            }
            Section {
                Text("Порядок важен. Это объяснение настроек, а не журнал фактически выполненного DNS-запроса.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("DNS-правило \(step.number)")
        .navigationBarTitleDisplayMode(.inline)
    }
}
#endif
