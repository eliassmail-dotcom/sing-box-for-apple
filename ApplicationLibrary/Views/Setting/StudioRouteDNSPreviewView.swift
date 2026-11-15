#if os(iOS)
import Foundation
import SwiftUI

/// An isolated preview of the DNS-follow-route behavior planned for the
/// writable policy editor. Changing any value here never touches live VPN.
struct StudioRouteDNSPreviewView: View {
    let model: StudioSemanticModel
    let addressTitle: String
    let currentRoute: String?
    let currentDNS: String?
    let dnsHasExplicitOverride: Bool

    @State private var route: String = ""
    @State private var associations: [String: String] = [:]
    @State private var policy: String = "auto"
    @State private var explicitDNS: String = ""

    private var routes: [String] {
        let names = model.document.array("outbounds").compactMap { $0["tag"] as? String }
        return Array(Set(names + ["direct"])).sorted()
    }

    private var dnsTags: [String] {
        Array(Set(model.dnsServers.map(\.name))).sorted()
    }

    private var choice: StudioDNSFollowRoute.DNSChoice {
        switch policy {
        case "inherit": return .inherit
        case "explicit": return .explicit(explicitDNS)
        default: return .automatic
        }
    }

    private var resolved: StudioDNSFollowRoute.Assignment {
        StudioDNSFollowRoute.resolve(route: route, choice: choice,
                                     association: associations,
                                     defaultDNS: model.defaultDNS)
    }

    var body: some View {
        Form {
            Section("Текущее состояние · \(addressTitle)") {
                field("Маршрут", value: currentRoute ?? model.defaultRoute ?? "Не определён")
                field("DNS", value: currentDNS ?? "Нет точного совпадения DNS-условий")
                if dnsHasExplicitOverride {
                    Label("Для этой группы выявлена отдельная DNS-политика",
                          systemImage: "lock.shield")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section {
                Label("Ниже только предпросмотр будущего редактора. Никакие настройки VPN не сохраняются.",
                      systemImage: "eye")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Маршрут") {
                Picker("Направлять через", selection: $route) {
                    ForEach(routes, id: \.self) { value in
                        Text(value).tag(value)
                    }
                }
            }
            Section("DNS-поведение") {
                Picker("Режим DNS", selection: $policy) {
                    Text("Следовать маршруту").tag("auto")
                    Text("Наследовать общий").tag("inherit")
                    Text("Выбрать отдельно").tag("explicit")
                }
                if policy == "auto" && !route.isEmpty {
                    Picker("DNS для \(route)", selection: Binding(
                        get: { associations[route] ?? "" },
                        set: { newValue in
                            if newValue.isEmpty { associations.removeValue(forKey: route) }
                            else { associations[route] = newValue }
                        }
                    )) {
                        Text("Нет привязки").tag("")
                        ForEach(dnsTags, id: \.self) { value in
                            Text(value).tag(value)
                        }
                    }
                } else if policy == "explicit" {
                    Picker("Выбранный DNS", selection: $explicitDNS) {
                        ForEach(dnsTags, id: \.self) { value in Text(value).tag(value) }
                    }
                }
            }
            Section("Результат моделирования") {
                field("Маршрут", value: route)
                field("DNS", value: resolved.dns ?? "Не определён")
                if resolved.source == .unmapped {
                    Label("Для этого выхода нет привязки DNS. Показан только DNS по умолчанию.",
                          systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Маршрут и DNS")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if route.isEmpty { route = currentRoute ?? model.defaultRoute ?? routes.first ?? "" }
            if let currentDNS, !currentDNS.isEmpty {
                explicitDNS = currentDNS
                if let currentRoute { associations[currentRoute] = currentDNS }
            } else {
                explicitDNS = model.defaultDNS ?? dnsTags.first ?? ""
            }
            if dnsHasExplicitOverride { policy = "explicit" }
        }
    }

    private func field(_ name: String, value: String) -> some View {
        HStack(spacing: 12) {
            Text(name)
            Spacer(minLength: 10)
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }
}
#endif
