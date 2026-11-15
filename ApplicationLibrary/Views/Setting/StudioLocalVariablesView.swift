#if os(iOS)
import Foundation
import SwiftUI

/// Client-owned generator defaults. Never contains tokens, credentials or subscription URLs.
/// These variables affect ONLY future local generation, never the selected/running profile.
public enum StudioGeneratorVariables {
    public struct Field: Identifiable {
        public let key: String
        public let name: String
        public let hint: String
        public var id: String { key }
    }
    public struct Category: Identifiable {
        public let name: String
        public let fields: [Field]
        public var id: String { name }
    }

    public static let categories: [Category] = [
        Category(name: "Фильтры и группы", fields: [
            Field(key: "EXCLUDE_NODES", name: "Исключённые узлы", hint: "Фрагменты имён через |"),
            Field(key: "WHITE_NODES", name: "Белые узлы", hint: "Фрагменты имён через |"),
            Field(key: "GEMINI_NODES", name: "Gemini+", hint: "Только Gemini-узлы, фрагменты имён через |"),
            Field(key: "TEST_NODES_JSON", name: "Подмножества узлов", hint: "JSON: группы и списки разрешённых имён"),
        ]),
        Category(name: "Проверка доступности", fields: [
            Field(key: "TEST_URL", name: "Адрес проверки", hint: "HTTPS без секретов и авторизации"),
            Field(key: "TEST_MODE", name: "Алгоритм LX", hint: "failover или least_test"),
            Field(key: "TEST_INTERVAL", name: "Интервал, с", hint: "Минимум 15 c для LX"),
            Field(key: "TEST_TOLERANCE", name: "Порог задержки, мс", hint: "По умолчанию 175"),
            Field(key: "TEST_IDLE", name: "Ожидание простоя, с", hint: "По умолчанию 180"),
            Field(key: "CONNECT_TIMEOUT", name: "Тайм-аут соединения, с", hint: "2–30"),
            Field(key: "TEST_INTERRUPT", name: "Прерывать соединения URLTest", hint: "true / false"),
            Field(key: "SELECTOR_INTERRUPT", name: "Прерывать при смене селектора", hint: "true / false"),
        ]),
        Category(name: "DNS и сеть", fields: [
            Field(key: "DNS_RACE", name: "DNS Race", hint: "true / false"),
            Field(key: "DNS_OPTIMISTIC", name: "Оптимистичный кеш", hint: "true / false"),
            Field(key: "DNS_CAPACITY", name: "Размер кеша", hint: "1024–65536"),
            Field(key: "DNS_STALE", name: "Устаревший кеш, с", hint: "30–3600"),
            Field(key: "DNS_TIMEOUT", name: "Тайм-аут DNS, с", hint: "1–10"),
            Field(key: "NET_FALLBACK", name: "Сетевой fallback", hint: "true / false"),
            Field(key: "NET_DELAY_MS", name: "Задержка fallback, мс", hint: "100–3000"),
            Field(key: "CORP_DNS_DYNAMIC", name: "DNS из OpenConnect", hint: "true / false"),
        ]),
        Category(name: "Дополнительно", fields: [
            Field(key: "TLS_RESILIENCE_MODE", name: "TLS Resilience (LX)", hint: "off / record / fragment"),
            Field(key: "GUEST_CELLULAR_DIRECT_CIDRS", name: "Guest: служебные IPv4 CIDR", hint: "Подтверждённые /24–/32 через |"),
            Field(key: "USER_AGENT", name: "User-Agent", hint: "По умолчанию sing-box"),
        ]),
    ]

    public static let key = "lx.generator.localSafeVariables.v1"
    private static var allowed: Set<String> {
        Set(categories.flatMap { $0.fields.map(\.key) })
    }

    public static func load() -> [String: String] {
        let stored = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        return stored.filter { allowed.contains($0.key) }
    }

    public static func lines() -> String {
        let values = load()
        return values.keys.sorted().map { "\($0)=\(values[$0] ?? "")" }.joined(separator: "\n")
    }

