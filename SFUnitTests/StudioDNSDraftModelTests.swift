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


    func testObservedR6DNSListsRealServersAndOrderedEvaluationWithoutDraft() throws {
        let data = """
        {
          "outbounds":[{"tag":"direct","type":"direct"},
                       {"tag":"Стратегия","type":"selector","outbounds":[]},
                       {"tag":"Gemini","type":"selector","outbounds":[]}],
          "route":{"default_domain_resolver":"local"},
          "dns":{
            "final":"cloudflare-proxy",
            "servers":[
              {"tag":"local","type":"local"},
              {"tag":"mskix-dns","type":"udp","server":"62.76.76.62"},
              {"tag":"mskix-dns-backup","type":"udp","server":"62.76.62.76"},
              {"tag":"cloudflare-proxy","type":"https","server":"1.1.1.1","detour":"Стратегия"},
              {"tag":"gemini-special","type":"https","server":"8.8.8.8","detour":"Gemini"}
            ],
            "rules":[
              {"action":"evaluate","server":"mskix-dns","tag":"failover-direct-01-1","timeout":"3s"},
              {"action":"respond","match_response":"failover-direct-01-1"},
              {"action":"evaluate","server":"mskix-dns-backup","tag":"failover-direct-01-2"},
              {"action":"route","server":"cloudflare-proxy","race":true},
              {"rule_set":["karing-acl-Gemini"],"action":"evaluate","server":"gemini-special","tag":"gemini-1"},
              {"action":"respond","match_response":"gemini-1"}
            ]
          }
        }
        """
        let document = try StudioDocument(content: data)
        let direct = StudioDNSObservedProfile(document: document, role: .directTraffic)
        XCTAssertEqual(direct.servers.map(\.name), ["mskix-dns", "mskix-dns-backup"])
        XCTAssertEqual(direct.rules.map(\.index), [0, 1, 2])
        XCTAssertEqual(direct.rules.map(\.action), ["evaluate", "respond", "evaluate"])
        XCTAssertEqual(direct.finalServer, "cloudflare-proxy")
        XCTAssertFalse(direct.rules.contains { $0.race })

        let proxy = StudioDNSObservedProfile(document: document, role: .proxyTraffic)
        XCTAssertEqual(proxy.servers.map(\.name), ["cloudflare-proxy", "gemini-special"])
        XCTAssertEqual(proxy.rules.map(\.index), [3, 4, 5])
        XCTAssertTrue(proxy.rules[0].race)

        let service = StudioDNSObservedProfile(document: document, role: .proxyHosts)
        XCTAssertEqual(service.servers.map(\.name), ["local"])
        XCTAssertEqual(service.rules.count, 0)

        let gemini = StudioDNSObservedProfile(document: document, role: .geminiTraffic)
        XCTAssertEqual(gemini.servers.map(\.name), ["gemini-special"])
        XCTAssertEqual(gemini.rules.map(\.index), [4, 5])
        XCTAssertFalse(gemini.rules.contains { $0.race })
    }

    func testGeminiDoesNotInventDNSAssignmentsWhenOnlyMatchResponseExists() throws {
        let document = try StudioDocument(content: """
        {"dns":{"final":"proxy-doh",
        "servers":[{"tag":"proxy-doh","type":"https","server":"1.1.1.1","detour":"Стратегия"}],
        "rules":[{"rule_set":["karing-acl-Gemini"],"action":"respond","match_response":true}]}}
        """)
        let gemini = StudioDNSObservedProfile(document: document, role: .geminiTraffic)
        XCTAssertTrue(gemini.servers.isEmpty)
        XCTAssertEqual(gemini.rules.map(\.index), [0])
        XCTAssertEqual(gemini.finalServer, "proxy-doh")
    }

    func testServiceResolversReportMissingReferencesWithoutFakingServers() throws {
        let document = try StudioDocument(content: """
        {"route":{"default_domain_resolver":"bootstrap-direct-dns-group"},
         "dns":{"servers":[{"type":"local","tag":"local"}],"rules":[]},
         "outbounds":[{"type":"vless","tag":"Server • Gemini","domain_resolver":"missing-tag"}]}
        """)
        let result = StudioDNSObservedProfile(document: document, role: .proxyHosts)
        XCTAssertEqual(result.servers.count, 0)
        XCTAssertEqual(result.unresolvedResolvers,
                       ["bootstrap-direct-dns-group", "missing-tag"])
    }


    func testDNSReuseSameRealSequenceForTwoAddressGroups() throws {
        let document = try StudioDocument(content: """
        {"dns":{"servers":[
            {"tag":"mskix-dns","type":"udp","server":"62.76.76.62"},
            {"tag":"mskix-dns-backup","type":"udp","server":"62.76.62.76"},
            {"tag":"karing-direct-doh-backup","type":"https","server":"8.8.8.8"}
          ],"rules":[
            {"domain_suffix":["site-a.ru"],"action":"evaluate","server":"mskix-dns","tag":"a-1","timeout":"3s"},
            {"match_response":"a-1","action":"respond"},
            {"domain_suffix":["site-a.ru"],"action":"evaluate","server":"mskix-dns-backup","tag":"a-2","timeout":"3s"},
            {"match_response":"a-2","action":"respond"},
            {"domain_suffix":["site-a.ru"],"action":"route","server":"karing-direct-doh-backup"},
            {"domain_suffix":["site-b.ru"],"action":"evaluate","server":"mskix-dns","tag":"b-1","timeout":"3s"},
            {"match_response":"b-1","action":"respond"},
            {"domain_suffix":["site-b.ru"],"action":"evaluate","server":"mskix-dns-backup","tag":"b-2","timeout":"3s"},
            {"match_response":"b-2","action":"respond"},
            {"domain_suffix":["site-b.ru"],"action":"route","server":"karing-direct-doh-backup"},
            {"rule_set":["independent"],"action":"reject"}
          ]}}
        """)
        let found = StudioDNSSchemeCatalog(document: document)
        XCTAssertEqual(found.schemes.count, 1)
        let scheme = try XCTUnwrap(found.schemes.first)
        XCTAssertEqual(scheme.serversInOrder,
                       ["mskix-dns", "mskix-dns-backup", "karing-direct-doh-backup"])
        XCTAssertFalse(scheme.hasExplicitRace)
        XCTAssertEqual(scheme.bindings.count, 2)
        XCTAssertEqual(scheme.template.map(\.index), [0, 1, 2, 3, 4])
        XCTAssertEqual(scheme.bindings[1].ruleIndexes, [5, 6, 7, 8, 9])
        XCTAssertEqual(found.ungroupedRuleIndexes, [10])
        XCTAssertEqual(found.linkedSchemes(forDNSRules: [7]).map(\.id), [scheme.id])
        XCTAssertTrue(found.linkedSchemes(forDNSRules: [10]).isEmpty)
    }

    func testDNSSchemeNeverInventsRaceOrLinksUnqualifiedGlobalRules() throws {
        let document = try StudioDocument(content: """
        {"dns":{"rules":[
          {"action":"evaluate","server":"proxy-doh"},
          {"match_response":true,"action":"respond"},
          {"domain":["gemini.google.com"],"action":"evaluate",
           "server":"proxy-doh","tag":"gemini-1","race":true},
          {"match_response":"gemini-1","action":"respond"},
          {"domain":["gemini.google.com"],"action":"route","server":"proxy-doh-backup"}
        ]}}
        """)
        let found = StudioDNSSchemeCatalog(document: document)
        XCTAssertEqual(found.schemes.count, 1)
        XCTAssertTrue(found.schemes[0].hasExplicitRace)
        XCTAssertEqual(found.ungroupedRuleIndexes, [0, 1])
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
