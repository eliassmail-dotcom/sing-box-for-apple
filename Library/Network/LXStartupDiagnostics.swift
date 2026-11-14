import Foundation

/// Lightweight, privacy-preserving breadcrumbs shared by the app and the
/// Packet Tunnel extension. The records deliberately contain no profile JSON,
/// server addresses, credentials or subscription URLs.
public enum LXStartupDiagnostics {
    public struct Event: Codable {
        public let attempt: String
        public let timestamp: Date
        public let stage: String
    }

    private static let filename = "lx-startup-stages.json"
    private static let processLock = NSLock()
    private static let maxEvents = 40

    private static var fileURL: URL {
        FilePath.sharedDirectory.appendingPathComponent(filename)
    }

    public static func record(_ stage: String, attempt: String) {
        guard !attempt.isEmpty, !stage.isEmpty else { return }
        processLock.lock()
        defer { processLock.unlock() }

        var events = readAll()
        events.append(Event(attempt: attempt, timestamp: Date(), stage: stage))
        if events.count > maxEvents {
            events.removeFirst(events.count - maxEvents)
        }
        guard let data = try? JSONEncoder().encode(events) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    public static func latestStages(attempt: String?) -> String? {
        guard let attempt, !attempt.isEmpty else { return nil }
        processLock.lock()
        defer { processLock.unlock() }
        let stages = readAll().filter { $0.attempt == attempt }.suffix(12)
        guard !stages.isEmpty else { return nil }
        return stages.map { $0.stage }.joined(separator: " → ")
    }

    private static func readAll() -> [Event] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([Event].self, from: data)) ?? []
    }
}
