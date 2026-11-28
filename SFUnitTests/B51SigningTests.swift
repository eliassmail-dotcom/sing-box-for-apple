import Foundation
import NetworkExtension
import SQLite3
import XCTest
@testable import Library

final class B51SigningTests: XCTestCase {
    private func members(groups: [String], declared: String, document: String? = nil) -> [SharedGroupContract.Member] {
        SharedGroupContract.Role.allCases.map {
            SharedGroupContract.Member(role: $0, bundleID: $0.rawValue, declared: declared,
                                       documentGroup: $0 == .files ? (document ?? declared) : nil,
                                       groups: Set(groups), source: "fixture")
        }
    }

    func testOriginalAndMappedMultiGroupSigning() {
        let groups = ["group.other", "group.intended", "group.third"]
        XCTAssertEqual(SharedGroupContract.decide(members(groups: groups, declared: "group.intended")).group, "group.intended")
        let mapped = members(groups: groups, declared: "group.old", document: "group.third")
        XCTAssertEqual(SharedGroupContract.decide(Array(mapped.reversed())).group, "group.third")
    }

    func testOneCommonGroupEvenWithStalePlistButFilesRequireExactDocumentGroup() {
        let single = members(groups: ["group.only"], declared: "group.old")
        let decision = SharedGroupContract.decide(single)
        XCTAssertEqual(decision.group, "group.only")
        XCTAssertNotEqual(decision.group, single.first { $0.role == .files }?.documentGroup)
    }

    func testFiveRenamedRightsHaveNoSemanticSuffixOrOrdering() {
        let groups = (1...5).map { "group.foreign.\($0)" }
        for names in [groups, Array(groups.reversed())] {
            let decision = SharedGroupContract.decide(members(groups: names, declared: "group.original.2"))
            XCTAssertNil(decision.group)
            XCTAssertEqual(decision.reason, "ambiguousNoMapping")
        }
    }

    func testConflictingAuthorizedDeclarationsFail() {
        let m = members(groups: ["group.host", "group.files"], declared: "group.host", document: "group.files")
        XCTAssertEqual(SharedGroupContract.decide(m).reason, "conflictingDeclarations")
    }

    func testEveryEmbeddedTargetIsRequiredAndConstrainsTheIntersection() {
        let original = members(groups: ["group.x"], declared: "group.x")
        for role in SharedGroupContract.Role.allCases {
            let rest = original.filter { $0.role != role }
            XCTAssertNil(SharedGroupContract.decide(rest).group)
            XCTAssertNil(SharedGroupContract.decide(original + [original.first { $0.role == role }!]).group)
            for rights in [Set<String>(), Set(["group.different"])] {
                let bad = SharedGroupContract.Member(role: role, bundleID: "test", declared: "group.x",
                                                      documentGroup: nil, groups: rights, source: "fixture")
                XCTAssertNil(SharedGroupContract.decide(rest + [bad]).group)
            }
        }
    }

    func testSignedGroupDoesNotImplyLiveContainer() {
        let decision = SharedGroupContract.decide(members(groups: ["group.ok"], declared: "group.ok"))
        XCTAssertNil(SharedGroupContract.open(decision) { _ in nil })
        let url = URL(fileURLWithPath: "/test")
        XCTAssertEqual(SharedGroupContract.open(decision) { $0 == "group.ok" ? url : nil }, url)
        let ambiguous = SharedGroupContract.decide(members(groups: ["group.a", "group.b"], declared: "group.stale"))
        XCTAssertNil(SharedGroupContract.open(ambiguous) { _ in XCTFail("No arbitrary probe"); return url })
    }

    func testTwoObserversOnlyOneProviderMayClaimAnAttempt() {
        let reply = VPNStartReceipt(operation: "op2", attempt: "try2", group: "fixture", stages: [])
        XCTAssertFalse(reply.matches(operation: "op1", issued: "try1"))
        XCTAssertFalse(reply.matches(operation: "op2", issued: "try1"))
        XCTAssertTrue(reply.matches(operation: "op2", issued: "try2"))
        XCTAssertFalse(VPNStartReceipt(operation: nil, attempt: "widget", group: "", stages: []).matches(operation: "op1", issued: "try1"))
    }

    func testReportDistinguishesCurrentProcessAndIPCFromHistoricalEvents() {
        func event(_ role: String, _ build: String?, _ stage: String, _ details: String) -> DiagnosticsLog.Event {
            DiagnosticsLog.Event(id: UUID().uuidString, ts: 1, process: role, session: "unit", build: build,
                                 operation: nil, attempt: nil, stage: stage, result: "PASS", errorDomain: nil,
                                 errorCode: nil, durationMs: nil, details: details)
        }
        let observations = DiagnosticsLog.groupObservations(in: [
            event("FILEPROVIDER", nil, "appgroup.access", "reason=legacy"),
            event("WIDGET", "50", "appgroup.access", "reason=legacy"),
            event("APP", "51", "appgroup.access", "selected=group.x reason=authorizedDeclaration"),
            event("APP", "51", "vpn.start.attribution", "providerOperation=unit selected=group.x reason=authorizedDeclaration")
        ], build: "51")
        XCTAssertEqual(observations.count, 7)
        XCTAssertTrue(observations.contains { $0.contains("role=APP build=51 source=process") })
        XCTAssertTrue(observations.contains { $0.contains("role=TUNNEL build=51 source=providerMessage") })
        XCTAssertTrue(observations.contains("observed role=FILEPROVIDER build=51 unobserved"))
        XCTAssertTrue(observations.contains("observed role=WIDGET build=51 unobserved"))
    }

