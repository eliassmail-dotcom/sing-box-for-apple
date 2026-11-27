import Library
import SwiftUI

/// Full-width vertical summary of the currently selected outbound tags.
/// Preserve the exact names from the active configuration, including comments,
/// suffixes and other meaningful node labels. Only Gemini chains receive
/// a small link icon, with no redundant "chain" text.
@MainActor
public struct CurrentRoutesCard: View {
    @EnvironmentObject private var commandClient: CommandClient
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var strategyOutbound = OutboundResolverModel(rootTag: "Стратегия")
    @StateObject private var geminiOutbound = OutboundResolverModel(rootTag: "Gemini")

    public init() {}

    public var body: some View {
        Group {
            if hasStrategy || hasGemini {
                DashboardCardView(title: "") {
                    VStack(alignment: .leading, spacing: 10) {
                        DashboardCardHeader(icon: "network", title: "Маршруты")

                        VStack(alignment: .leading, spacing: 12) {
                            if hasStrategy {
                                routeRow(title: "Основной маршрут", result: strategyOutbound.result, showsChain: false)
                            }

                            if hasStrategy && hasGemini {
                                Divider()
                            }

                            if hasGemini {
                                routeRow(title: "Gemini", result: geminiOutbound.result, showsChain: true)
                            }
                        }
                    }
                }
                .onAppear {
                    strategyOutbound.bind(to: commandClient)
                    geminiOutbound.bind(to: commandClient)
                }
                .onChangeCompat(of: scenePhase) { phase in
                    guard phase == .active else { return }
                    commandClient.refreshGroups()
                }
            }
        }
    }

    private var hasStrategy: Bool {
        commandClient.groups?.contains {
            $0.tag == StrategyModeCatalog.strategyGroupTag && $0.selectable
        } == true
    }

    private var hasGemini: Bool {
        commandClient.groups?.contains {
            $0.tag == StrategyModeCatalog.geminiGroupTag && $0.selectable
        } == true
    }

    private func routeRow(title: String, result: ResolvedOutbound?, showsChain: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if showsChain, result?.isChained == true {
                    Image(systemName: "link")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Цепочка")
                }
            }

            HStack(alignment: .top, spacing: 12) {
                // This is the original tag. Never strip suffixes such as
                // "(Gemini)" or "(YouTube без рекламы)" for presentation.
                Text(result?.displayNodeTag ?? "Определяем узел…")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)

                if let delay = result?.latencyMs, delay > 0 {
                    Text("\(delay) мс")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(delayColor(Int(delay)))
                        .fixedSize(horizontal: true, vertical: false)
                } else {
                    Text("—")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }

            if let result, case .incomplete(_) = result.status {
                Text("Маршрут определён не полностью")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func delayColor(_ delay: Int) -> Color {
        if delay < 200 { return .urlTestGood }
        if delay < 500 { return .orange }
        return .red
    }
}
