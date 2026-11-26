import AppIntents
import SwiftUI
import WidgetKit

/// A stateless Control Center action. The active VPN's Strategy selector stays
/// unchanged; the packet tunnel rotates the selected leaf within that mode.
struct NextNodeControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(
            kind: "sing-box.lx.control.NextNode.v2",
            provider: NextNodeValueProvider()
        ) { _ in
            ControlWidgetButton(action: NextNodeControlIntent()) {
                Label("Сменить узел", systemImage: "arrow.clockwise")
            }
        }
        .displayName("Сменить узел")
        .description("Переключить сервер внутри активного режима VPN.")
    }
}

// Keep the action stateless and the existing control identity. The explicit
// Bool payload avoids the provider-less (Void) configuration path that trapped
// inside WidgetKit on iOS 27.2.1. Do not load VPN preferences to render a
// button; the intent still validates the connected session when invoked.
struct NextNodeValueProvider: ControlValueProvider {
    var previewValue: Bool { true }

    func currentValue() async throws -> Bool {
        WidgetTunnelControl.configureDiagnostics()
        DiagnosticsLog.record("widget.node.value", result: .pass, details: "explicit Bool provider")
        return true
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
