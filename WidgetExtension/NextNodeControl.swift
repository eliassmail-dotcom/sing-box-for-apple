import AppIntents
import SwiftUI
import WidgetKit

/// A stateless Control Center action. The active VPN's Strategy selector stays
/// unchanged; the packet tunnel rotates the selected leaf within that mode.
struct NextNodeControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(
            kind: WidgetAppConfiguration.widgetNextNodeKind
        ) {
            ControlWidgetButton(action: NextNodeControlIntent()) {
                Label("Сменить узел", systemImage: "arrow.triangle.2.circlepath")
                    .controlWidgetActionHint("Сменить узел")
            }
        }
        .displayName("Сменить узел")
        .description("Переключить сервер внутри активного режима VPN.")
    }
}

struct NextNodeControlIntent: AppIntent {
    static var title: LocalizedStringResource = "Сменить узел"
    static var description = IntentDescription(
        "Переключает сервер внутри активного режима sing-box lx++ без остановки VPN."
    )

    func perform() async throws -> some IntentResult {
        try await WidgetTunnelControl.changeNode()
        return .result()
    }
}