    @MainActor
    func testInstallAndColdStartFindOnlyOwnedManager() throws {
        func manager(_ provider: String, enabled: Bool = true) -> NETunnelProviderManager {
            let manager = NETunnelProviderManager()
            let proto = NETunnelProviderProtocol()
            proto.providerBundleIdentifier = provider
            manager.protocolConfiguration = proto
            manager.isEnabled = enabled
            return manager
        }
        let owned = manager(AppConfiguration.extensionBundleID)
        let disabled = manager(AppConfiguration.extensionBundleID, enabled: false)
        let foreign = manager("example.foreign.packet")
        XCTAssertNil(try ExtensionProfile.ownedManager(in: [foreign]))
        XCTAssertTrue(try ExtensionProfile.ownedManager(in: [foreign, disabled, owned]) === owned)
        XCTAssertThrowsError(try ExtensionProfile.ownedManager(in: [owned, manager(AppConfiguration.extensionBundleID)]))
    }
}

#if os(iOS)
final class B51StorageTests: XCTestCase {
    private var base: URL!
    private var source: URL { base.appendingPathComponent("isolated") }
    private var target: URL { base.appendingPathComponent("shared") }
    private let fm = FileManager.default

    override func setUpWithError() throws {
        base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try fm.removeItem(at: base) }

    private func sql(_ root: URL, _ statement: String) throws -> String? {
        var db: OpaquePointer?
        guard sqlite3_open(root.appendingPathComponent("settings.db").path, &db) == SQLITE_OK else { throw CocoaError(.fileReadUnknown) }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, statement, -1, &stmt, nil) == SQLITE_OK else { throw CocoaError(.fileReadCorruptFile) }
        defer { sqlite3_finalize(stmt) }
        switch sqlite3_step(stmt) {
        case SQLITE_ROW: return sqlite3_column_text(stmt, 0).map { String(cString: $0) }
        case SQLITE_DONE: return nil
        default: throw CocoaError(.fileWriteUnknown)
        }
    }

    private func seed(_ root: URL, name: String) throws {
        _ = try Database.open(directory: root, importing: nil)
        let configs = root.appendingPathComponent("configs")
        try fm.createDirectory(at: configs, withIntermediateDirectories: true)
        try Data(name.utf8).write(to: configs.appendingPathComponent("config_1.json"))
        _ = try sql(root, "INSERT INTO profiles (id,name,\"order\",type,path) VALUES(1,'\(name)',0,0,'configs/config_1.json')")
        _ = try sql(root, "INSERT INTO preferences VALUES('fixture',X'CAFE')")
        _ = try sql(root, "INSERT INTO remote_servers(id,name,\"order\",url,secret) VALUES(1,'s',0,'host','fixture')")
    }

    func testCleanInstallationHasNoImportMarker() throws {
        _ = try Database.open(directory: target, importing: source)
        XCTAssertEqual(try sql(target, "SELECT COUNT(*) FROM profiles"), "0")
        XCTAssertEqual(try sql(target, "SELECT COUNT(*) FROM sqlite_master WHERE name='sfi_imported_private_b50'"), "0")
    }

    func testUpgradeFromIsolatedPreservesBytesPreferencesServersAndIDsOnlyOnce() throws {
        try seed(source, name: "private")
        for _ in 0..<2 { _ = try Database.open(directory: target, importing: source) }
        XCTAssertEqual(try sql(target, "SELECT name FROM profiles WHERE id=1"), "private")
        XCTAssertEqual(try sql(target, "SELECT COUNT(*) FROM profiles"), "1")
        XCTAssertEqual(try sql(target, "SELECT hex(data) FROM preferences WHERE name='fixture'"), "CAFE")
        XCTAssertEqual(try sql(target, "SELECT COUNT(*) FROM remote_servers"), "1")
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("configs/config_1.json")),
                       try Data(contentsOf: target.appendingPathComponent("configs/config_1.json")))
    }

    func testExistingSharedStoreSurvivesSameIDAndFilenameCollision() throws {
        try seed(source, name: "private")
        try seed(target, name: "shared")
        _ = try Database.open(directory: target, importing: source)
        XCTAssertEqual(try sql(target, "SELECT name FROM profiles WHERE id=1"), "shared")
        let path = try XCTUnwrap(sql(target, "SELECT path FROM profiles WHERE name='private'"))
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent(path), encoding: .utf8), "private")
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("configs/config_1.json"), encoding: .utf8), "shared")
    }

    func testInterruptedImportCanResumeWithoutReplacingDestination() throws {
        try seed(source, name: "private")
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        let blocker = target.appendingPathComponent("configs")
        try Data("existing".utf8).write(to: blocker)
        _ = try Database.open(directory: target, importing: source)
        XCTAssertEqual(try sql(target, "SELECT COUNT(*) FROM profiles"), "0")
        XCTAssertEqual(try String(contentsOf: blocker, encoding: .utf8), "existing")
        try fm.removeItem(at: blocker)
        _ = try Database.open(directory: target, importing: source)
        XCTAssertEqual(try sql(target, "SELECT COUNT(*) FROM profiles"), "1")
    }
}
#endif
