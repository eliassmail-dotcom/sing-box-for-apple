import Library
import SwiftUI

#if os(iOS)
    import UIKit
#endif

/// One Settings row: writes the merged diagnostics report (own process +
/// everything readable from the shared container) into Documents and offers
/// the system share sheet. Available even when VPN or the File Provider are
/// broken: the report renders UNKNOWN sections instead of failing.
public struct DiagnosticsExportButton: View {
    private struct ShareItem: Identifiable {
        let id = UUID().uuidString
        let url: URL
    }

    @State private var shareItem: ShareItem?
    @State private var failureText: String?

    public init() {}

    public var body: some View {
        Button {
            export()
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Диагностика VPN и подписи")
                    if let failureText {
                        Text(failureText)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            } icon: {
                Image(systemName: "wrench.and.screwdriver")
            }
        }
        #if os(iOS)
            .sheet(item: $shareItem) { item in
                ShareSheet(url: item.url)
            }
        #endif
    }

    private func export() {
        let header = [
            "version: \(Bundle.application.version) build \(Bundle.application.versionNumber)",
            "signing: \(AppConfiguration.signingDiagnostics)",
            "process: \(DiagnosticsLog.process.rawValue)",
        ]
        if let url = DiagnosticsLog.writeReportToDocuments(header: header + AppConfiguration.signingInventory) {
            DiagnosticsLog.record("diagnostics.export", result: .pass, details: "written to Documents")
            failureText = nil
            shareItem = ShareItem(url: url)
        } else {
            // The report text itself is still returned in the error path via
            // the log; a failed write is visible on the next export attempt.
            DiagnosticsLog.record("diagnostics.export", result: .fail,
                details: "Documents write failed in process \(DiagnosticsLog.process.rawValue)")
            failureText = String(localized: "Не удалось записать отчёт в Documents")
        }
    }
}

#if os(iOS)
    private struct ShareSheet: UIViewControllerRepresentable {
        let url: URL

        func makeUIViewController(context: Context) -> UIActivityViewController {
            UIActivityViewController(activityItems: [url], applicationActivities: nil)
        }

        func updateUIViewController(_: UIActivityViewController, context _: Context) {}
    }
#endif
