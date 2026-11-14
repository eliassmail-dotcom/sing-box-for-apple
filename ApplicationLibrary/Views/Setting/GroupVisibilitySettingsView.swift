import Library
import SwiftUI

/// Visible order in the Groups screen; does not alter proxy routing.
@MainActor
public struct GroupVisibilitySettingsView: View {
    @EnvironmentObject private var environments: ExtensionEnvironments
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var profileID: Int64 = -1
    @State private var groupTags: [String] = []
    @State private var hiddenTags: Set<String> = []
    @State private var savedOrder: [String] = []
    @State private var savedHidden: Set<String> = []
    @State private var alert: AlertState?

    public init() {}

    private var hasChanges: Bool {
        groupTags != savedOrder || hiddenTags != savedHidden
    }

    public var body: some View {
        Group {
            if isLoading {
                ProgressView()
            } else {
                List {
                    Section {
                        Text("Перетащи группу за значок справа, чтобы изменить порядок. Переключатель управляет только видимостью в разделе «Группы».")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Section("Группы") {
                        if groupTags.isEmpty {
                            Text("Группы не найдены. Подключи VPN или выбери профиль с группами selector / urltest.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(groupTags, id: \.self) { tag in
                            Toggle(isOn: visibilityBinding(for: tag)) {
                                Text(tag)
                                    .foregroundStyle(hiddenTags.contains(tag) ? .secondary : .primary)
                            }
                        }
                        .onMove { indices, newOffset in
                            groupTags.move(fromOffsets: indices, toOffset: newOffset)
                        }
                    }
                    Section {
                        Button {
                            Task { await save() }
                        } label: {
                            HStack {
                                Text("Сохранить")
                                Spacer()
                                if isSaving { ProgressView() }
                            }
                        }
                        .disabled(isSaving || !hasChanges)

                        Button("Сбросить порядок и видимость", role: .destructive) {
                            Task { await reset() }
                        }
                        .disabled(isSaving)
                    } footer: {
                        Text("Параметры сохраняются отдельно для каждого профиля. Новые группы из подписки будут видимы по умолчанию и появятся в конце списка. Скрытие не отключает селектор, URLTest или маршрутизацию VPN.")
                    }
                }
                #if os(iOS)
                .environment(\.editMode, .constant(.active))
                #endif
            }
        }
        .navigationTitle("Видимость групп")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .alert($alert)
        .task { await load() }
        .onReceive(environments.commandClient.$groups) { groups in
            guard !isLoading, let groups, !groups.isEmpty else { return }
            mergeTags(groups.map(\.tag))
        }
        .onReceive(environments.selectedProfileUpdate) { _ in
            Task { await load() }
        }
    }

    private func visibilityBinding(for tag: String) -> Binding<Bool> {
        Binding(
            get: { !hiddenTags.contains(tag) },
            set: { isVisible in
                if isVisible { hiddenTags.remove(tag) }
                else { hiddenTags.insert(tag) }
            }
        )
    }

    private func mergeTags(_ available: [String]) {
        var current = GroupPresentationSettings()
        current.order = groupTags
        let next = current.orderedTags(available: available)
        if next != groupTags { groupTags = next }
    }

    private func availableTags(profileID id: Int64) async -> [String] {
        if let live = environments.commandClient.groups, !live.isEmpty {
            return live.map(\.tag)
        }
        guard let profile = try? await ProfileManager.get(id),
              let contents = try? await profile.readAsync() else { return [] }
        return GroupPresentationSettings.tagsFromConfig(contents)
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let id = await SharedPreferences.selectedProfileID.get()
            let all = try GroupPresentationStore.decode(await SharedPreferences.groupPresentationJSON.get())
            let settings = all.profiles[String(id)] ?? GroupPresentationSettings()
            let available = await availableTags(profileID: id)
            let ordered = settings.orderedTags(available: available)
            profileID = id
            groupTags = ordered
            hiddenTags = settings.hidden
            savedOrder = ordered
            savedHidden = settings.hidden
        } catch {
            alert = AlertState(action: "load group visibility", error: error)
        }
    }

    private func save() async {
        guard !isSaving, hasChanges else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            // Always read the latest store to avoid overwriting other profiles.
            let oldJSON = await SharedPreferences.groupPresentationJSON.get()
            var all = try GroupPresentationStore.decode(oldJSON)
            var settings = all.profiles[String(profileID)] ?? GroupPresentationSettings()
            settings.setOrder(groupTags)
            settings.hidden = hiddenTags
            if settings.hidden.isEmpty && settings.order.isEmpty {
                all.profiles.removeValue(forKey: String(profileID))
            } else {
                all.profiles[String(profileID)] = settings
            }
            let currentID = await SharedPreferences.selectedProfileID.get()
            guard currentID == profileID else {
                throw NSError(domain: "GroupVisibility", code: 1, userInfo: [NSLocalizedDescriptionKey: "Активный профиль изменился. Открой настройки снова."])
            }
            let newJSON = try all.encode()
            await SharedPreferences.groupPresentationJSON.set(newJSON)
            guard await SharedPreferences.groupPresentationJSON.get() == newJSON else {
                throw NSError(domain: "GroupVisibility", code: 2, userInfo: [NSLocalizedDescriptionKey: "Не удалось сохранить настройки."])
            }
            savedOrder = groupTags
            savedHidden = hiddenTags
            NotificationCenter.default.post(name: .groupPresentationChanged, object: nil)
        } catch {
            alert = AlertState(action: "save group visibility", error: error)
        }
    }

    private func reset() async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            let currentID = await SharedPreferences.selectedProfileID.get()
            guard currentID == profileID else {
                throw NSError(domain: "GroupVisibility", code: 3, userInfo: [NSLocalizedDescriptionKey: "Активный профиль изменился."])
            }
            var all = try GroupPresentationStore.decode(await SharedPreferences.groupPresentationJSON.get())
            all.profiles.removeValue(forKey: String(profileID))
            let encoded = try all.encode()
            await SharedPreferences.groupPresentationJSON.set(encoded)
            guard await SharedPreferences.groupPresentationJSON.get() == encoded else {
                throw NSError(domain: "GroupVisibility", code: 4, userInfo: [NSLocalizedDescriptionKey: "Не удалось сбросить настройки."])
            }
            let available = await availableTags(profileID: profileID)
            groupTags = GroupPresentationSettings().orderedTags(available: available)
            hiddenTags = []
            savedOrder = groupTags
            savedHidden = []
            NotificationCenter.default.post(name: .groupPresentationChanged, object: nil)
        } catch {
            alert = AlertState(action: "reset group visibility", error: error)
        }
    }
}
