import Library
import SwiftUI

/// LX controls work on the effective configuration, not on the subscription.
public struct LXRuntimeSettingsView: View {
    @EnvironmentObject private var environments: ExtensionEnvironments
    @State private var isLoading = true
    @State private var isApplying = false
    @State private var alert: AlertState?
    @State private var profileID: Int64 = -1
    @State private var profileContent = ""
    @State private var summary: LXConfigSummary?
    @State private var saved = LXOverridesStore()
    @State private var draft = LXOverridesStore()

    public init() {}

    public var body: some View {
        Group {
            if isLoading {
                ProgressView()
            } else if let summary {
                FormView {
                    Section {
                        Text("Настройки действуют только на выбранный профиль и переживают обновления подписки. Исходный JSON не изменяется.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if !summary.urlTests.isEmpty {
                        Section("Для всех URLTest") {
                            Picker("Общий режим", selection: globalModeBinding) {
                                Text("Как в профиле").tag("profile")
                                Text("Least Test · самый быстрый").tag("least_test")
                                Text("Failover · стабильный").tag("failover")
                                Text("Round Robin · балансировка").tag("round_robin")
                            }
                            if currentSettings.urlTestDefault.mode == "round_robin" {
                                Stepper("Размер пула: \(currentSettings.urlTestDefault.pool)",
                                        value: globalPoolBinding, in: 1...32)
                                Stepper("Pool tolerance: \(currentSettings.urlTestDefault.poolTolerance) мс",
                                        value: globalToleranceBinding, in: 0...500, step: 25)
                                Toggle("Sticky Hash · закреплять соединения", isOn: globalStickyBinding)
                            }
                            Text("Общий режим применяется ко всем группам выбранного профиля, кроме групп с индивидуальным переопределением.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        Section("Устойчивость URLTest") {
                            Toggle("Адаптивный порог задержки", isOn: adaptiveEnabledBinding)
                            if currentSettings.adaptiveTolerancePercent > 0 {
                                Stepper("Относительный порог: \(currentSettings.adaptiveTolerancePercent)%",
                                        value: adaptivePercentBinding, in: 5...60, step: 5)
                            }
                            Toggle("Удерживать выбранный узел", isOn: holdEnabledBinding)
                            if currentSettings.minHoldSeconds > 0 {
                                Stepper("Минимальное удержание: \(currentSettings.minHoldSeconds) с",
                                        value: holdSecondsBinding, in: 5...120, step: 5)
                            }
                            TextField("Проверочные URL через запятую", text: probeURLsBinding)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            Text("До трёх HTTP(S)-адресов. Узел доступен, если ответил хотя бы один. Пустое поле сохраняет исходный URL. Порог и удержание действуют только для Least Test; при отказе или возврате на базовые удержание не мешает переключению.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        Section("Переопределения групп") {
                            ForEach(summary.urlTests) { group in
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(group.tag).font(.headline)
                                    Text("В исходном профиле: \(group.mode)")
                                        .font(.caption).foregroundStyle(.secondary)
                                    Picker("Режим", selection: urlModeBinding(group.tag)) {
                                        Text("Наследовать общий").tag("inherit")
                                        Text("Как в исходном профиле").tag("profile")
                                        Text("Least Test · самый быстрый").tag("least_test")
                                        Text("Failover · стабильный").tag("failover")
                                        Text("Round Robin · балансировка").tag("round_robin")
                                    }
                                    Text("Итог: \(effectiveURLMode(group))")
                                        .font(.caption).foregroundStyle(.secondary)
                                    if currentSettings.urlTests[group.tag]?.mode == "round_robin" {
                                        Stepper("Размер пула: \(urlSetting(group.tag).pool)",
                                                value: poolBinding(group.tag), in: 1...32)
                                        Stepper("Pool tolerance: \(urlSetting(group.tag).poolTolerance) мс",
                                                value: toleranceBinding(group.tag), in: 0...500, step: 25)
                                        Toggle("Sticky Hash · закреплять соединения", isOn: stickyBinding(group.tag))
                                    }
                                }.padding(.vertical, 4)
                            }
                        }
                    }

                    if !summary.dnsGroups.isEmpty {
                        Section("DNS-группы") {
                            ForEach(summary.dnsGroups) { group in
                                Picker(group.tag, selection: dnsBinding(group.tag)) {
                                    Text("Как в профиле (\(group.mode))").tag("profile")
                                    Text("Stable").tag("stable")
                                    Text("Fastest").tag("fastest")
                                    Text("Parallel").tag("parallel")
                                }
                            }
                        }
                    }

                    if summary.wireGuardCount > 0 {
                        Section("WireGuard / AmneziaWG") {
                            Picker("Экономия энергии · Idle Suspend", selection: wgIdleBinding) {
                                Text("Как в профиле").tag("profile")
                                Text("Включить").tag("on")
                                Text("Выключить").tag("off")
                            }
                            Text("Включено: 30 с для неиспользуемых узлов, 5 мин для достижимых, разборка через 10 мин. Требует мобильного LX-ядра с idle suspend.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }

                    Section("Функции, зависящие от конфигурации") {
                        statusRow("Multi-hop Chain", value: "\(summary.chainCount) цепочек")
                        statusRow("XHTTP", value: "\(summary.xhttpCount) узлов")
                        statusRow("VLESS Encryption", value: "\(summary.encryptedVlessCount) узлов")
                        Text("Цепочки, XHTTP и VLESS Encryption нельзя включить общим тумблером: нужна соответствующая конфигурация узлов и поддержка серверов. Существующие цепочки выбираются в разделе «Группы».")
                            .font(.footnote).foregroundStyle(.secondary)
                        statusRow("Clash API / CommandClient", value: "Функции ядра")
                        Text("API и события определяются сборкой ядра, а не переключателем в профиле.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }

                    Section {
                        Button {
                            Task { await apply() }
                        } label: {
                            HStack {
                                Text("Применить к VPN")
                                Spacer()
                                if isApplying { ProgressView() }
                            }
                        }.disabled(isApplying || draft == saved)

                        Button("Вернуть настройки профиля", role: .destructive) {
                            draft.profiles.removeValue(forKey: String(profileID))
                        }.disabled(isApplying || currentSettings.isEmpty)
                    } footer: {
                        Text("Применение перезагружает VPN-конфигурацию и может прервать текущие соединения. При ошибке сохранённые настройки откатываются.")
                    }
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                    Text("Нет данных профиля")
                    Text("Выбери JSON-профиль sing-box.").font(.footnote)
                }
            }
        }
        .navigationTitle("Функции LX")
        .alert($alert)
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await load() }
    }

    private func statusRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
    }

    private var currentSettings: LXProfileSettings {
        draft.profiles[String(profileID)] ?? LXProfileSettings()
    }

    private func mutate(_ update: (inout LXProfileSettings) -> Void) {
        var settings = currentSettings
        update(&settings)
        if settings.isEmpty {
            draft.profiles.removeValue(forKey: String(profileID))
        } else {
            draft.profiles[String(profileID)] = settings
        }
    }

    private var adaptiveEnabledBinding: Binding<Bool> {
        Binding(get: { currentSettings.adaptiveTolerancePercent > 0 },
                set: { enabled in mutate { $0.adaptiveTolerancePercent = enabled ? 30 : 0 } })
    }

    private var adaptivePercentBinding: Binding<Int> {
        Binding(get: { currentSettings.adaptiveTolerancePercent },
                set: { value in mutate { $0.adaptiveTolerancePercent = value } })
    }

    private var holdEnabledBinding: Binding<Bool> {
        Binding(get: { currentSettings.minHoldSeconds > 0 },
                set: { enabled in mutate { $0.minHoldSeconds = enabled ? 30 : 0 } })
    }

    private var holdSecondsBinding: Binding<Int> {
        Binding(get: { currentSettings.minHoldSeconds },
                set: { value in mutate { $0.minHoldSeconds = value } })
    }

    private var probeURLsBinding: Binding<String> {
        Binding(get: { currentSettings.probeURLs },
                set: { value in mutate { $0.probeURLs = value } })
    }

    private var globalModeBinding: Binding<String> {
        Binding(
            get: { currentSettings.urlTestDefault.mode },
            set: { value in mutate { $0.urlTestDefault.mode = value } }
        )
    }

    private var globalPoolBinding: Binding<Int> {
        Binding(
            get: { currentSettings.urlTestDefault.pool },
            set: { value in mutate { $0.urlTestDefault.pool = value } }
        )
    }

    private var globalToleranceBinding: Binding<Int> {
        Binding(
            get: { currentSettings.urlTestDefault.poolTolerance },
            set: { value in mutate { $0.urlTestDefault.poolTolerance = value } }
        )
    }

    private var globalStickyBinding: Binding<Bool> {
        Binding(
            get: { currentSettings.urlTestDefault.sticky },
            set: { value in mutate { $0.urlTestDefault.sticky = value } }
        )
    }

    private func effectiveURLMode(_ group: LXConfigGroup) -> String {
        if let individual = currentSettings.urlTests[group.tag] {
            if individual.mode == "profile" { return "\(group.mode) (из профиля)" }
            return "\(individual.mode) (свой)"
        }
        let common = currentSettings.urlTestDefault.mode
        return common == "profile" ? "\(group.mode) (из профиля)" : "\(common) (общий)"
    }

    private func urlSetting(_ tag: String) -> LXURLTestOverride {
        currentSettings.urlTests[tag] ?? currentSettings.urlTestDefault
    }

    private func changeURLSetting(_ tag: String, _ update: (inout LXURLTestOverride) -> Void) {
        mutate { settings in
            var item = settings.urlTests[tag] ?? settings.urlTestDefault
            update(&item)
            // Keep explicit "profile" to allow opting out of the global mode.
            settings.urlTests[tag] = item
        }
    }

    private func urlModeBinding(_ tag: String) -> Binding<String> {
        Binding(
            get: { currentSettings.urlTests[tag]?.mode ?? "inherit" },
            set: { value in
                if value == "inherit" {
                    mutate { $0.urlTests.removeValue(forKey: tag) }
                } else {
                    changeURLSetting(tag) { $0.mode = value }
                }
            }
        )
    }

    private func poolBinding(_ tag: String) -> Binding<Int> {
        Binding(get: { urlSetting(tag).pool }, set: { value in changeURLSetting(tag) { $0.pool = value } })
    }

    private func toleranceBinding(_ tag: String) -> Binding<Int> {
        Binding(get: { urlSetting(tag).poolTolerance }, set: { value in changeURLSetting(tag) { $0.poolTolerance = value } })
    }

    private func stickyBinding(_ tag: String) -> Binding<Bool> {
        Binding(get: { urlSetting(tag).sticky }, set: { value in changeURLSetting(tag) { $0.sticky = value } })
    }

    private func dnsBinding(_ tag: String) -> Binding<String> {
        Binding(
            get: { currentSettings.dnsGroups[tag] ?? "profile" },
            set: { value in
                mutate { settings in
                    if value == "profile" { settings.dnsGroups.removeValue(forKey: tag) }
                    else { settings.dnsGroups[tag] = value }
                }
            }
        )
    }

    private var wgIdleBinding: Binding<String> {
        Binding(get: { currentSettings.wgIdle }, set: { value in mutate { $0.wgIdle = value } })
    }

    @MainActor
    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let id = await SharedPreferences.selectedProfileID.get()
            guard let profile = try await ProfileManager.get(id) else { return }
            let source = try await profile.readAsync()
            let info = try LXProfileOverrides.inspect(source)
            let persisted = try LXOverridesStore.decode(await SharedPreferences.lxOverridesJSON.get())
            profileID = id
            profileContent = source
            summary = info
            saved = persisted
            draft = persisted
        } catch {
            alert = AlertState(action: "load LX settings", error: error)
        }
    }

    @MainActor
    private func apply() async {
        guard !isApplying, draft != saved else { return }
        isApplying = true
        defer { isApplying = false }
        let previousJSON = await SharedPreferences.lxOverridesJSON.get()
        do {
            let desiredJSON = try draft.encode()
            _ = try LXProfileOverrides.apply(profileContent, profileID: profileID, storedJSON: desiredJSON)
            let activeID = await SharedPreferences.selectedProfileID.get()
            guard activeID == profileID else {
                throw NSError(domain: "LXRuntimeSettings", code: 1, userInfo: [NSLocalizedDescriptionKey: "Активный профиль изменился. Открой настройки LX заново."])
            }
            await SharedPreferences.lxOverridesJSON.set(desiredJSON)
            guard await SharedPreferences.lxOverridesJSON.get() == desiredJSON else {
                throw NSError(domain: "LXRuntimeSettings", code: 2, userInfo: [NSLocalizedDescriptionKey: "Настройки не сохранились."])
            }
            if let profile = environments.extensionProfile, profile.status.isConnected {
                do {
                    try await profile.reloadService()
                } catch {
                    await SharedPreferences.lxOverridesJSON.set(previousJSON)
                    try? await profile.reloadService()
                    throw error
                }
            }
            saved = draft
        } catch {
            alert = AlertState(action: "apply LX settings", error: error)
        }
    }
}
