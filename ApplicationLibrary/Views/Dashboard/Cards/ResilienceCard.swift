import Library
import SwiftUI

/// Independent Dashboard card. Presets apply only to the selected profile;
/// Strategy and Gemini selectors remain untouched.
@MainActor
public struct ResilienceCard: View {
    @EnvironmentObject private var profile: ExtensionProfile
    @EnvironmentObject private var environments: ExtensionEnvironments
    @State private var alert: AlertState?
    @State private var resiliencePreset = LXResiliencePreset.custom.rawValue
    @State private var resilienceProfileID: Int64 = -1
    @State private var resilienceSupported = false
    @State private var applyingResiliencePreset: String?

    public init() {}

    public var body: some View {
        Group {
            if resilienceSupported {
                DashboardCardView(title: "") {
                    resilienceSelector
                }
            }
        }
        .task { await loadResiliencePreset() }
        .onReceive(environments.selectedProfileUpdate) { _ in
            Task { await loadResiliencePreset() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .lxResilienceSettingsChanged)) { _ in
            Task { await loadResiliencePreset() }
        }
        .alert($alert)
    }

    private var resilienceSelector: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                DashboardCardHeader(icon: "shield.lefthalf.filled", title: "Устойчивость")
                Spacer(minLength: 4)
                if applyingResiliencePreset != nil {
                    ProgressView().controlSize(.small)
                } else if resiliencePreset == LXResiliencePreset.custom.rawValue {
                    Text("Мои настройки")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 8) {
                resilienceButton("Стабильный", preset: .economy)
                resilienceButton("Баланс", preset: .balance)
                resilienceButton("Антиблок", preset: .antiblock)
            }
            Text("Смена профиля применяет настройки VPN и может прервать текущие соединения.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func resilienceButton(_ title: String, preset: LXResiliencePreset) -> some View {
        let selected = resiliencePreset == preset.rawValue
        return Button {
            Task { await applyResiliencePreset(preset) }
        } label: {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity, minHeight: 38)
                .padding(.horizontal, 7)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(selected ? Color.accentColor.opacity(0.12) : modeTileBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(selected ? Color.accentColor : Color.urlTestNeutral,
                              lineWidth: selected ? 2 : 1)
        )
        .disabled(applyingResiliencePreset != nil || selected)
        .accessibilityLabel(selected ? "\(title), выбран" : title)
    }

    private func loadResiliencePreset() async {
        guard applyingResiliencePreset == nil else { return }
        do {
            let id = await SharedPreferences.selectedProfileID.get()
            guard let selectedProfile = try await ProfileManager.get(id) else {
                resilienceSupported = false
                return
            }
            let content = try await selectedProfile.readAsync()
            let supports = !(try LXProfileOverrides.inspect(content)).urlTests.isEmpty
            let store = try LXOverridesStore.decode(await SharedPreferences.lxOverridesJSON.get())
            let currentID = await SharedPreferences.selectedProfileID.get()
            guard id == currentID else { return }
            resilienceProfileID = id
            resilienceSupported = supports
            resiliencePreset = store.profiles[String(id)]?.resiliencePreset ??
                LXResiliencePreset.custom.rawValue
        } catch {
            resilienceSupported = false
        }
    }

    private func applyResiliencePreset(_ preset: LXResiliencePreset) async {
        guard applyingResiliencePreset == nil, resilienceSupported,
              resiliencePreset != preset.rawValue else { return }
        applyingResiliencePreset = preset.rawValue
        defer { applyingResiliencePreset = nil }

        let original = await SharedPreferences.lxOverridesJSON.get()
        do {
            let id = await SharedPreferences.selectedProfileID.get()
            guard id == resilienceProfileID,
                  let selectedProfile = try await ProfileManager.get(id) else {
                throw NSError(domain: "LXDashboard", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Активный профиль изменился. Повтори выбор."
                ])
            }
            let source = try await selectedProfile.readAsync()
            var store = try LXOverridesStore.decode(original)
            var settings = store.profiles[String(id)] ?? LXProfileSettings()
            settings.applyResiliencePreset(preset.rawValue)
            store.profiles[String(id)] = settings
            let updated = try store.encode()
            _ = try LXProfileOverrides.apply(source, profileID: id, storedJSON: updated)
            let currentID = await SharedPreferences.selectedProfileID.get()
            guard id == currentID else {
                throw NSError(domain: "LXDashboard", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "Профиль изменился во время применения."
                ])
            }

            await SharedPreferences.lxOverridesJSON.set(updated)
            guard await SharedPreferences.lxOverridesJSON.get() == updated else {
                await SharedPreferences.lxOverridesJSON.set(original)
                throw NSError(domain: "LXDashboard", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "Не удалось сохранить настройки."
                ])
            }

            // A live update uses the same guarded reload as Settings → LX:
            // on error restore the previous JSON and attempt to restore the
            // previous working tunnel. Do not start an inactive VPN.
            if profile.status.isConnected {
                do {
                    try await profile.reloadService()
                } catch {
                    await SharedPreferences.lxOverridesJSON.set(original)
                    try? await profile.reloadService()
                    throw error
                }
            }
            resiliencePreset = preset.rawValue
            NotificationCenter.default.post(name: .lxResilienceSettingsChanged, object: nil)
        } catch {
            alert = AlertState(action: "изменить профиль устойчивости", error: error)
        }
    }

    private var modeTileBackground: Color {
        #if os(iOS)
            Color(uiColor: .systemGroupedBackground)
        #elseif os(macOS)
            Color(nsColor: .windowBackgroundColor)
        #else
            Color.clear
        #endif
    }
}
