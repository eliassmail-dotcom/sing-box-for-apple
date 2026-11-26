import Foundation
import os

/// Event-based runtime diagnostics for the signing, first-VPN-start and
/// File Provider investigation (b42).
///
/// Constraints agreed in peer review:
/// - event-driven only: no background monitoring, no timers, no network requests;
/// - never throws and never blocks the Network Extension critical path;
/// - never relies on the shared App Group: every event is mirrored to os_log
///   and to a process-local file; the shared-container copy is best-effort and
///   is configured only from points where the host code already resolves its
///   container, so diagnostics cannot change initialization order;
/// - bounded storage: append-only JSONL, at most 256 KiB per file with a
///   single rotation; a bounded in-memory queue drops overflow instead of
///   blocking, and records the loss count;
/// - `details` carries only non-sensitive identifiers, counters and
///   NSError domain/code values - never URLs, secrets or profile content.
public enum DiagnosticsLog {

    // MARK: - Types

    public enum Process: String {
        case app = "APP"
        case tunnel = "TUNNEL"
        case fileProvider = "FILEPROVIDER"
        case widget = "WIDGET"
    }

    public enum Result: String {
        case pass = "PASS"
        case fail = "FAIL"
        case unknown = "UNKNOWN"
    }

    struct Event: Codable {
        let id: String
        let ts: Int64
        let process: String
        let session: String
        let operation: String?
        let attempt: String?
        let stage: String
        let result: String
        let errorDomain: String?
        let errorCode: Int?
        let durationMs: Int?
        let details: String?
    }

    // MARK: - Constants

    private static let maxFileBytes = 256 * 1024
    private static let maxPendingEvents = 64
    private static let maxDetailsLength = 1024
    private static let probeRingSize = 3
    private static let probeMaxAge: TimeInterval = 24 * 3600

    // MARK: - State

