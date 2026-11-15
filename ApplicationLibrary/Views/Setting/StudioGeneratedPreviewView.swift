#if os(iOS)
import Foundation
import SwiftUI

/// Visual preview of a generated config. The result is intentionally not
/// installed or applied by viewing it.
struct StudioGeneratedPreviewView: View {
    let content: String

    private var document: StudioDocument? {
        try? StudioDocument(content: content)
    }

    var body: some View {
        List {
            if let document {
                Section {
                    Label("Предварительный просмотр созданного профиля. Просмотр не устанавливает VPN и не меняет текущий профиль.",
                          systemImage: "eye")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("Состав профиля") {
                    ForEach(document.categories) { category in
                        NavigationLink {
                            StudioCategoryView(category: category)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: category.icon)
                                    .foregroundStyle(.tint)
                                    .frame(width: 30)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(category.title).font(.subheadline.weight(.medium))
                                    Text(category.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                Spacer(minLength: 5)
                                Text("\(category.items.count)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            } else {
                Section {
                    Label("Результат не является корректным профилем JSON",
                          systemImage: "exclamationmark.triangle")
                }
            }
        }
        .navigationTitle("Просмотр профиля")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    NavigationLink {
                        StudioJSONView(title: "Технический JSON", content: content)
                    } label: {
                        Label("Технический JSON", systemImage: "curlybraces")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
    }
}
#endif
