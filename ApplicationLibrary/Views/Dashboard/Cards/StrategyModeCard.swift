import Library
import SwiftUI

// Dashboard mode selector. Live route details are rendered by
// CurrentRoutesCard; the counters below are the latest successful URLTest
// probes, not per-connection network guarantees.
@MainActor
public struct StrategyModeCard: View {
    @EnvironmentObject private var commandClient: CommandClient
    @State private var alert: AlertState?
    @State private var switchingMode: StrategyModeSpec?

    public init() {}

    public var body: some View {
        Group {
            if let strategyGroup {
                DashboardCardView(title: "") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            DashboardCardHeader(icon: "wand.and.stars", title: "Выбор узлов")
                            Spacer(minLength: 4)
                            Button {
                                alert = AlertState(title: "URLTest", message: "Числа — последние успешные замеры URLTest; не подтверждают доступность сейчас и не учитывают карантин.")
                            } label: {
                                Image(systemName: "info.circle")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Что означают числа")
                        }

                        // Primary strategy first: full width and separate Base/White
                        // availability, instead of a misleading aggregate count.
                        if let smartMode = dashboardModes.first(where: { $0.title == "Авто • Умный" }) {
                            modeButton(smartMode, strategyGroup: strategyGroup, isWide: true)
                        }

                        // Three equal tiles, in Smart fallback priority order.
                        LazyVGrid(
                            columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3),
                            spacing: 8
                        ) {
                            ForEach(dashboardModes.filter { $0.title != "Авто • Умный" }) { mode in
                                modeButton(mode, strategyGroup: strategyGroup, isWide: false)
                            }
                        }

                        if let active = activeMode(strategyGroup: strategyGroup), dashboardModes.contains(active) {
                            Text("Повторное нажатие — сменить узел")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
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

                    }
                }
                .alert($alert)
            }
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
                        smartTier("Базовые", tag: availableBaseTag, strategyGroup: strategyGroup)
                        if availableChainTag != nil {
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
                            smartTier("🔗", tag: availableChainTag, strategyGroup: strategyGroup)
                        }
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
                        smartTier("Белые", tag: availableWhiteTag, strategyGroup: strategyGroup)
                    }
                    .font(.caption.monospacedDigit())
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .combine)
                }
                .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            } else {
                VStack(spacing: 3) {
                    if switchingMode == mode {
                        ProgressView().controlSize(.small)
                            .frame(height: 24)
                    } else {
                        let count = respondingCount(mode, strategyGroup: strategyGroup)
                        Text(count.map { String($0) } ?? "—")
                            .font(.title3.monospacedDigit().weight(.semibold))
                            .foregroundColor((count ?? 0) > 0 ? .urlTestGood : .secondary)
                            .accessibilityLabel("Последние успешные замеры URLTest: " + (count.map { String($0) } ?? "нет данных"))
                    }
                    Text(shortTitle(mode))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                .frame(maxWidth: .infinity, minHeight: 44)
                .padding(.horizontal, 4)
                .padding(.vertical, 6)
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

    private func shortTitle(_ mode: StrategyModeSpec) -> String {
        switch mode.title {
        case "Авто • Базовая": return "Базовые"
        case "Авто • 🔗 Цепочки": return "Цепочки"
        case "Авто • Белые": return "Белые"
        default: return mode.title
        }
    }

    private func smartTier(_ title: String, tag: String?, strategyGroup: OutboundGroup) -> some View {
        let count = respondingCount(rootTag: tag)
        let smart = StrategyModeCatalog.modes.first { $0.title == "Авто • Умный" }
        let smartTag = smart.flatMap { StrategyModeCatalog.strategyTarget($0, strategyTags: strategyTags(strategyGroup)) }
        let currentTier = commandClient.groups?.first { $0.tag == smartTag }?.selected
        let isCurrent = tag != nil && tag == currentTier && smartTag != nil && strategyGroup.selected == smartTag
        return HStack(spacing: 3) {
            Text(title)
            Text(count.map { String($0) } ?? "—")
        }
        .font(.caption.monospacedDigit().weight(isCurrent ? .semibold : .regular))
        .foregroundColor(isCurrent ? Color.accentColor : .secondary)
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

    private var availableChainTag: String? {
        guard let tags = commandClient.groups?.map(\.tag) else { return nil }
        return ["Ru 🔗 Авто"].first { tags.contains($0) }
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

    // Keep legacy modes in the catalog for existing profile detection, but
    // do not expose Full or Manual as dashboard shortcuts.
    private var dashboardModes: [StrategyModeSpec] {
        ["Авто • Умный", "Авто • Базовая", "Авто • 🔗 Цепочки", "Авто • Белые"].compactMap { title in
            StrategyModeCatalog.modes.first { $0.title == title }
        }
    }

    private func unavailableModes(strategyGroup: OutboundGroup) -> [StrategyModeSpec]? {
        let modes = dashboardModes.filter { !availability($0, strategyGroup: strategyGroup) }
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
                // rotates within the effective policy. Smart base > chains > white
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
