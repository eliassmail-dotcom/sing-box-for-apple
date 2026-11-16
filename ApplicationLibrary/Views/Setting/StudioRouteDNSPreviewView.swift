#if os(iOS)
import Foundation
import SwiftUI

/// Local-only preview of route → DNS profile inheritance. This is a proposed
/// policy model, not a change to DNS rules or the running VPN.
struct StudioRouteDNSPreviewView: View {
    let model: StudioSemanticModel
    let addressTitle: String
    let currentRoute: String?
    let currentDNS: String?
    let dnsHasExplicitOverride: Bool

    @State private var route = ""
    @State private var dnsChoice = "auto"

    private var routes: [String] {
        let names = model.document.array("outbounds").compactMap { $0["tag"] as? String }
        return Array(Set(names + ["direct"])).sorted()
    }
    private var profiles: [StudioDNSExplanation.Profile] {
        StudioDNSExplanation.profiles(document: model.document)
    }
    private var proposedFamily: StudioDNSExplanation.Family? {
        switch dnsChoice {
        case "direct": return .direct
        case "proxy": return .proxy
        case "inherit": return nil
        default:
            return StudioDNSExplanation.suggestedFamily(
                forRoute: route, document: model.document)
        }
    }
    private var selectedProfile: StudioDNSExplanation.Profile? {
        guard let proposedFamily else { return nil }
        return profiles.first { $0.family == proposedFamily }
    }

    var body: some View {
        Form {
            Section("Найдено в конфигурации · \(addressTitle)") {
                field("Маршрут в правилах", value: currentRoute ?? "Не установлен однозначно")
                field("DNS-сервер в правилах", value: currentDNS ?? "Не установлен однозначно")
                if dnsHasExplicitOverride {
                    Label("Есть отдельное DNS-правило: будущий автоподбор не должен его затирать",
                          systemImage: "lock.shield")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section {
                Text("Ниже — пример будущей логики. Ничего не сохраняется, и на действующий DNS это не влияет.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Направление трафика") {
                Picker("Маршрут", selection: $route) {
                    ForEach(routes, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
            }
            Section("DNS-профиль для этого маршрута") {
                Picker("Выбор профиля", selection: $dnsChoice) {
                    Text("Автоматически по маршруту").tag("auto")
                    Text("Общий DNS при отсутствии правила").tag("inherit")
                    Text("Direct DNS").tag("direct")
                    Text("Proxy DNS").tag("proxy")
                }
                if let profile = selectedProfile {
                    field("Предлагаемый профиль", value: profile.title)
                    if profile.bindings.isEmpty {
                        Text("Для этого профиля нет однозначно обнаруженных DNS-серверов. Нельзя автоматически сформировать рабочую схему.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        field("DNS-серверы", value: profile.bindings.map(\.name).joined(separator: ", "))
                    }
                } else {
                    field("Общий DNS-сервер", value: model.defaultDNS ?? "Не указан")
                    if dnsChoice == "auto" {
                        Text("Маршрут не позволяет достоверно определить тип DNS-профиля.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            Section("Обработка DNS") {
                NavigationLink {
                    StudioDNSRuleFlowView(model: model, filteredIndexes: nil)
                } label: {
                    Label("Посмотреть действующую схему RACE, проверок и ответов",
                          systemImage: "arrow.triangle.branch")
                }
                Text("Профиль — будущая единица настроек. Сегодня RACE/Evaluate/Respond заданы общей последовательностью DNS-правил; приложение не приписывает эти действия выдуманному профилю.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Маршрут и DNS")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if route.isEmpty {
                route = currentRoute ?? model.defaultRoute ?? routes.first ?? ""
            }
        }
    }

    private func field(_ name: String, value: String) -> some View {
        HStack(spacing: 12) {
            Text(name).font(.subheadline)
            Spacer(minLength: 10)
            Text(value).font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}
#endif
