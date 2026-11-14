import Library
import SwiftUI

// gru: strategy mode card (Dashboard TZ 14.11.2026, stage 4). Four switches
// that drive the real selector state of both root groups («Стратегия» and
// «Gemini»). The active mode is derived from the live core state only — never
// from local SwiftUI state. Modes whose groups are absent from the current
// profile stay visible but disabled; a selector mismatch (e.g. after a manual
// change in Groups) shows the mixed-configuration state instead.
// Mode ↔ tag mapping lives in StrategyModeCatalog (unit-tested).
public struct StrategyModeCard: View {
    @EnvironmentObject private var commandClient: CommandClient
    @State private var alert: AlertState?
    @State private var switchingMode: StrategyModeSpec?

    public init() {}

    public var body: some View {
        if let strategyGroup {
            DashboardCardView(title: "") {
                VStack(alignment: .leading, spacing: 12) {
                    DashboardCardHeader(icon: "wand.and.stars", title: "Режим")
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                        ForEach(StrategyModeCatalog.modes) { mode in
                            modeButton(mode, strategyGroup: strategyGroup)
                        }
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

    @ViewBuilder
    private func modeButton(_ mode: StrategyModeSpec, strategyGroup: OutboundGroup) -> some View {
        let availability = availability(mode, strategyGroup: strategyGroup)
        let isActive = activeMode(strategyGroup: strategyGroup) == mode
        let isSwitching = switchingMode != nil
        Button {
            Task {
                await apply(mode)
            }
        } label: {
            Group {
                if switchingMode == mode {
                    ProgressView()
                } else {
                    Text(mode.title)
                        .font(.system(size: buttonFontSize, weight: .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: buttonHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isActive ? .primary : availability ? .secondary : .tertiary)
        .opacity(availability || isActive ? 1 : 0.45)
        .disabled(!availability || isSwitching)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isActive ? Color.primary.opacity(0.16) : Color.secondary.opacity(0.1))
        )
    }

    private var strategyGroup: OutboundGroup? {
        commandClient.groups?.first { $0.tag == StrategyModeCatalog.strategyGroupTag && $0.selectable }
    }

    private var geminiGroup: OutboundGroup? {
        commandClient.groups?.first { $0.tag == StrategyModeCatalog.geminiGroupTag && $0.selectable }
    }

    private func strategyTags(_ group: OutboundGroup) -> [String] {
        group.items.map(\.tag)
    }

    private func availability(_ mode: StrategyModeSpec, strategyGroup: OutboundGroup) -> Bool {
        StrategyModeCatalog.isAvailable(mode, strategyTags: strategyTags(strategyGroup), geminiTags: geminiGroup.map(strategyTags))
    }
    private func unavailableModes(strategyGroup: OutboundGroup) -> [StrategyModeSpec]? {
        let unavailable = StrategyModeCatalog.modes.filter { !availability($0, strategyGroup: strategyGroup) }
        return unavailable.isEmpty ? nil : unavailable
    }

    private func activeMode(strategyGroup: OutboundGroup) -> StrategyModeSpec? {
        StrategyModeCatalog.activeMode(
            strategySelected: strategyGroup.selected,
            geminiSelected: geminiGroup?.selected,
            strategyTags: strategyTags(strategyGroup),
            geminiTags: geminiGroup.map(strategyTags)
        )
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
            try await CommandTarget.standaloneClient().selectOutbound(StrategyModeCatalog.strategyGroupTag, outboundTag: strategyTarget)
            if let geminiTarget {
                do {
                    try await CommandTarget.standaloneClient().selectOutbound(StrategyModeCatalog.geminiGroupTag, outboundTag: geminiTarget)
                } catch {
                    // Roll back both groups to the pre-switch state so the
                    // profile never stays half-switched; if that also fails,
                    // the live-state check surfaces the mixed state.
                    try? await CommandTarget.standaloneClient().selectOutbound(StrategyModeCatalog.strategyGroupTag, outboundTag: originalStrategy)
                    if let originalGemini {
                        try? await CommandTarget.standaloneClient().selectOutbound(StrategyModeCatalog.geminiGroupTag, outboundTag: originalGemini)
                    }
                    throw error
                }
            }
        } catch {
            alert = AlertState(action: "select outbound", error: error)
        }
        // No local "success" state: the highlight follows the live group
        // states pushed by the core (see activeMode).
    }

    private var buttonHeight: CGFloat {
        #if os(tvOS)
            60
        #elseif os(macOS)
            32
        #else
            44
        #endif
    }

    private var buttonFontSize: CGFloat {
        #if os(macOS)
            13
        #else
            15
        #endif
    }
}
