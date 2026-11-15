import Foundation
import SwiftUI

#if os(iOS)
import Libbox
import Library

/// Isolated migration tool. It generates and imports a new local profile but
/// NEVER changes the current active profile, VPN session or remote subscription.
@MainActor
public struct LocalGeneratorView: View {
    @EnvironmentObject private var environments: ExtensionEnvironments

    @State private var variables = ""
    @State private var subscriptionURL = ""
    @State private var pastedSubscription = ""
    @State private var fallbackEnabled = false
    @State private var proxyURL = ""
    @State private var proxyToken = ""
    @State private var variant = "personal"
    @State private var core = "lx"
    @State private var platform = "ios"
    @State private var logLevel = "info"
    @State private var profileName = "Локальный VPN"

    @State private var isGenerating = false
    @State private var isCreating = false
    @State private var resultJSON = ""
    @State private var resultSignature = ""
    @State private var exportURL: URL?
    @State private var resultOrigin = ""
    @State private var resultNodes = 0
    @State private var alert: AlertState?

    private let engine = LocalGeneratorEngine()

    public init() {}

    public var body: some View {
        FormView {
            Section {
                Text("Изолированный локальный генератор на основе v1.4.48r2. Профиль Яндекс-функции и текущий VPN не изменяются.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Исходная подписка") {
                TextField("HTTPS-ссылка на VLESS-подписку", text: $subscriptionURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                Text("Если URL не задан здесь, используется SUB_URL из переменных ниже. Подписка скачивается напрямую с iPhone.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("Или вставьте текст подписки вручную:")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                TextEditor(text: $pastedSubscription)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(minHeight: 70, maxHeight: 130)
            }

            Section("Переменные генератора · KEY=VALUE") {
                TextEditor(text: $variables)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(minHeight: 130, maxHeight: 250)
                Text("Все параметры v1.4.48r2: EXCLUDE_NODES, WHITE_NODES, GEMINI_NODES, TEST_*, DNS_*, NET_*, SELECTOR_INTERRUPT и другие. Отсутствующие переменные получают исходные значения генератора. Токены доступа Яндекс-функции для локального формирования не требуются.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Вариант выходного JSON") {
                Picker("Профиль", selection: $variant) {
                    Text("Личный").tag("personal")
                    Text("Корпоративный").tag("corporate")
                    Text("Гостевой").tag("guest")
                    Text("NB · без белых узлов").tag("nb")
                    Text("CD · два OpenConnect").tag("cd")
                }
                Picker("Платформа", selection: $platform) {
                    Text("iOS").tag("ios")
                    Text("Windows").tag("windows")
                }
                Picker("Ядро", selection: $core) {
                    Text("sing-box lx++").tag("lx")
                    Text("Стандартное sing-box").tag("upstream")
                }
                Picker("Логирование", selection: $logLevel) {
                    Text("Info").tag("info")
                    if platform == "ios" {
                        Text("Debug").tag("debug")
                    }
                }
            }

            Section("Резервный источник узлов") {
                Toggle("Яндекс-прокси при недоступности подписки", isOn: $fallbackEnabled)
                if fallbackEnabled {
                    TextField("HTTPS URL функции-proxy", text: $proxyURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    SecureField("Ключ доступа к прокси (не менее 32 символов)", text: $proxyToken)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("Нужен отдельный API Яндекс-функции, отдающий только сырую подписку/узлы. Старая функция, возвращающая готовый JSON, для этой роли не подходит. URL исходной подписки и её токен через Яндекс не передаются.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Прямой источник используется всегда; Яндекс не вызывается.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Генерация") {
                Button {
                    Task { await generate() }
                } label: {
                    HStack {
                        Label("Сгенерировать JSON", systemImage: "curlybraces")
                        Spacer()
                        if isGenerating { ProgressView() }
                    }
                }
                .disabled(isGenerating || isCreating)
                if !resultJSON.isEmpty {
                    Text("Источник: \(resultOrigin) · узлов VLESS: \(resultNodes)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: .constant(resultJSON))
                        .font(.system(.caption2, design: .monospaced))
                        .frame(minHeight: 180, maxHeight: 320)
                    if #available(iOS 16.0, *), let exportURL {
                        ShareLink(item: exportURL) {
                            Label("Экспортировать JSON", systemImage: "square.and.arrow.up")
                        }
                    }
                }
            }

            Section("Создать профиль в приложении") {
                TextField("Название", text: $profileName)
                Button {
                    Task { await createProfile() }
                } label: {
                    HStack {
                        Label("Создать профиль", systemImage: "plus.rectangle.on.folder")
                        Spacer()
                        if isCreating { ProgressView() }
                    }
                }
                .disabled(!isCurrentResult || isCreating || isGenerating || platform != "ios")
                Text(platform == "ios"
                     ? "Создаёт отдельный локальный профиль после проверки JSON ядром. Не переключает текущий профиль и не запускает VPN."
                     : "Windows JSON можно экспортировать. Кнопка «Создать профиль» доступна для iOS.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Локальный генератор")
        .navigationBarTitleDisplayMode(.inline)
        .alert($alert)
        .onChange(of: platform) { newValue in
            if newValue == "windows" { logLevel = "info" }
        }
    }

    /// Prevent saving a stale JSON after the user modifies any input field.
    private var signature: String {
        [variables, subscriptionURL, pastedSubscription, String(fallbackEnabled),
         proxyURL, proxyToken, variant, core, platform, logLevel].joined(separator: "\u{001F}")
    }

    private var isCurrentResult: Bool {
        !resultJSON.isEmpty && resultSignature == signature
    }

    private func generate() async {
        guard !isGenerating else { return }
        isGenerating = true
        resultJSON = ""
        resultSignature = ""
        exportURL = nil
        defer { isGenerating = false }
        do {
            let inputSignature = signature
            let env = try LocalGeneratorEngine.parseVariables(variables)
            let sourceURL = subscriptionURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? (env["SUB_URL"] ?? "")
                : subscriptionURL.trimmingCharacters(in: .whitespacesAndNewlines)
            let origin: String
            let source: String
            if !pastedSubscription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                source = pastedSubscription
                origin = "Вставленный текст"
            } else {
                guard !sourceURL.isEmpty else {
                    throw LocalGeneratorEngine.GeneratorError.invalidInput(
                        "Укажите SUB_URL или вставьте текст подписки"
                    )
                }
                let loaded = try await LocalGeneratorEngine.loadSubscription(
                    from: sourceURL,
                    userAgent: env["USER_AGENT"] ?? "sing-box",
                    proxyURL: fallbackEnabled ? proxyURL : nil,
                    proxyToken: fallbackEnabled ? proxyToken : nil
                )
                source = loaded.text
                origin = loaded.origin == .direct ? "Напрямую" : "Яндекс-прокси"
            }
            let generated = try await engine.generate(
                variables: env, subscription: source, variant: variant,
                core: core, platform: platform, log: logLevel
            )
            guard let json = generated.json else {
                throw LocalGeneratorEngine.GeneratorError.javascriptUnavailable
            }
            // Validate JSON syntax before presenting or exporting. Full libbox
            // semantic validation is performed again when creating a profile.
            guard let data = json.data(using: .utf8),
                  (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
                throw LocalGeneratorEngine.GeneratorError.generation("INVALID_JSON_OUTPUT")
            }
            guard inputSignature == signature else {
                throw LocalGeneratorEngine.GeneratorError.invalidInput(
                    "Настройки изменились во время генерации. Повторите генерацию."
                )
            }
            resultJSON = json
            resultSignature = inputSignature
            resultOrigin = origin
            resultNodes = generated.nodeCount ?? 0
            exportURL = try makeExportFile(json: json)
        } catch {
            alert = AlertState(title: "Локальный генератор",
                               message: error.localizedDescription)
        }
    }

    private func makeExportFile(json: String) throws -> URL {
        let filename = "sing-box-local-\(variant)-\(platform).json"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try json.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func createProfile() async {
        guard !isCreating, isCurrentResult, platform == "ios" else { return }
        let name = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            alert = AlertState(title: "Создать профиль", message: "Укажите название профиля.")
            return
        }
        isCreating = true
        defer { isCreating = false }
        do {
            let json = resultJSON
            // Same semantic validation as in NewProfileViewModel.
            try await BlockingIO.run {
                var error: NSError?
                LibboxCheckConfig(json, &error)
                if let error { throw error }
            }
            let id = try await ProfileManager.nextID()
            let uniqueName = try await ProfileManager.uniqueName(name)
            let relativePath = "configs/config_\(id).json"
            let directory = FilePath.sharedDirectory.appendingPathComponent(
                "configs", isDirectory: true
            )
            let configFile = directory.appendingPathComponent("config_\(id).json")
            try await BlockingIO.run {
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true
                )
                try json.write(to: configFile, atomically: true, encoding: .utf8)
            }
            do {
                let profile = Profile(
                    name: uniqueName, type: .local, path: relativePath,
                    autoUpdate: false
                )
                try await ProfileManager.create(profile)
            } catch {
                try? FileManager.default.removeItem(at: configFile)
                throw error
            }
            environments.profileUpdate.send()
            alert = AlertState(
                title: "Профиль создан",
                message: "«\(uniqueName)» добавлен в список. Текущий профиль и работающий VPN не изменены."
            )
        } catch {
            alert = AlertState(title: "Создать профиль",
                               message: error.localizedDescription)
        }
    }
}
#else
import SwiftUI

public struct LocalGeneratorView: View {
    public init() {}
    public var body: some View {
        Text("Локальный генератор доступен в iOS-приложении.")
    }
}
#endif
