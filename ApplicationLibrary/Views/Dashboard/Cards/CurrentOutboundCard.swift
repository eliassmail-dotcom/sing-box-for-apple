import Library
import SwiftUI

//gru: dashboard widgets showing the currently selected outbound of a group,
// styled like the item rows on the Groups screen (tag, type, url-test delay).
public struct CurrentOutboundCard: View {
    @EnvironmentObject private var commandClient: CommandClient

    private let groupTag: String
    private let title: LocalizedStringKey

    public init(groupTag: String, title: LocalizedStringKey) {
        self.groupTag = groupTag
        self.title = title
    }

    public var body: some View {
        if let item = currentItem {
            DashboardCardView(title: "") {
                VStack(alignment: .leading, spacing: 12) {
                    DashboardCardHeader(icon: "antenna.radiowaves.left.and.right", title: title)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(item.tag)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.foreground)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: 4)
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(Color.accentColor)
                        }
                        HStack {
                            Text(item.displayType)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 8)
                            if item.urlTestDelay > 0 {
                                Text(item.delayString)
                                    .font(.caption.monospacedDigit().weight(.semibold))
                                    .foregroundColor(item.delayColor)
                            }
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
        }
    }

    private var currentItem: OutboundGroupItem? {
        guard let group = commandClient.groups?.first(where: { $0.tag == groupTag }) else {
            return nil
        }
        return group.items.first { $0.tag == group.selected }
    }
}
