import Libbox
import Library
import SwiftUI

//gru: strategy quick-switch card (separate card, clash mode picker untouched).
// Buttons map to selector groups of the generated profile:
//   Авто • Базовая -> Стратегия: Авто · Базовая, Gemini: Gemini • Super • A
//   Авто • Белые   -> Стратегия: Авто · Белые,   Gemini: Gemini • Super • A
//   Авто • Полная  -> Стратегия: Авто · Полная,  Gemini: Gemini • Super • A
//   Ручной режим   -> Стратегия: Ручной выбор,    Gemini: Gemini • Выбор
// A button is shown only when the profile actually has the target group.
public struct StrategyModeCard: View {
    @EnvironmentObject private var commandClient: CommandClient
    @State private var alert: AlertState?

    private struct StrategyOption {
        let title: String
        let strategyOutbound: String
        let geminiOutbound: String
    }

    private static let strategyGroupTag = "Стратегия"
    private static let geminiGroupTag = "Gemini"

    private var allOptions: [StrategyOption] {
        [
            StrategyOption(title: "Авто • Базовая", strategyOutbound: "Авто · Базовая", geminiOutbound: "Gemini • Super • A"),
            StrategyOption(title: "Авто • Белые", strategyOutbound: "Авто · Белые", geminiOutbound: "Gemini • Super • A"),
            StrategyOption(title: "Авто • Полная", strategyOutbound: "Авто · Полная", geminiOutbound: "Gemini • Super • A"),
            StrategyOption(title: "Ручной режим", strategyOutbound: "Ручной выбор", geminiOutbound: "Gemini • Выбор"),
        ]
    }

    public init() {}

    public var body: some View {
        if let strategyGroup {
            DashboardCardView(title: "") {
                VStack(alignment: .leading, spacing: 12) {
                    DashboardCardHeader(icon: "wand.and.stars", title: "Режим")
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                        ForEach(visibleOptions, id: \.title) { option in
                            Button {
                                Task {
                                    await apply(option)
                                }
                            } label: {
                                Text(option.title)
                                    .font(.system(size: buttonFontSize, weight: .medium))
                                    .foregroundStyle(isActive(option, strategyGroup: strategyGroup) ? .primary : .secondary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: buttonHeight)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(isActive(option, strategyGroup: strategyGroup) ? Color.primary.opacity(0.16) : Color.secondary.opacity(0.1))
                            )
                        }
                    }
                }
            }
            .alert($alert)
        }
    }

    private var strategyGroup: OutboundGroup? {
        commandClient.groups?.first { $0.tag == Self.strategyGroupTag && $0.selectable }
    }

    private var geminiGroup: OutboundGroup? {
        commandClient.groups?.first { $0.tag == Self.geminiGroupTag && $0.selectable }
    }

    private var visibleOptions: [StrategyOption] {
        guard let strategyGroup else {
            return []
        }
        return allOptions.filter { option in
            strategyGroup.items.contains { $0.tag == option.strategyOutbound }
        }
    }

    private func isActive(_ option: StrategyOption, strategyGroup: OutboundGroup) -> Bool {
        strategyGroup.selected == option.strategyOutbound
    }

    private func apply(_ option: StrategyOption) async {
        do {
            try await CommandTarget.standaloneClient().selectOutbound(Self.strategyGroupTag, outboundTag: option.strategyOutbound)
            if let geminiGroup, geminiGroup.items.contains(where: { $0.tag == option.geminiOutbound }) {
                try await CommandTarget.standaloneClient().selectOutbound(Self.geminiGroupTag, outboundTag: option.geminiOutbound)
            }
        } catch {
            alert = AlertState(action: "select outbound", error: error)
        }
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
