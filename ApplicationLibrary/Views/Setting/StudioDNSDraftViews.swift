#if os(iOS)
import SwiftUI

/// A proposed DNS policy in the UI. The source JSON and the running
/// NetworkExtension configuration stay unchanged.
struct StudioDNSDraftProfileView: View {
    let role: StudioDNSRole
    let catalog: [StudioDNSCatalogEntry]
    @ObservedObject var draft: StudioDNSDraftStore

    private var rows: [StudioDNSDraftAssignment] {
        draft.rows(for: role).sorted {
            if $0.priority != $1.priority { return $0.priority < $1.priority }
            return $0.entryID < $1.entryID
        }
    }
    private func entry(_ id: String) -> StudioDNSCatalogEntry? {
        catalog.first { $0.id == id }
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(role.subtitle)
                        .font(.subheadline.weight(.medium))
                    Text("Черновик: выбор пока не меняет DNS в работающем VPN и не сохраняется в профиль.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            Section("Выбранные DNS-серверы") {
                if rows.isEmpty {
                    Text("Серверы пока не выбраны. Добавь один или несколько DNS из каталога.")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                }
                ForEach(rows, id: \.entryID) { selection in
                    if let item = entry(selection.entryID) {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.name).font(.subheadline.weight(.medium))
                                Text(item.uri)
                                    .font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(3)
                                    .textSelection(.enabled)
                            }
                            Spacer(minLength: 6)
                            Picker("Приоритет", selection: Binding(
                                get: { draft.rows(for: role).first(where: {
                                    $0.entryID == selection.entryID
                                })?.priority ?? 1 },
                                set: { draft.changePriority(selection.entryID, for: role, to: $0) }
                            )) {
                                ForEach(1...9, id: \.self) { number in
                                    Text(String(format: "%02d", number)).tag(number)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .accessibilityLabel("Приоритет DNS: \(item.name)")
                            Button {
                                draft.toggle(item.id, for: role)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Убрать \(item.name)")
                        }
                        .padding(.vertical, 6)
                    }
                }
                NavigationLink {
                    StudioDNSCatalogPickerView(role: role, catalog: catalog, draft: draft)
                } label: {
                    Label("Выбрать DNS-серверы", systemImage: "plus.circle")
                }
            }
            if !rows.isEmpty {
                Section("Как будут обрабатываться запросы") {
                    ForEach(StudioDNSDraftLogic.groups(rows)) { group in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Приоритет \(String(format: "%02d", group.priority))")
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                Text(group.isRace ? "Параллельно" : "Один DNS")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            let names = group.entries.compactMap { entry($0.entryID)?.name }
                            Text(names.joined(separator: ", "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 3)
                    }
                    Text("Одинаковый номер — параллельные запросы (RACE). Следующий номер — резерв, если предыдущая группа не дала допустимый ответ. Это будущая схема, ещё не включённая в ядре.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section("Сетевой путь") {
                switch role {
                case .directTraffic:
                    Text("При реализации этот профиль предназначен для прямого трафика. Путь подключения каждого DNS нужно проверять отдельно.")
                case .proxyTraffic, .geminiTraffic:
                    Text("При реализации эти DNS должны подключаться через разрешённый прокси, без скрытого перехода на DIRECT.")
                case .proxyHosts, .dnsHosts:
                    Text("Служебный DNS должен быть доступен до подключения прокси. Для защиты от циклов он проверяется отдельно.")
                }
            }
            .font(.footnote)
            Section {
                Text("Действующие правила RACE, корпоративные исключения и DNS bootstrap остаются в исходной конфигурации. Нельзя использовать этот экран как доказательство того, что новые приоритеты уже применились.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(role.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Karing-inspired catalog: full protocol URI, provider label, independent
/// checkmark selection. Entries from the actual config appear first.
struct StudioDNSCatalogPickerView: View {
    let role: StudioDNSRole
    let catalog: [StudioDNSCatalogEntry]
    @ObservedObject var draft: StudioDNSDraftStore
    @State private var search = ""

    private var configured: [StudioDNSCatalogEntry] {
        filtered.filter(\.isConfigured)
    }
    private var suggestions: [StudioDNSCatalogEntry] {
        filtered.filter { !$0.isConfigured }
    }
    private var filtered: [StudioDNSCatalogEntry] {
        guard !search.isEmpty else { return catalog }
        return catalog.filter {
            $0.name.localizedCaseInsensitiveContains(search) ||
                $0.uri.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        List {
            Section {
                Text("Выбери DNS для «\(role.title)». Один провайдер может встречаться с разными адресами и протоколами — каждый выбирается отдельно.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if !configured.isEmpty {
                Section("Из текущей конфигурации") {
                    ForEach(configured) { item in
                        row(item)
                    }
                }
            }
            if !suggestions.isEmpty {
                Section("Каталог DNS") {
                    ForEach(suggestions) { item in
                        row(item)
                    }
                }
            }
            Section {
                Text("Выбор влияет только на черновик интерфейса. DNS-серверы из каталога не подключаются к VPN до появления безопасного механизма сохранения и генерации правил.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .searchable(text: $search, prompt: "Имя или адрес DNS")
        .navigationTitle("Выбор DNS")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ item: StudioDNSCatalogEntry) -> some View {
        Button {
            draft.toggle(item.id, for: role)
        } label: {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.name)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(item.uri)
                        .font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Image(systemName: draft.contains(item.id, in: role)
                      ? "checkmark.square.fill" : "square")
                    .font(.title3)
                    .foregroundStyle(draft.contains(item.id, in: role) ? Color.green : Color.secondary)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(item.name), \(item.uri)")
        .accessibilityAddTraits(draft.contains(item.id, in: role) ? .isSelected : [])
    }
}

struct StudioDNSCatalogOverviewView: View {
    let catalog: [StudioDNSCatalogEntry]
    @State private var search = ""
    private var filtered: [StudioDNSCatalogEntry] {
        if search.isEmpty { return catalog }
        return catalog.filter {
            $0.name.localizedCaseInsensitiveContains(search) ||
                $0.uri.localizedCaseInsensitiveContains(search)
        }
    }
    var body: some View {
        List {
            Section {
                Text("Серверы, обнаруженные в загруженной конфигурации. Их исходные теги и адреса показаны без изменений.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(filtered) { item in
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.name).font(.subheadline.weight(.medium))
                    Text(item.uri).font(.subheadline).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    if item.isConfigured {
                        Text("Из текущей конфигурации")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 5)
            }
        }
        .searchable(text: $search)
        .navigationTitle("Каталог DNS")
        .navigationBarTitleDisplayMode(.inline)
    }
}
#endif
