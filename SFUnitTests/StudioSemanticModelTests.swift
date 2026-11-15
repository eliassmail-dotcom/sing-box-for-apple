#if os(iOS)
import Foundation
import XCTest
@testable import ApplicationLibrary

final class StudioSemanticModelTests: XCTestCase {
    private let fixture = """
    {
      "outbounds": [
        {"type": "vless", "tag": "node-a", "server":"server-a.invalid", "server_port": 443},
        {"type": "vless", "tag": "node-b", "server":"server-b.invalid", "server_port": 443},
        {"type": "selector", "tag": "США", "outbounds":["node-a"]},
        {"type": "urltest", "tag": "Основные", "outbounds":["node-b","США"], "mode":"failover"},
        {"type": "selector", "tag": "Комбинированная", "outbounds":["node-a","Основные"],
         "include":["EU"], "exclude":["blocked"]},
        {"type": "selector", "tag": "Цикл", "outbounds":["Цикл"]}
      ],
      "route": {
        "final": "Основные",
        "default_http_client": "rules-direct",
        "rules": [
          {"rule_set":["google"],"outbound":"Комбинированная"},
          {"domain_suffix":["youtube.com"],"outbound":"Основные"},
          {"domain_suffix":["youtube.com"],"outbound":"node-b"}
        ]
      },
      "dns": {
        "final":"dnsdirect1",
        "servers":[
          {"tag":"dnsdirect1","type":"https","server":"1.1.1.1"},
          {"tag":"proxydns1","type":"https","server":"8.8.8.8","detour":"Основные"}
        ],
        "rules":[
          {"rule_set":["google"],"action":"route","server":"proxydns1"},
          {"domain_suffix":["youtube.com"],"action":"route","server":"dnsdirect1"},
          {"domain_suffix":["example.org"],"action":"route","server":"dnsdirect1"},
          {"action":"evaluate","server":"dnsdirect1"},
          {"action":"respond","match_response":true,"race":true}
        ]
      }
    }
    """

    private func load() throws -> StudioSemanticModel {
        StudioSemanticModel(document: try StudioDocument(content: fixture))
    }

    func testCompositeGroupsExpandInOrderWithDeduplication() throws {
        let model = try load()
        let group = try XCTUnwrap(model.groups.first { $0.id == "Комбинированная" })
        XCTAssertEqual(group.composition, "Комбинированная")
        XCTAssertEqual(group.explicitNodes, ["node-a"])
        XCTAssertEqual(group.memberGroups, ["Основные"])
        XCTAssertEqual(group.includePatterns, ["EU"])
        XCTAssertEqual(group.excludePatterns, ["blocked"])
        XCTAssertEqual(group.resolvedNodes, ["node-a", "node-b"])
        XCTAssertEqual(group.cycles, [])
        XCTAssertEqual(group.unresolvedReferences, [])
        let cycle = try XCTUnwrap(model.groups.first { $0.id == "Цикл" })
        XCTAssertEqual(cycle.cycles, ["Цикл"])
    }

    func testNestedDynamicIncludesAndExcludesApplyAtEachLevel() {
        typealias Group = StudioNodeGroupComposer.Definition
        let groups = [
            Group(id: "Europe", members: ["CH base"],
                  include: ["germany"], exclude: ["Germany white"]),
            Group(id: "Composite", members: ["Europe", "PT base"],
                  include: ["Swiss"], exclude: ["Portugal"])
        ]
        let inventory = ["CH base", "Germany base", "Germany white", "PT base", "Swiss backup"]
        let result = StudioNodeGroupComposer.resolve(
            group: "Composite", definitions: groups,
            knownTags: inventory,
            filterableNodes: inventory
        )
        XCTAssertEqual(result.nodes, ["CH base", "Germany base", "Swiss backup"])
        XCTAssertTrue(result.missing.isEmpty)
        XCTAssertTrue(result.cycles.isEmpty)
    }

    func testStrategiesAreNotTechnicalGroupsAndHaveNoFabricatedTiers() throws {
        let model = try load()
        let smart = try XCTUnwrap(model.strategies.first { $0.id == "Основные" })
        XCTAssertEqual(smart.readableKind, "Резервирование")
        XCTAssertTrue(smart.verifiedPriorityLevels.isEmpty)
        XCTAssertEqual(smart.participantGroups, ["США"])
        let manual = try XCTUnwrap(model.strategies.first { $0.id == "США" })
        XCTAssertEqual(manual.readableKind, "Ручной выбор")
    }

    func testDefaultRoutesAndNamedDNSAndPolicyBuckets() throws {
        let model = try load()
        XCTAssertEqual(model.defaultRoute, "Основные")
        XCTAssertEqual(model.defaultDNS, "dnsdirect1")
        XCTAssertEqual(model.defaultHTTPClient, "rules-direct")
        XCTAssertEqual(model.dnsServers.map(\.name), ["dnsdirect1", "proxydns1"])
        let direct = try XCTUnwrap(model.dnsPolicies.first { $0.server == "dnsdirect1" && $0.action == "route" })
        XCTAssertEqual(direct.indices, [1, 2])
        let race = try XCTUnwrap(model.dnsPolicies.first { $0.race })
        XCTAssertEqual(race.indices, [4])
        XCTAssertTrue(race.matchesEvaluatedResponse)
    }

