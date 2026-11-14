import Library
import SwiftUI

// Dashboard mode selector + live routed outbounds in one compact card.
// The selector's live state is authoritative; latency counters report the
// latest successful URLTest probes, not per-connection network guarantees.
@MainActor
public struct StrategyModeCard: View {
    @EnvironmentObject private var commandClient: CommandClient
    @EnvironmentObject private var environments: ExtensionEnvironments
    @EnvironmentObject private var profile: ExtensionProfile
    @StateObject private var strategyOutbound = OutboundResolverModel(rootTag: "Стратегия")
    @StateObject private var geminiOutbound = OutboundResolverModel(rootTag: "Gemini")
    @State private var alert: AlertState?
    @State private var switchingMode: StrategyModeSpec?
    @State private var resiliencePreset = LXResiliencePreset.custom.rawValue
    @State private var resilienceProfileID: Int64 = -1
    @State private var resilienceSupported = false
    @State private var applyingResiliencePreset: String?

    public init() {}

    public var body: some View {
        Group {
            if let strategyGroup {
                DashboardCardView(title: "") {
                    VStack(alignment: .leading, spacing: 12) {
                        DashboardCardHeader(icon: "wand.and.stars", title: "Режим")

                        // Primary strategy first: full width and separate Base/White
                        // availability, instead of a misleading aggregate count.
                        if let smartMode = StrategyModeCatalog.modes.first(where: { $0.title == "Авто • Умный" }) {
                            modeButton(smartMode, strategyGroup: strategyGroup, isWide: true)
                        }

                        // Alternative modes retain their existing two-column layout.
                        LazyVGrid(
                            columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                            spacing: 8
                        ) {
                            ForEach(StrategyModeCatalog.modes.filter { $0.title != "Авто • Умный" }) { mode in
                                modeButton(mode, strategyGroup: strategyGroup, isWide: false)
                            }
                        }

                        if activeMode(strategyGroup: strategyGroup) != nil {
                            Text("Повторное нажатие на активный режим — сменить узел")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        if let unavailable = unavailableModes(strategyGroup: strategyGroup), !unavailable.isEmpty {
                            Text("Недоступно в этом профиле: \(unavailable.map(\.title).joined(separator: ", "))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        if activeMode(strategyGroup: strategyGroup) == nil {
                            Text("Смешанная конфигурация")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }

                        if resilienceSupported {
                            Divider()
                            resilienceSelector
                        }

                        Divider()
                        VStack(alignment: .leading, spacing: 12) {
                            currentOutboundRow(
                                title: "Основной маршрут",
                                symbol: "network",
                                result: strategyOutbound.result
                            )
                            if geminiGroup != nil {
                                currentOutboundRow(
                                    title: "Gemini",
                                    symbol: "sparkles",
                                    result: geminiOutbound.result
                                )
                            }
                        }
                    }
                }
                .onAppear {
                    // Bind independently of whether a node has resolved: otherwise
                    // nil result hides the view and the subscription never starts.
                    strategyOutbound.bind(to: commandClient)
                    geminiOutbound.bind(to: commandClient)
                }
                .alert($alert)
                .task { await loadResiliencePreset() }
                .onReceive(environments.selectedProfileUpdate) { _ in
                    Task { await loadResiliencePreset() }
                }
                .onReceive(NotificationCenter.default.publisher(for: .lxResilienceSettingsChanged)) { _ in
                    Task { await loadResiliencePreset() }
                }
            }
        }
    }


    // A compact per-profile reliability selector. It is deliberately separate
    // from Strategy: route selectors remain unchanged, and the subscription is
    // never edited by this control.
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
            HStack(spacing: 7) {
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
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .foregroundStyle(selected ? Color.accentColor : Color.primary)
                .frame(maxWidth: .infinity, minHeight: 35)
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(selected ? Color.accentColor.opacity(0.12) : modeTileBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(selected ? Color.accentColor : Color.urlTestNeutral,
                              lineWidth: selected ? 2 : 1)
        )
        .disabled(applyingResiliencePreset != nil || selected)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
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
            guard id == await SharedPreferences.selectedProfileID.get() else { return }
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
            guard id == await SharedPreferences.selectedProfileID.get() else {
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

    @ViewBuilder
    private func modeButton(_ mode: StrategyModeSpec, strategyGroup: OutboundGroup, isWide: Bool) -> some View {
        let isAvailable = availability(mode, strategyGroup: strategyGroup)
        let isActive = activeMode(strategyGroup: strategyGroup) == mode

        Button {
            Task { await handleModeTap(mode) }
        } label: {
            if isWide {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(mode.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Spacer(minLength: 4)
                        if switchingMode == mode {
                            ProgressView().controlSize(.small)
                        } else if isActive {
                            Image(systemName: "arrow.clockwise")
                                .foregroundStyle(Color.accentColor)
                                .font(.caption)
                                .accessibilityLabel("Сменить узел")
                        }
                    }
                    HStack(spacing: 5) {
                        Text("Базовые")
                            .foregroundStyle(.secondary)
                        if let count = respondingCount(rootTag: availableBaseTag) {
                            Text("\(count)")
                                .foregroundColor(.urlTestGood)
                        } else {
                            Text("—").foregroundStyle(.secondary)
                        }
                        Text("·").foregroundStyle(.secondary)
                        Text("Белые")
                            .foregroundStyle(.secondary)
                        if let count = respondingCount(rootTag: availableWhiteTag) {
                            Text("\(count)")
                                .foregroundColor(.urlTestGood)
                        } else {
                            Text("—").foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .font(.caption.monospacedDigit())
                    .accessibilityElement(children: .combine)
                }
                .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            } else {
                HStack(spacing: 6) {
                    Text(mode.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if switchingMode == mode {
                        ProgressView().controlSize(.small)
                    } else if let count = respondingCount(mode, strategyGroup: strategyGroup) {
                        Text("\(count)")
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundColor(.urlTestGood)
                            .accessibilityLabel("Успешный URLTest: \(count) узлов")
                    } else {
                        Text("—").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint(isActive ? "Сменить узел, не меняя стратегию" : "Включить выбранный режим")
        .opacity(isAvailable || isActive ? 1 : 0.45)
        .disabled(!isAvailable || switchingMode != nil)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isActive ? Color.accentColor.opacity(0.12) : modeTileBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(isActive ? Color.accentColor : Color.urlTestNeutral, lineWidth: isActive ? 2 : 1)
        )
        .animation(.easeOut(duration: 0.12), value: isActive)
    }

    private func currentOutboundRow(title: String, symbol: String, result: ResolvedOutbound?) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(nodeDescription(result))
                        .font(.subheadline.weight(.medium))
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let delay = result?.latencyMs, delay > 0 {
                        Text("\(delay) мс")
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundColor(delayColor(Int(delay)))
                            .fixedSize()
                    }
                }
                if let result, case .incomplete = result.status {
                    Text("Маршрут определён не полностью")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func nodeDescription(_ result: ResolvedOutbound?) -> String {
        guard let result else { return "Определяем узел…" }
        if result.chainHops.count > 1 {
            return result.chainHops.joined(separator: " → ")
        }
        return result.selectedTag ?? "Нет данных о выбранном узле"
    }

    private func delayColor(_ delay: Int) -> Color {
        if delay < 200 { return .urlTestGood }
        if delay < 500 { return .orange }
        return .red
    }

    private var strategyGroup: OutboundGroup? {
        commandClient.groups?.first { $0.tag == StrategyModeCatalog.strategyGroupTag && $0.selectable }
    }

    private var geminiGroup: OutboundGroup? {
        commandClient.groups?.first { $0.tag == StrategyModeCatalog.geminiGroupTag && $0.selectable }
    }

    private var availableBaseTag: String? {
        guard let tags = commandClient.groups?.map(\.tag) else { return nil }
        return ["Авто · Базовая", "Авто"].first { tags.contains($0) }
    }

    private var availableWhiteTag: String? {
        guard let tags = commandClient.groups?.map(\.tag) else { return nil }
        return ["Авто · Белые", "Авто · Только белые"].first { tags.contains($0) }
    }

    private func strategyTags(_ group: OutboundGroup) -> [String] {
        group.items.map(\.tag)
    }

    private func respondingCount(_ mode: StrategyModeSpec, strategyGroup: OutboundGroup) -> Int? {
        guard let tag = StrategyModeCatalog.strategyTarget(mode, strategyTags: strategyTags(strategyGroup)) else {
            return nil
        }
        return respondingCount(rootTag: tag)
    }

    private func respondingCount(rootTag: String?) -> Int? {
        guard let rootTag, let groups = commandClient.groups else { return nil }
        let snapshots = groups.map { group in
            ModeLatencyGroup(
                tag: group.tag,
                members: group.items.map {
                    ModeLatencyItem(tag: $0.tag, delayMs: $0.urlTestDelay)
                }
            )
        }
        return ModeRespondingNodeCounter.count(rootTag: rootTag, groups: snapshots)
    }

    private func availability(_ mode: StrategyModeSpec, strategyGroup: OutboundGroup) -> Bool {
        StrategyModeCatalog.isAvailable(
            mode, strategyTags: strategyTags(strategyGroup),
            geminiTags: geminiGroup.map(strategyTags)
        )
    }

    private func unavailableModes(strategyGroup: OutboundGroup) -> [StrategyModeSpec]? {
        let modes = StrategyModeCatalog.modes.filter { !availability($0, strategyGroup: strategyGroup) }
        return modes.isEmpty ? nil : modes
    }

    private func activeMode(strategyGroup: OutboundGroup) -> StrategyModeSpec? {
        StrategyModeCatalog.activeMode(
            strategySelected: strategyGroup.selected,
            geminiSelected: geminiGroup?.selected,
            strategyTags: strategyTags(strategyGroup),
            geminiTags: geminiGroup.map(strategyTags)
        )
    }

    // An active tile is a node-rotation action, not a second selector write.
    // The Strategy and Gemini selectors remain unchanged.
    private func handleModeTap(_ mode: StrategyModeSpec) async {
        guard switchingMode == nil, let strategyGroup else { return }
        if activeMode(strategyGroup: strategyGroup) == mode {
            await changeNode(mode, strategyGroup: strategyGroup)
        } else {
            await apply(mode)
        }
    }

    private func changeNode(_ mode: StrategyModeSpec, strategyGroup: OutboundGroup) async {
        guard let target = StrategyModeCatalog.strategyTarget(
            mode, strategyTags: strategyTags(strategyGroup)
        ), let targetGroup = commandClient.groups?.first(where: { $0.tag == target }) else {
            alert = AlertState(title: "Сменить узел",
                               message: "Группа выбранной стратегии пока недоступна.")
            return
        }

        switchingMode = mode
        defer { switchingMode = nil }
        do {
            if targetGroup.type == "selector" {
                // Manual mode is a regular selector. Choose the next probed
                // live leaf without changing the enclosing Strategy selector.
                let next = StrategyNodeChange.nextHealthyManualTag(
                    current: targetGroup.selected,
                    candidates: targetGroup.items.map {
                        (tag: $0.tag, delayMs: $0.urlTestDelay)
                    }
                )
                guard let next else {
                    alert = AlertState(
                        title: "Сменить узел",
                        message: "В этом режиме нет другого доступного узла. Проверь URLTest."
                    )
                    return
                }
                try await selectNodeOffMainThread(groupTag: target, outboundTag: next)
            } else if targetGroup.type == "urltest" {
                // LX recognizes the reserved command in SelectOutbound and
                // rotates within the effective policy. Smart base > white
                // priority and live connections are preserved by the core.
                try await selectNodeOffMainThread(
                    groupTag: target, outboundTag: StrategyNodeChange.nextNodeCommand
                )
            } else {
                alert = AlertState(
                    title: "Сменить узел",
                    message: "Режим не поддерживает смену узла без изменения маршрутизации."
                )
            }
        } catch {
            alert = AlertState(action: "сменить узел", error: error)
        }
    }

    private func selectNodeOffMainThread(groupTag: String, outboundTag: String) async throws {
        // The core may wait for an in-flight health-check before changing the
        // selection. Do not block the SwiftUI main actor during that RPC.
        try await Task.detached(priority: .userInitiated) {
            try CommandTarget.standaloneClient().selectOutbound(
                groupTag, outboundTag: outboundTag
            )
        }.value
    }

    private func apply(_ mode: StrategyModeSpec) async {
        guard let strategyGroup,
              let strategyTarget = StrategyModeCatalog.strategyTarget(mode, strategyTags: strategyTags(strategyGroup))
        else { return }
        let geminiGroup = self.geminiGroup
        let geminiTarget = StrategyModeCatalog.geminiTarget(mode, geminiTags: geminiGroup.map(strategyTags))
        let originalStrategy = strategyGroup.selected
        let originalGemini = geminiGroup?.selected

        switchingMode = mode
        defer { switchingMode = nil }
        do {
            try await CommandTarget.standaloneClient()
                .selectOutbound(StrategyModeCatalog.strategyGroupTag, outboundTag: strategyTarget)
            if let geminiTarget {
                do {
                    try await CommandTarget.standaloneClient()
                        .selectOutbound(StrategyModeCatalog.geminiGroupTag, outboundTag: geminiTarget)
                } catch {
                    try? await CommandTarget.standaloneClient()
                        .selectOutbound(StrategyModeCatalog.strategyGroupTag, outboundTag: originalStrategy)
                    if let originalGemini {
                        try? await CommandTarget.standaloneClient()
                            .selectOutbound(StrategyModeCatalog.geminiGroupTag, outboundTag: originalGemini)
                    }
                    throw error
                }
            }
        } catch {
            alert = AlertState(action: "select outbound", error: error)
        }
        // Highlight and displayed outbounds follow the live core state.
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
