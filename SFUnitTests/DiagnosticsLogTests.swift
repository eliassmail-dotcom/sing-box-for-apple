import XCTest

@testable import Library

/// DiagnosticsLog behavior agreed in peer review: event-based recording,
/// append-only bounded JSONL storage, best-effort semantics (record never
/// throws), and the cross-process shared-container probe.
final class DiagnosticsLogTests: XCTestCase {
    override func setUp() {
        super.setUp()
        DiagnosticsLog.configureSharedDirectory(nil)
    }

    override func tearDown() {
        DiagnosticsLog.flushForTests()
        DiagnosticsLog.configureSharedDirectory(nil)
        DiagnosticsLog.configureLocalDirectoryForTests(nil)
        super.tearDown()
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("diagnostics-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testRecordedEventsArePersistedAndCollected() {
        let dir = temporaryDirectory()
        DiagnosticsLog.configureLocalDirectoryForTests(dir)

        DiagnosticsLog.record("unit.a", result: .pass, details: "first")
        DiagnosticsLog.record("unit.b", result: .fail, errorDomain: "TestDomain", errorCode: 42)
        DiagnosticsLog.flushForTests()

        let events = DiagnosticsLog.collectEvents()
        let stages = events.map(\.stage)
        XCTAssertTrue(stages.contains("unit.a"))
        XCTAssertTrue(stages.contains("unit.b"))

        let failed = events.first(where: { $0.stage == "unit.b" })
        XCTAssertEqual(failed?.result, "FAIL")
        XCTAssertEqual(failed?.errorDomain, "TestDomain")
        XCTAssertEqual(failed?.errorCode, 42)

        // Every event belongs to the same launch session and carries an id.
        XCTAssertEqual(Set(events.map(\.session)).count, 1)
        XCTAssertEqual(Set(events.map(\.id)).count, events.count)
    }

    func testExportReportRendersUnknownSectionsForMissingProcesses() {
        let dir = temporaryDirectory()
        DiagnosticsLog.configureLocalDirectoryForTests(dir)
        DiagnosticsLog.record("unit.export", result: .pass)
        DiagnosticsLog.flushForTests()

        let report = DiagnosticsLog.exportReport(header: ["signing: unit-test"])
        XCTAssertTrue(report.contains("unit.export"))
        XCTAssertTrue(report.contains("UNKNOWN: no TUNNEL"))
        XCTAssertTrue(report.contains("UNKNOWN: no FILEPROVIDER"))
        XCTAssertFalse(report.contains("UNKNOWN: no APP"))
    }

    func testRecordToleratesUnusableLocalDirectory() {
        // A regular file where a directory is expected must not crash or throw.
        let blocker = FileManager.default.temporaryDirectory
            .appendingPathComponent("diagnostics-blocker-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: blocker.path, contents: Data([1]))
        DiagnosticsLog.configureLocalDirectoryForTests(blocker)

        DiagnosticsLog.record("unit.unwritable", result: .pass, details: "still fine")
        DiagnosticsLog.flushForTests() // must not throw

        XCTAssertEqual(DiagnosticsLog.collectEvents().filter { $0.stage == "unit.unwritable" }.count, 0)
    }

    func testSanitizeEnforcesDetailsBudget() {
        XCTAssertNil(DiagnosticsLog.sanitize(nil))
        XCTAssertNil(DiagnosticsLog.sanitize(""))
        XCTAssertEqual(DiagnosticsLog.sanitize("group.a group.b"), "group.a group.b")

        let long = String(repeating: "x", count: 5000)
        let sanitized = DiagnosticsLog.sanitize(long)
        XCTAssertLessThanOrEqual(sanitized?.count ?? 0, 1024)
        XCTAssertTrue(sanitized?.hasSuffix("...") ?? false)
    }

    func testProbeMarkerPassesWhenFresh() {
        let shared = temporaryDirectory()
        DiagnosticsLog.configureSharedDirectory(shared)
        DiagnosticsLog.writeProbeMarker()

        DiagnosticsLog.checkSharedContainerProbe(expectedSession: nil)
        DiagnosticsLog.flushForTests()

        let probe = DiagnosticsLog.collectEvents().first(where: { $0.stage == "appgroup.probe" })
        XCTAssertEqual(probe?.result, "PASS")
    }

    func testStaleProbeMarkerIsUnknownNotPass() {
        let shared = temporaryDirectory()
        DiagnosticsLog.configureSharedDirectory(shared)

        // Hand-craft a marker older than the freshness threshold.
        let probeDir = shared.appendingPathComponent("Probes", isDirectory: true)
        try? FileManager.default.createDirectory(at: probeDir, withIntermediateDirectories: true)
        let stale = """
            {"appSessionID":"old-session","probeID":"old-probe","createdAt":\(Date().timeIntervalSince1970 - 48 * 3600)}
            """
        try? Data(stale.utf8).write(to: probeDir.appendingPathComponent("probe-old.json"))

        DiagnosticsLog.checkSharedContainerProbe(expectedSession: nil)
        DiagnosticsLog.flushForTests()

        let probe = DiagnosticsLog.collectEvents().first(where: { $0.stage == "appgroup.probe" })
        XCTAssertEqual(probe?.result, "UNKNOWN")
    }

    func testMissingProbeDirectoryIsUnknown() {
        let shared = temporaryDirectory()
        DiagnosticsLog.configureSharedDirectory(shared)

        DiagnosticsLog.checkSharedContainerProbe(expectedSession: nil)
        DiagnosticsLog.flushForTests()

        let probe = DiagnosticsLog.collectEvents().first(where: { $0.stage == "appgroup.probe" })
        XCTAssertEqual(probe?.result, "UNKNOWN")
    }

    func testStorageStaysBoundedUnderManyEvents() {
        let dir = temporaryDirectory()
        DiagnosticsLog.configureLocalDirectoryForTests(dir)

        // Far more events than fit into the 256 KiB budget; interleaved
        // flushes keep the pending queue below its drop threshold.
        for index in 0..<600 {
            DiagnosticsLog.record("unit.flood", result: .pass, details: "payload \(index) " + String(repeating: "p", count: 64))
            if index.isMultiple(of: 16) {
                DiagnosticsLog.flushForTests()
            }
        }
        DiagnosticsLog.flushForTests()

        let file = dir.appendingPathComponent("diagnostics-APP.jsonl")
        let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        XCTAssertLessThanOrEqual(size, 260_000)
    }

    func testExportWritesReportFileIntoDocuments() {
        let report = DiagnosticsLog.exportReport(header: ["signing: unit-test"])
        XCTAssertFalse(report.isEmpty)
        // writeReportToDocuments writes into the real Documents directory of
        // the test host; verify via a header-only report round trip.
        if let url = DiagnosticsLog.writeReportToDocuments(header: ["signing: unit-test"]) {
            defer { try? FileManager.default.removeItem(at: url) }
            let written = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            XCTAssertTrue(written.contains("unit.export") || written.contains("# Diagnostics report"))
        } else {
            XCTFail("report write to Documents failed")
        }
    }
}
