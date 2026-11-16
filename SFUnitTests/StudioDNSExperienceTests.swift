#if os(iOS)
import Foundation
import XCTest
@testable import ApplicationLibrary

final class StudioDNSExperienceTests: XCTestCase {
    private let json = """
    {
      "outbounds": [
        {"tag":"direct","type":"direct"},
        {"tag":"Proxy","type":"selector","outbounds":["p1"]},
        {"tag":"Gemini","type":"urltest","outbounds":["p1"]},
        {"tag":"p1","type":"vless","server":"example.invalid","server_port":443}
      ],
      "route": {
        "final":"Proxy",
        "rules":[
          {"domain":["site1.example","site2.example"],"outbound":"direct"},
          {"domain":["site3.example"],"outbound":"Proxy"}
        ]
      },
      "dns": {
        "final":"direct-a",
        "servers":[
          {"tag":"direct-a","type":"https","server":"1.1.1.1","path":"/p0"},
          {"tag":"proxy-a","type":"https","server":"8.8.8.8","detour":"Proxy"},
          {"tag":"corp","type":"https","server":"192.0.2.1","detour":"corporate-unknown"}
        ],
        "rules":[
          {"action":"evaluate","server":"proxy-a","tag":"probe",
           "domain":["site1.example","site2.example"]},
          {"action":"route","server":"direct-a","match_response":"probe",
           "response_rcode":[0],"race":true},
          {"action":"route","server":"proxy-a","speculative":true},
          {"action":"respond","match_response":"probe"},
          {"domain":["site3.example"],"server":"direct-a"}
        ]
      }
    }
    """

    private func document() throws -> StudioDocument {
        try StudioDocument(content: json)
    }

    func testProfileClassificationKeepsUnknownDetoursSeparate() throws {
        let profiles = StudioDNSExplanation.profiles(document: try document())
        let direct = try XCTUnwrap(profiles.first { $0.family == .direct })
        let proxy = try XCTUnwrap(profiles.first { $0.family == .proxy })
        let unknown = try XCTUnwrap(profiles.first { $0.family == .other })
        XCTAssertEqual(direct.bindings.map(\.name), ["direct-a"])
        XCTAssertEqual(proxy.bindings.map(\.name), ["proxy-a"])
        XCTAssertEqual(unknown.bindings.map(\.name), ["corp"])
        XCTAssertEqual(direct.ruleIndexes, [1, 4])
        XCTAssertEqual(proxy.ruleIndexes, [0, 2])
        XCTAssertEqual(unknown.ruleIndexes, [])
        XCTAssertEqual(direct.bindings.first?.object["path"] as? String, "/p0")
    }

    func testDNSRuleFlowKeepsOrderAndEvaluationSemantics() throws {
        let steps = StudioDNSExplanation.steps(document: try document())
        XCTAssertEqual(steps.map(\.index), [0, 1, 2, 3, 4])
        XCTAssertEqual(steps.map(\.action),
                       ["evaluate", "route", "route", "respond", "route"])
        XCTAssertEqual(steps[0].condition, "2 точных домена")
        XCTAssertTrue(steps[0].result.contains("следующими правилами"))
        XCTAssertEqual(steps[1].responseDependency, "Результат проверки «probe»")
        XCTAssertTrue(steps[1].race)
        XCTAssertTrue(steps[2].speculative)
        XCTAssertTrue(steps[3].result.contains("evaluate"))
        XCTAssertEqual(steps[4].heading, "Запросить DNS-сервер")
    }

    func testCompactSummaryCountsRulesWithoutClaimingExecutionOrder() throws {
        let steps = StudioDNSExplanation.steps(document: try document())
        let summary = StudioDNSExplanation.RuleSummary(rules: steps)
        XCTAssertEqual(steps.count, 5)
        XCTAssertEqual(summary.routeCount, 3)
        XCTAssertEqual(summary.evaluateCount, 1)
        XCTAssertEqual(summary.respondCount, 1)
        XCTAssertEqual(summary.raceCount, 1)
        XCTAssertEqual(summary.speculativeCount, 1)
        XCTAssertEqual(summary.otherCount, 0)
        XCTAssertEqual(summary.servers, ["direct-a", "proxy-a"])
    }

    func testFilteredSummaryNeverInventsMissingEvaluationSteps() throws {
        let steps = StudioDNSExplanation.steps(document: try document())
        let subset = steps.filter { [1, 2, 3].contains($0.index) }
        let summary = StudioDNSExplanation.RuleSummary(rules: subset)
        XCTAssertEqual(subset.map(\.index), [1, 2, 3])
        XCTAssertEqual(summary.evaluateCount, 0)
        XCTAssertEqual(summary.respondCount, 1)
        XCTAssertEqual(summary.raceCount, 1)
        XCTAssertEqual(summary.speculativeCount, 1)
        XCTAssertEqual(summary.servers, ["direct-a", "proxy-a"])
    }

    func testRoutesSuggestProfilesWithoutChangingDNSRules() throws {
        let doc = try document()
        XCTAssertEqual(StudioDNSExplanation.suggestedFamily(forRoute: "direct", document: doc), .direct)
        XCTAssertEqual(StudioDNSExplanation.suggestedFamily(forRoute: "Proxy", document: doc), .proxy)
        XCTAssertEqual(StudioDNSExplanation.suggestedFamily(forRoute: "Gemini", document: doc), .proxy)
        XCTAssertNil(StudioDNSExplanation.suggestedFamily(forRoute: "unknown", document: doc))
        let model = StudioSemanticModel(document: doc)
        XCTAssertEqual(model.defaultDNS, "direct-a")
        XCTAssertEqual(model.defaultRoute, "Proxy")
        XCTAssertEqual(model.addressPolicies.first?.title, "2 точных домена")
    }

    func testDNSConditionsDoNotClaimSingleDomainForLists() {
        let exact = ["a.example", "b.example", "c.example"]
        XCTAssertEqual(StudioDNSExplanation.exactDomainCount(["domain": exact]), 3)
        XCTAssertEqual(StudioDNSExplanation.conditionsDescription(["domain": exact]), "3 точных домена")
        XCTAssertEqual(StudioDNSExplanation.conditionsDescription([:]),
                       "Если предыдущие правила не завершили обработку")
    }

    func testHumanReadableFieldsExplainIdleAndDoH() {
        XCTAssertEqual(StudioHumanFields.label("idle_timeout"),
                       "Остановка проверок при бездействии")
        XCTAssertEqual(StudioHumanFields.label("domain"), "Точные домены")
        XCTAssertEqual(StudioHumanFields.action("evaluate"), "Проверить DNS")
    }
}
#endif