    func testAddressGroupsLinkOnlyExactMatchingCriteria() throws {
        let model = try load()
        let youtube = try XCTUnwrap(model.addressPolicies.first { $0.title == "youtube.com" })
        XCTAssertEqual(youtube.routeRules, [1, 2])
        XCTAssertEqual(youtube.dnsRules, [1])
        XCTAssertEqual(youtube.destinations, ["Основные", "node-b"])
        XCTAssertEqual(youtube.dnsTargets, ["dnsdirect1"])
        let google = try XCTUnwrap(model.addressPolicies.first { $0.title == "google" })
        XCTAssertEqual(google.routeRules, [0])
        XCTAssertEqual(google.dnsRules, [0])
    }

    func testDNSFollowsRouteAndRespectsExplicitAndProtectedPolicies() {
        let map = ["Proxy": "proxydns1", "direct": "dnsdirect1", "Gemini": "dns-gemini"]
        let proxy = StudioDNSFollowRoute.resolve(route: "Proxy", choice: .automatic,
                                                  association: map, defaultDNS: "fallback")
        let direct = StudioDNSFollowRoute.resolve(route: "direct", choice: .automatic,
                                                   association: map, defaultDNS: "fallback")
        XCTAssertEqual(proxy.dns, "proxydns1")
        XCTAssertEqual(direct.dns, "dnsdirect1")
        XCTAssertEqual(direct.source, .associated)
        XCTAssertEqual(StudioDNSFollowRoute.resolve(route: "direct",
                                                     choice: .explicit("corporate-dns"),
                                                     association: map, defaultDNS: "fallback").dns,
                       "corporate-dns")
        XCTAssertEqual(StudioDNSFollowRoute.resolve(route: "Proxy",
                                                     choice: .automatic,
                                                     association: map, defaultDNS: "fallback",
                                                     protectedDNS: "bootstrap-dns").dns,
                       "bootstrap-dns")
        let unknown = StudioDNSFollowRoute.resolve(route: "new-route", choice: .automatic,
                                                    association: map, defaultDNS: "fallback")
        XCTAssertEqual(unknown.source, .unmapped)
    }

    func testQuarantinedNodesAreLastResortAcrossAllTiers() {
        typealias Tier = StudioSemanticModel.PriorityTier
        typealias Sample = StudioTierEligibility.NodeSample
        let tiers = [
            Tier(id: "base", group: "Base", check: .urlTest, minimumHealthy: 1,
                 quarantine: .deprioritize, returnAfterRecovery: true),
            Tier(id: "white", group: "White", check: .urlTest, minimumHealthy: 1,
                 quarantine: .exclude, returnAfterRecovery: true)
        ]
        let quarantinedBase = [Sample(tag: "bad", urlTestOK: true,
                                       realDialOK: nil, quarantined: true)]
        let availableWhite = [Sample(tag: "white", urlTestOK: true,
                                     realDialOK: nil, quarantined: false)]
        XCTAssertEqual(StudioTierEligibility.activeTier(tiers: tiers, samplesByGroup: [
            "Base": quarantinedBase, "White": availableWhite
        ]), "white")
        XCTAssertEqual(StudioTierEligibility.activeTier(tiers: tiers, samplesByGroup: [
            "Base": quarantinedBase, "White": []
        ]), "base")
    }

    func testNLevelHealthChecksAreIndependentOfURLTestAndQuarantine() {
        typealias Tier = StudioSemanticModel.PriorityTier
        typealias Sample = StudioTierEligibility.NodeSample
        let tiers = [
            Tier(id: "one", group: "Base", check: .combined, minimumHealthy: 2,
                 quarantine: .exclude, returnAfterRecovery: true),
            Tier(id: "two", group: "Reserve", check: .realDial, minimumHealthy: 1,
                 quarantine: .exclude, returnAfterRecovery: true),
            Tier(id: "three", group: "White", check: .urlTest, minimumHealthy: 1,
                 quarantine: .lastResort, returnAfterRecovery: false)
        ]
        let samples: [String: [Sample]] = [
            "Base": [
                Sample(tag: "p1", urlTestOK: true, realDialOK: false, quarantined: false),
                Sample(tag: "p2", urlTestOK: true, realDialOK: true, quarantined: true)
            ],
            "Reserve": [Sample(tag: "r1", urlTestOK: false, realDialOK: true, quarantined: false)],
            "White": [Sample(tag: "w1", urlTestOK: true, realDialOK: nil, quarantined: true)]
        ]
        XCTAssertEqual(StudioTierEligibility.activeTier(tiers: tiers, samplesByGroup: samples), "two")
        let unknown = StudioTierEligibility.evaluate(
            tier: tiers[0],
            samples: [Sample(tag: "unknown", urlTestOK: true, realDialOK: nil, quarantined: false)]
        )
        XCTAssertEqual(unknown.unknown, ["unknown"])
        XCTAssertFalse(unknown.meetsMinimum)
    }
}
#endif
