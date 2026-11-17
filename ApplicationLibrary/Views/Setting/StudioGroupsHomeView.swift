#if os(iOS)
import Foundation
import SwiftUI

/// Composition-first, read-only Groups hierarchy. No group edits are
/// persisted and no filters are reverse-engineered from generated pools.
struct StudioGroupsHomeView: View {
    let document: StudioDocument
    private var catalog: StudioGroupCatalog { StudioGroupCatalog(document: document) }

    var body: some View {
        let data = catalog
        List {
            Section {
                Text("Группы задают состав подключений. Ручной выбор, URLTest, приоритеты и переключение относятся к стратегиям. Показаны только элементы из текущего JSON.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Типы групп") {
                ForEach(StudioGroupCatalog.Kind.allCases, id: \.self) { kind in
                    if kind == .smart {
                        HStack(spacing: 12) {
                            Image(systemName: kind.icon)
                                .foregroundStyle(.tertiary).frame(width: 28)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(kind.title).font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Text(kind.subtitle).font(.caption).foregroundStyle(.tertiary)
                            }
                            Spacer()
                            Text("Позже").font(.caption2).foregroundStyle(.tertiary)
                        }
                    } else {
                        NavigationLink {
                            StudioGroupCategoryView(kind: kind, items: data.items(kind))
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: kind.icon).foregroundStyle(.tint).frame(width: 28)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(kind.title).font(.subheadline.weight(.semibold))
                                    Text(kind.subtitle).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("\(data.items(kind).count)")
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            if !data.legacyPools.isEmpty {
                Section("Совместимость с r6") {
                    Text("Пулы A–D остаются видимыми как существующие URLTest-группы. Алгоритм их распределения выполнялся генератором и не восстанавливается из конечного JSON. Новый конструктор пулов пока не добавляем.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("Пулы A–D в источнике: \(data.legacyPools.count)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                Text("«Умные группы» пока недоступны. Будущий редактор не должен считать вручную перечисленные в JSON узлы исходными динамическими фильтрами.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Группы")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct StudioGroupCategoryView: View {
    let kind: StudioGroupCatalog.Kind
    let items: [StudioGroupCatalog.Item]
    @State private var query = ""

    private var filtered: [StudioGroupCatalog.Item] {
        if query.isEmpty { return items }
        return items.filter {
            $0.tag.localizedCaseInsensitiveContains(query) ||
                $0.members.contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    var body: some View {
        List {
            Section {
                Text(kind.subtitle)
                    .font(.footnote).foregroundStyle(.secondary)
                if kind == .dynamic && items.isEmpty {
                    Text("В загруженном JSON нет явно заданных include/exclude. Генератор мог выполнить фильтрацию до сохранения конфига — параметры фильтрации нельзя достоверно восстановить.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section("\(kind.title) · \(filtered.count)") {
                ForEach(filtered) { item in
                    NavigationLink {
                        StudioGroupObjectView(item: item)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.tag).font(.subheadline.weight(.medium))
                            Text(item.kind == .chain
                                 ? "Хопы: \(item.chainHopsLabel)"
                                 : "\(item.type) · участников: \(item.members.count)")
                                .font(.caption).foregroundStyle(.secondary)
                            if item.isLegacyPool {
                                Text("Legacy · пул из генератора r6")
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
        }
        .searchable(text: $query, prompt: "Поиск группы или узла")
        .navigationTitle(kind.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct StudioGroupObjectView: View {
    let item: StudioGroupCatalog.Item

    var body: some View {
        List {
            Section("Объект из JSON") {
                label("Название", item.tag)
                label("Тип", item.type)
                if item.isLegacyPool {
                    Text("Legacy: состав сформирован генератором. Это не сохраняемое правило динамического распределения.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            if let detour = item.detour {
                Section("Хопы цепочки") {
                    label("Первый хоп / detour", detour)
                    label("Выходной хоп", item.tag)
                    Text("Фактический маршрут зависит от ссылок и поведения ядра. Здесь сохранены исходные теги, включая служебные символы.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            if !item.members.isEmpty {
                Section("Участники · \(item.members.count)") {
                    ForEach(item.members.indices, id: \.self) { index in
                        HStack {
                            Text("\(index + 1)")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                .frame(width: 26)
                            Text(item.members[index])
                        }
                    }
                }
            }
            if !item.linkedGroups.isEmpty {
                Section("Вложенные группы") {
                    ForEach(item.linkedGroups, id: \.self) { Text($0) }
                }
            }
            Section("Все параметры") {
                NavigationLink {
                    StudioNativeDetailView(title: item.tag,
                                           path: "outbounds[\(item.index)]",
                                           value: item.raw)
                } label: {
                    Label("Исходные настройки", systemImage: "list.bullet.rectangle")
                }
            }
        }
        .navigationTitle(item.tag)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func label(_ name: String, _ value: String) -> some View {
        HStack {
            Text(name).font(.subheadline)
            Spacer(minLength: 8)
            Text(value).font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}
#endif
