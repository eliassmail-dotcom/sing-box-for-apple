import AppIntents
import SwiftUI
import WidgetKit

/// A stateless Control Center action. The active VPN's Strategy selector stays
/// unchanged; the packet tunnel rotates the selected leaf within that mode.
struct NextNodeControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(
            kind: "sing-box.lx.control.NextNode.v2"
        ) {
            ControlWidgetButton(action: NextNodeControlIntent()) {
                Label("Сменить узел", systemImage: "arrow.clockwise")
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
        WidgetTunnelControl.configureDiagnostics()
        DiagnosticsLog.record("widget.node.entered", result: .unknown)
        do {
            try await WidgetTunnelControl.changeNode()
            DiagnosticsLog.record("widget.node.command", result: .pass)
        } catch {
            let nsError = error as NSError
            DiagnosticsLog.record("widget.node.command", result: .fail,
                errorDomain: nsError.domain, errorCode: nsError.code)
            throw error
        }
        return .result()
    }
}
