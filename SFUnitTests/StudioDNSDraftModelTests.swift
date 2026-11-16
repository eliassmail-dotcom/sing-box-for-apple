#if os(iOS)
import Foundation
import XCTest
@testable import ApplicationLibrary

final class StudioDNSDraftModelTests: XCTestCase {
    private let json = """
    {
      "dns":{
        "final":"proxy-dns",
        "servers":[
          {"tag":"direct-doh","type":"https","server":"1.1.1.1","path":"/p0"},
          {"tag":"proxy-doh","type":"https","server":"8.8.8.8","server_port":8443},
          {"tag":"local","type":"local"},
          {"tag":"ipv6","type":"tls","server":"2606:4700:4700::1111"},
          {"tag":"msk-ix","type":"udp","server":"62.76.76.62"}
        ],
        "rules":[
          {"action":"evaluate","server":"direct-doh","tag":"test"},
          {"action":"respond","match_response":"test","race":true}
        ]
      }
    }
    """
    private func doc() throws -> StudioDocument {
        try StudioDocument(content: json)
    }

    func testCatalogRetainsOriginalURIsAndDoHPaths() throws {
        let items = StudioDNSCatalogEntry.catalog(document: try doc())
        let configured = items.filter(\.isConfigured)
        XCTAssertEqual(configured.count, 5)
        XCTAssertEqual(configured.map(\.name),
            ["direct-doh", "proxy-doh", "local", "ipv6", "msk-ix"])
        XCTAssertEqual(configured.map(\.uri),
            ["https://1.1.1.1/p0",
             "https://8.8.8.8:8443/dns-query",
             "local",
             "tls://[2606:4700:4700::1111]",
             "udp://62.76.76.62"])
        XCTAssertEqual(items.count, 13)
    }

    func testCatalogNeverInfersDNSPurposeFromDirectTransport() throws {
        // The existing config has DNS servers, but it does not necessarily
        // encode editable Direct/Proxy purpose assignments.
        let items = StudioDNSCatalogEntry.catalog(document: try doc())
        XCTAssertNotNil(items.first { $0.id == "config:0" })
        XCTAssertTrue(items.contains { $0.id == "preset:g-doh1" })
        XCTAssertNotEqual(StudioDNSRole.directTraffic, StudioDNSRole.proxyTraffic)
    }

    func testRussianPurposeLabelsAndServiceSeparation() {
        XCTAssertEqual(StudioDNSRole.directTraffic.title, "Direct DNS")
        XCTAssertEqual(StudioDNSRole.proxyTraffic.title, "Proxy DNS")
        XCTAssertTrue(StudioDNSRole.proxyHosts.isService)
        XCTAssertTrue(StudioDNSRole.dnsHosts.isService)
        XCTAssertFalse(StudioDNSRole.directTraffic.isService)
    }

    func testPriorityGroupsAreStableAndHigherLevelIsFallback() {
        let rows: [StudioDNSDraftAssignment] = [
            .init(entryID: "cloudflare", priority: 1),
            .init(entryID: "quad9", priority: 2),
            .init(entryID: "google", priority: 1),
            .init(entryID: "backup", priority: 3)
        ]
        let groups = StudioDNSDraftLogic.groups(rows)
        XCTAssertEqual(groups.map(\.priority), [1, 2, 3])
        XCTAssertEqual(groups[0].entries.map(\.entryID), ["cloudflare", "google"])
        XCTAssertTrue(groups[0].isRace)
        XCTAssertFalse(groups[1].isRace)
        XCTAssertFalse(groups[2].isRace)
    }

    @MainActor
    func testSelectionsRemainIndependentAndSessionOnly() {
        let store = StudioDNSDraftStore()
        XCTAssertEqual(store.rows(for: .directTraffic), [])
        XCTAssertEqual(store.rows(for: .proxyTraffic), [])
        store.toggle("config:0", for: .directTraffic)
        store.toggle("preset:g-doh1", for: .proxyTraffic)
        store.toggle("preset:cf-doh1", for: .proxyTraffic)
        XCTAssertEqual(store.rows(for: .directTraffic).count, 1)
        XCTAssertEqual(store.rows(for: .proxyTraffic).count, 2)
        XCTAssertEqual(StudioDNSDraftLogic.groups(store.rows(for: .proxyTraffic)).count, 1)
        store.changePriority("preset:cf-doh1", for: .proxyTraffic, to: 2)
        XCTAssertEqual(StudioDNSDraftLogic.groups(store.rows(for: .proxyTraffic)).count, 2)
        store.toggle("config:0", for: .directTraffic)
        XCTAssertEqual(store.rows(for: .directTraffic), [])
        XCTAssertEqual(store.rows(for: .proxyTraffic).count, 2)
        store.clear(.proxyTraffic)
        XCTAssertEqual(store.rows(for: .proxyTraffic), [])
        let second = StudioDNSDraftStore()
        XCTAssertEqual(second.rows(for: .proxyTraffic), [])
    }
}
#endif