    public static func save(_ values: [String: String]) throws {
        guard values.keys.allSatisfy({ allowed.contains($0) }) else {
            throw GeneratorSettingsError.invalid("Допускаются только локальные переменные из каталога.")
        }
        let booleanNames: Set<String> = [
            "TEST_INTERRUPT", "SELECTOR_INTERRUPT", "DNS_RACE",
            "DNS_OPTIMISTIC", "NET_FALLBACK", "CORP_DNS_DYNAMIC",
        ]
        let bounds: [String: ClosedRange<Int>] = [
            "TEST_INTERVAL": 15...3600,
            "TEST_TOLERANCE": 0...2000,
            "TEST_IDLE": 0...3600,
            "CONNECT_TIMEOUT": 2...30,
            "DNS_CAPACITY": 1024...65536,
            "DNS_STALE": 30...3600,
            "DNS_TIMEOUT": 1...10,
            "NET_DELAY_MS": 100...3000,
        ]
        for (name, value) in values {
            guard !value.contains("\n"), !value.contains("\r"), value.utf8.count <= 8192 else {
                throw GeneratorSettingsError.invalid("\(name): слишком длинное или многострочное значение")
            }
            if booleanNames.contains(name) && !["true", "false"].contains(value) {
                throw GeneratorSettingsError.invalid("\(name): допустимо true или false")
            }
            if let limit = bounds[name], let number = Int(value), limit.contains(number) {
                // Valid range
            } else if bounds[name] != nil {
                throw GeneratorSettingsError.invalid("\(name): неверное числовое значение")
            }
        }
        if let mode = values["TEST_MODE"], !["failover", "least_test"].contains(mode) {
            throw GeneratorSettingsError.invalid("TEST_MODE: failover или least_test")
        }
        if let mode = values["TLS_RESILIENCE_MODE"], !["off", "record", "fragment"].contains(mode) {
            throw GeneratorSettingsError.invalid("TLS_RESILIENCE_MODE: off, record или fragment")
        }
        if let text = values["TEST_NODES_JSON"],
           (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] == nil {
            throw GeneratorSettingsError.invalid("TEST_NODES_JSON должен быть JSON-объектом")
        }
        if let link = values["TEST_URL"] {
            guard let parts = URLComponents(string: link), parts.scheme == "https",
                  parts.host != nil, parts.user == nil, parts.password == nil,
                  (parts.queryItems ?? []).isEmpty else {
                throw GeneratorSettingsError.invalid("TEST_URL: используйте публичный HTTPS URL без параметров авторизации")
            }
        }
        UserDefaults.standard.set(values, forKey: key)
    }

    public enum GeneratorSettingsError: LocalizedError {
        case invalid(String)
        public var errorDescription: String? {
            if case let .invalid(message) = self { return message }
            return nil
        }
    }
}

@MainActor
public struct StudioLocalVariablesView: View {
    @State private var values = StudioGeneratorVariables.load()
    @State private var result: String?
    @State private var saved = true

    public init() {}

    public var body: some View {
        Form {
            Section {
                Label("Настройки только для новых локально создаваемых профилей. Действующий VPN, Yandex Cloud и подписки не изменяются.",
                      systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(StudioGeneratorVariables.categories) { category in
                Section(category.name) {
                    ForEach(category.fields) { field in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(field.name)
                                .font(.subheadline.weight(.medium))
                            TextField(field.hint, text: binding(field.key))
                                .font(.system(.subheadline, design: .monospaced))
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            Text(field.key)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
            Section {
                Button {
                    do {
                        try StudioGeneratorVariables.save(values.filter { !$0.value.isEmpty })
                        saved = true
                        result = "Сохранено на устройстве. Локальный генератор использует эти значения при следующем открытии."
                    } catch {
                        result = error.localizedDescription
                    }
                } label: {
                    Label("Сохранить локальные параметры", systemImage: "checkmark.circle")
                }
                if let result {
                    Text(result).font(.footnote).foregroundStyle(.secondary)
                }
                Button("Восстановить значения генератора", role: .destructive) {
                    values = [:]
                    result = "Для удаления сохранённых значений нажмите «Сохранить»."
                }
            }
        }
        .navigationTitle("Переменные генератора")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func binding(_ key: String) -> Binding<String> {
        Binding(
            get: { values[key] ?? "" },
            set: { newValue in
                values[key] = newValue
                saved = false
                result = nil
            }
        )
    }
}
#endif
