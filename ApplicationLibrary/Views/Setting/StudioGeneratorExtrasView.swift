#if os(iOS)
import Foundation
import SwiftUI

/// Native advanced-variable editor. The source generator still consumes
/// KEY=VALUE internally, but users never have to edit a block of code.
struct StudioGeneratorExtrasView: View {
    @Binding var variables: String
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [Entry] = []
    @State private var message: String?
    @State private var loaded = false

    private struct Entry: Identifiable {
        let id = UUID()
        var key: String
        var value: String
    }

    var body: some View {
        Form {
            Section {
                Label("Дополнительные параметры генератора, для которых пока нет отдельного контроллера. Каждый параметр задаётся в двух полях.",
                      systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Дополнительные параметры") {
                ForEach($entries) { $entry in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            TextField("Название параметра", text: $entry.key)
                                .textInputAutocapitalization(.characters)
                                .autocorrectionDisabled()
                                .font(.subheadline.weight(.medium))
                            Button(role: .destructive) {
                                entries.removeAll { $0.id == entry.id }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                        }
                        if StudioDocumentFormatter.isSensitiveKey(entry.key) {
                            SecureField("Значение", text: $entry.value)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        } else {
                            TextField("Значение", text: $entry.value)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                    }
                    .padding(.vertical, 4)
                }
                Button {
                    entries.append(Entry(key: "", value: ""))
                } label: {
                    Label("Добавить параметр", systemImage: "plus.circle")
                }
            }
            Section {
                Button {
                    save()
                } label: {
                    Label("Сохранить дополнительные параметры", systemImage: "checkmark.circle")
                }
                if let message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Дополнительные параметры")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            let all = (try? LocalGeneratorEngine.parseVariables(variables)) ?? [:]
            let owned = Set(StudioGeneratorVariables.categories.flatMap { $0.fields.map(\.key) })
            entries = all.keys.sorted().filter { !owned.contains($0) }.map {
                Entry(key: $0, value: all[$0] ?? "")
            }
        }
    }

    private func save() {
        var dictionary = StudioGeneratorVariables.load()
        let owned = Set(StudioGeneratorVariables.categories.flatMap { $0.fields.map(\.key) })
        for entry in entries {
            let key = entry.key.trimmingCharacters(in: .whitespacesAndNewlines)
            if key.isEmpty && entry.value.isEmpty { continue }
            guard !owned.contains(key) else {
                message = "«\(key)» уже настраивается в основном разделе параметров."
                return
            }
            guard dictionary[key] == nil else {
                message = "Параметр \(key) добавлен дважды."
                return
            }
            dictionary[key] = entry.value
        }
        let body = dictionary.keys.sorted().map { "\($0)=\(dictionary[$0] ?? "")" }.joined(separator: "\n")
        do {
            _ = try LocalGeneratorEngine.parseVariables(body)
            variables = body
            dismiss()
        } catch {
            message = error.localizedDescription
        }
    }
}
#endif
