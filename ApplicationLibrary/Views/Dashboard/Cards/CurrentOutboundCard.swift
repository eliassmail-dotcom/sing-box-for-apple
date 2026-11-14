import Library
import Libbox
import SwiftUI

// gru: dashboard widgets showing the actually selected outbound of a root
// group, resolved down to the final node (Dashboard TZ 14.11.2026). The route
// line shows the full traversal; chains show entry → exit hops. Latency is
// the final node's own URL-test delay only.
public struct CurrentOutboundCard: View {
    @EnvironmentObject private var commandClient: CommandClient
    @StateObject private var model: OutboundResolverModel

    private let title: LocalizedStringKey
    private let icon: String

    public init(groupTag: String, title: LocalizedStringKey, icon: String = "antenna.radiowaves.left.and.right") {
        self.title = title
        self.icon = icon
        _model = StateObject(wrappedValue: OutboundResolverModel(rootTag: groupTag))
    }

    public var body: some View {
        if let result = model.result, let tag = result.selectedTag {
            DashboardCardView(title: "") {
                VStack(alignment: .leading, spacing: 12) {
                    DashboardCardHeader(icon: icon, title: title)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(tag)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.foreground)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: 4)
                            if result.status == .resolved {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(Color.accentColor)
                            } else {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                        Text(routeText(result))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                        HStack {
                            Text(displayType(result))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 8)
                            latencyText(result)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.accentColor.opacity(0.12))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(Color.accentColor, lineWidth: 1)
                    )
                }
            }
            .onAppear {
                model.bind(to: commandClient)
            }
        }
    }

    private func routeText(_ result: ResolvedOutbound) -> String {
        var route = result.groupPath
        if result.chainHops.isEmpty {
            if let tag = result.selectedTag {
                route.append(tag)
            }
        } else {
            route += result.chainHops
        }
        return route.joined(separator: " → ")
    }

    private func displayType(_ result: ResolvedOutbound) -> String {
        guard let type = result.selectedType, !type.isEmpty else { return "—" }
        return LibboxProxyDisplayType(type)
    }

    @ViewBuilder
    private func latencyText(_ result: ResolvedOutbound) -> some View {
        if let latency = result.latencyMs, latency > 0 {
            Text("\(latency)ms")
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundColor(delayColor(Int(latency)))
        } else {
            Text("—")
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    private func delayColor(_ delay: Int) -> Color {
        if delay <= 0 { return .secondary }
        if delay < 200 { return .green }
        if delay < 500 { return .orange }
        return .red
    }
}