    private static let lock = NSLock()
    private static let queue = DispatchQueue(label: "DiagnosticsLog", qos: .utility)
    private static let osLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "unknown", category: "Diagnostics"
    )

    private static var _session: String?
    private static var _process: Process?
    private static var _sharedDirectory: URL?
    private static var _localDirectory: URL?
    private static var pending = 0
    private static var droppedEvents = 0

    /// Process of the running executable. Detected once, never re-detected.
    public static var process: Process {
        lock.lock()
        if let cached = _process {
            lock.unlock()
            return cached
        }
        lock.unlock()
        let value = detectProcess()
        lock.lock()
        _process = value
        lock.unlock()
        return value
    }

    /// Session identifier of this process launch.
    public static var session: String {
        lock.lock()
        if let cached = _session {
            lock.unlock()
            return cached
        }
        lock.unlock()
        let value = UUID().uuidString
        lock.lock()
        if let cached = _session {
            lock.unlock()
            return cached
        }
        _session = value
        lock.unlock()
        return value
    }

    /// Best-effort shared-container directory for cross-process events and
    /// probes. Configured only from code paths that already resolved the
    /// container; nil keeps this process local-only. Never resolves the
    /// app group itself and never throws.
    public static func configureSharedDirectory(_ url: URL?) {
        lock.lock()
        _sharedDirectory = url
        lock.unlock()
    }

    /// Process-local directory for the diagnostics file. Overridable in tests.
    static func configureLocalDirectoryForTests(_ url: URL?) {
        lock.lock()
        _localDirectory = url
        lock.unlock()
    }

    /// Blocks until every event queued so far has been written (unit tests only).
    static func flushForTests() {
        queue.sync {}
    }

    // MARK: - Recording

    /// Records one diagnostic event. Non-throwing, non-blocking; a failed or
    /// unavailable store is silently tolerated.
    public static func record(
        _ stage: String,
        result: Result = .unknown,
        operation: String? = nil,
        attempt: String? = nil,
        errorDomain: String? = nil,
        errorCode: Int? = nil,
        durationMs: Int? = nil,
        details: String? = nil
    ) {
        let event = Event(
            id: UUID().uuidString,
            ts: Int64(Date().timeIntervalSince1970 * 1000),
            process: process.rawValue,
            session: session,
            operation: operation,
            attempt: attempt,
            stage: stage,
            result: result.rawValue,
            errorDomain: errorDomain,
            errorCode: errorCode,
            durationMs: durationMs,
            details: sanitize(details)
        )
        mirror(event)

        lock.lock()
        if pending >= maxPendingEvents {
            droppedEvents += 1
            lock.unlock()
            return
        }
        pending += 1
        lock.unlock()

        queue.async {
            defer {
                lock.lock()
                pending -= 1
                lock.unlock()
            }
            var followUp: Event?
            lock.lock()
            if droppedEvents > 0 {
                followUp = Event(
                    id: UUID().uuidString,
                    ts: event.ts,
                    process: event.process,
                    session: event.session,
                    operation: event.operation,
                    attempt: event.attempt,
                    stage: "diagnostics.dropped",
                    result: Result.unknown.rawValue,
                    errorDomain: nil,
                    errorCode: nil,
                    durationMs: nil,
                    details: "droppedEvents=\(droppedEvents)"
                )
                droppedEvents = 0
            }
            lock.unlock()
            append(event)
            if let followUp {
                mirror(followUp)
                append(followUp)
            }
        }
    }

    /// Best-effort: os_log always receives the event even when disk writes
    /// fail or the process is killed before the queued write completes.
    private static func mirror(_ event: Event) {
        osLogger.log("\(event.singleLine, privacy: .public)")
    }

    private static func append(_ event: Event) {
        let line: Data
        do {
            line = try JSONEncoder().encode(event)
        } catch {
            return
        }
        var data = line
        data.append(0x0A)
        let shared = lock.locked { _sharedDirectory }
        appendLine(data, directory: localDirectory())
        appendLine(data, directory: shared)
    }

    /// Appends one JSONL line to `<dir>/diagnostics-<process>.jsonl`,
    /// rotating at the size limit. FileHandle(forWritingTo:) only opens an
    /// EXISTING file, so the file is created on first use and after every
    /// rotation; if rotation fails the event is dropped rather than letting
    /// the file grow beyond the limit. All failures are silently tolerated.
    private static func appendLine(_ line: Data, directory: URL?) {
        guard let directory else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("diagnostics-\(process.rawValue).jsonl")
            let rotated = file.appendingPathExtension("1")
            let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
            let currentSize = (attributes?[.size] as? NSNumber)?.intValue ?? 0
            if currentSize + line.count > maxFileBytes {
                do {
                    try? FileManager.default.removeItem(at: rotated)
                    try FileManager.default.moveItem(at: file, to: rotated)
                } catch {
                    return // refuse to grow past the budget; drop this event
                }
            }
            if !FileManager.default.fileExists(atPath: file.path) {
                FileManager.default.createFile(atPath: file.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } catch {
            // Diagnostics must never impact the caller.
        }
    }

    private static func localDirectory() -> URL? {
        lock.lock()
        if let cached = _localDirectory {
            lock.unlock()
            return cached
        }
        lock.unlock()
        // FileManager.url(for:create:) is throwing; the plural variant is not.
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        lock.lock()
        _localDirectory = url
        lock.unlock()
        return url
    }

    // MARK: - Export

    /// Reads the events this process can see: its local file plus every
    /// shared diagnostics file, deduplicated by event id and sorted by time.
    /// Invalid or truncated trailing lines are skipped, not fatal.
    static func collectEvents() -> [Event] {
        var byId: [String: Event] = [:]
        for event in readEvents(from: localDirectory(), allProcesses: true) {
            byId[event.id] = event
        }
        let shared = lock.locked { _sharedDirectory }
        for event in readEvents(from: shared, allProcesses: true) {
            byId[event.id] = event
        }
        return byId.values.sorted { $0.ts < $1.ts }
    }

    /// Human-readable report: header lines, the merged timeline and the
    /// dropped-event counter. Available even when the VPN or File Provider
    /// are broken; unreadable sections are reported as UNKNOWN.
    public static func exportReport(header: [String]) -> String {
        var lines: [String] = ["# Diagnostics report"]
        lines.append("generated: \(Int(Date().timeIntervalSince1970 * 1000))")
        for entry in header {
            lines.append(entry)
        }
        lock.lock()
        let dropped = droppedEvents
        lock.unlock()
        lines.append("droppedEvents: \(dropped)")

        let events = collectEvents()
        let seen = Set(events.map(\.process))
        for expected in ["APP", "TUNNEL", "FILEPROVIDER"] where !seen.contains(expected) {
            lines.append("UNKNOWN: no \(expected) events - extension diagnostics inaccessible")
        }
        // WIDGET events only exist when a Control Center control was actually
        // used; report their absence without implying broken access.
        if !seen.contains("WIDGET") {
            lines.append("UNKNOWN: no WIDGET events - Control Center controls not used since last rotation")
        }
        lines.append("--- events (\(events.count)) ---")
        for event in events {
            lines.append(event.singleLine)
        }
        return lines.joined(separator: "\n")
    }

    /// Writes the report into the app's Documents directory (visible in the
    /// Files app when UIFileSharingEnabled is set), so it can be extracted
    /// even when the share sheet is unavailable. Returns nil on failure.
    public static func writeReportToDocuments(header: [String]) -> URL? {
        let text = exportReport(header: header)
        guard let data = text.data(using: .utf8) else { return nil }
        do {
            let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let name = "diagnostics-report-\(Int(Date().timeIntervalSince1970 * 1000)).txt"
            let url = dir.appendingPathComponent(name)
            try data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.creationDate: Date()], ofItemAtPath: url.path)
            return url
        } catch {
            return nil
        }
    }

    /// Reads the diagnostics files of `directory`: the active JSONL files and
    /// their single rotation (.jsonl.1). Invalid or truncated trailing lines
    /// are skipped, not fatal.
    private static func readEvents(from directory: URL?, allProcesses: Bool) -> [Event] {
        guard let directory else { return [] }
        var events: [Event] = []
        let names: [String]
        if allProcesses {
            names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        } else {
            names = ["diagnostics-\(process.rawValue).jsonl"]
        }
        for name in names {
            let isActive = name.hasPrefix("diagnostics-") && name.hasSuffix(".jsonl")
            let isRotated = name.hasPrefix("diagnostics-") && name.hasSuffix(".jsonl.1")
            guard isActive || isRotated else { continue }
            for line in (try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8))?
                .split(separator: "\n") ?? [] {
                if let data = String(line).data(using: .utf8),
                   let event = try? JSONDecoder().decode(Event.self, from: data) {
                    events.append(event)
                }
            }
        }
        return events
    }

    // MARK: - Shared container probe

    /// The app writes a marker identifying its launch session into the shared
    /// container (best effort, ring of the newest 3, no timers). Asynchronous:
    /// never performs file IO on the caller's thread (didFinishLaunching).
    public static func writeProbeMarker() {
        queue.async {
            writeProbeMarkerNow()
        }
    }

    private static func writeProbeMarkerNow() {
        let shared = lock.locked { _sharedDirectory }
        guard let shared else { return }
        let marker = ProbeMarker(appSessionID: session, probeID: UUID().uuidString, createdAt: Date().timeIntervalSince1970)
        guard let data = try? JSONEncoder().encode(marker) else { return }
        do {
            let dir = shared.appendingPathComponent("Probes", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: dir.appendingPathComponent("probe-\(marker.probeID).json"), options: .atomic)
            pruneProbes(in: dir)
        } catch {
            // The probe is best-effort; failures surface via checkProbe.
        }
    }

    /// A non-app process verifies that the app container is shared. Asynchronous:
    /// directory reads must not sit on the tunnel's startup critical path.
    public static func checkSharedContainerProbe(expectedSession: String?) {
        queue.async {
            checkSharedContainerProbeNow(expectedSession: expectedSession)
        }
    }

    /// Runs on the diagnostics queue. When the caller knows the expected app
    /// session (app-initiated start), a marker from ANY other session is
    /// UNKNOWN regardless of freshness: it does not prove a link to the
    /// current session. Freshness alone proves only historical availability
    /// and is a PASS exclusively for external starts (Control Center / On
    /// Demand), where no app session is expected. A confirmed read error is
    /// FAIL; a missing directory or stale marker is UNKNOWN.
    private static func checkSharedContainerProbeNow(expectedSession: String?) {
        let shared = lock.locked { _sharedDirectory }
        guard let shared else {
            record("appgroup.probe", result: .unknown, details: "no shared container in this process")
            return
        }
        let dir = shared.appendingPathComponent("Probes", isDirectory: true)
        guard FileManager.default.fileExists(atPath: dir.path) else {
            record("appgroup.probe", result: .unknown, details: "probe directory absent")
            return
        }
        let markers: [ProbeMarker]
        do {
            markers = try readProbes(in: dir)
        } catch {
            record("appgroup.probe", result: .fail, errorDomain: (error as NSError).domain,
                   errorCode: (error as NSError).code, details: "probe read failed")
            return
        }
        guard let newest = markers.max(by: { $0.createdAt < $1.createdAt }) else {
            record("appgroup.probe", result: .unknown, details: "no probe markers found")
            return
        }
        let ageSeconds = Int(Date().timeIntervalSince1970 - newest.createdAt)
        if let expectedSession {
            if newest.appSessionID == expectedSession {
                record("appgroup.probe", result: .pass, details: "expected app session, age \(ageSeconds)s")
            } else {
                record("appgroup.probe", result: .unknown,
                       details: "marker from another app session, age \(ageSeconds)s")
            }
        } else if ageSeconds < Int(probeMaxAge) {
            record("appgroup.probe", result: .pass, details: "fresh marker (external start), age \(ageSeconds)s")
        } else {
            record("appgroup.probe", result: .unknown, details: "stale marker, age \(ageSeconds)s")
        }
    }

    private struct ProbeMarker: Codable {
        let appSessionID: String
        let probeID: String
        let createdAt: TimeInterval
    }

    private static func readProbes(in dir: URL) throws -> [ProbeMarker] {
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        var markers: [ProbeMarker] = []
        for name in names where name.hasPrefix("probe-") {
            if let data = try? FileManager.default.contents(atPath: dir.appendingPathComponent(name).path),
               let marker = try? JSONDecoder().decode(ProbeMarker.self, from: data) {
                markers.append(marker)
            }
        }
        return markers
    }

    private static func pruneProbes(in dir: URL) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        var candidates: [(URL, Date)] = []
        for name in names where name.hasPrefix("probe-") {
            let url = dir.appendingPathComponent(name)
            if let date = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date {
                candidates.append((url, date))
            }
        }
        let cutoff = Date().addingTimeInterval(-probeMaxAge)
        for (url, date) in candidates where date < cutoff {
            try? FileManager.default.removeItem(at: url)
        }
        for (url, _) in candidates
            .filter({ $0.1 >= cutoff })
            .sorted(by: { $0.1 < $1.1 })
            .dropLast(probeRingSize) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Helpers

    private static func detectProcess() -> Process {
        let bundleID = (Bundle.main.bundleIdentifier ?? "").lowercased()
        if bundleID.contains("fileprovider") {
            return .fileProvider
        }
        if bundleID.contains("widget") {
            return .widget
        }
        if Bundle.main.object(forInfoDictionaryKey: "NSExtension") != nil {
            return .tunnel
        }
        return .app
    }

    /// Details are non-sensitive by construction at the call sites; the
    /// sanitizer enforces the length budget defensively.
    static func sanitize(_ details: String?) -> String? {
        guard var value = details, !value.isEmpty else { return nil }
        if value.count > maxDetailsLength {
            value = String(value.prefix(maxDetailsLength - 3)) + "..."
        }
        return value
    }
}

private extension DiagnosticsLog.Event {
    var singleLine: String {
        var parts = ["ts=\(ts)", "p=\(process)", "s=\(session)"]
        if let operation { parts.append("op=\(operation)") }
        if let attempt { parts.append("at=\(attempt)") }
        parts.append("stage=\(stage)")
        parts.append("r=\(result)")
        if let errorDomain { parts.append("err=\(errorDomain)/\(errorCode ?? -1)") }
        if let durationMs { parts.append("ms=\(durationMs)") }
        if let details { parts.append(details) }
        return parts.joined(separator: " ")
    }
}

private extension NSLock {
    func locked<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
