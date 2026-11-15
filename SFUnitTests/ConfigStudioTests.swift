#if os(iOS)
import Foundation
import XCTest
@testable import ApplicationLibrary

final class ConfigStudioTests: XCTestCase {
    private let fixture = """
    {
      "outbounds": [
        {"type":"vless","tag":"узел","uuid":"sensitive-uuid","server":"example.invalid"},
        {"type":"selector","tag":"Стратегия","outbounds":["узел"]},
        {"type":"chain","tag":"Gemini Chain","outbounds":["Стратегия","узел"]}
      ],
      "endpoints": [{"type":"openconnect","tag":"corporate-vpn","password":"sensitive-password"}],
      "route": {
        "final":"Стратегия",
        "rules":[{"domain_suffix":["example.org"],"action":"route","outbound":"Стратегия"}],
        "rule_set":[{"type":"remote","tag":"whitelist","url":"https://example.invalid/rule.srs?key=secretvalue"}]
      },
      "dns": {
        "servers":[{"type":"https","tag":"dns","server":"1.1.1.1"}],
        "rules":[{"action":"evaluate","server":"dns"}]
      },
      "http_clients":[{"tag":"rules-direct","detour":"direct"}],
      "future_lx_field":{"custom":true}
    }
    """

    func testReadOnlyModelPreservesEveryRootSection() throws {
        let document = try StudioDocument(content: fixture)
        XCTAssertEqual(document.array("outbounds").count, 3)
        XCTAssertEqual(document.array("endpoints").count, 1)
        let paths = Set(document.categories.map(\.path))
        XCTAssertTrue(paths.contains("groups"))
        XCTAssertTrue(paths.contains("chains"))
        XCTAssertTrue(paths.contains("nodes"))
        XCTAssertTrue(paths.contains("route.rules"))
        XCTAssertTrue(paths.contains("route.rule_set"))
        XCTAssertTrue(paths.contains("dns.servers"))
        XCTAssertTrue(paths.contains("dns.rules"))
        XCTAssertTrue(paths.contains("http_clients"))
        XCTAssertTrue(paths.contains("future_lx_field"))
        XCTAssertEqual(document.root.keys.count, 6)
        XCTAssertEqual(document.raw, fixture)
    }

    func testSanitizedJSONNeverRevealsSecretFieldsOrURLKeys() throws {
        let document = try StudioDocument(content: fixture)
        let preview = StudioDocumentFormatter.pretty(document.root)
        XCTAssertFalse(preview.contains("sensitive-uuid"))
        XCTAssertFalse(preview.contains("sensitive-password"))
        XCTAssertFalse(preview.contains("secretvalue"))
        XCTAssertFalse(StudioDocumentFormatter.pretty("password-secret", key: "password").contains("password-secret"))
        XCTAssertTrue(preview.contains("corporate-vpn"))
        XCTAssertTrue(preview.contains("Стратегия"))
        XCTAssertTrue(preview.contains("future_lx_field"))
        XCTAssertTrue(document.raw.contains("sensitive-uuid")) // read-only source intact
    }

    func testLocalVariablesRejectSecretsAndBadValues() throws {
        let existing = StudioGeneratorVariables.load()
        defer { try? StudioGeneratorVariables.save(existing) }
        XCTAssertThrowsError(try StudioGeneratorVariables.save(["CORPORATE_TOKEN": "super-secret"]))
        XCTAssertThrowsError(try StudioGeneratorVariables.save(["SUB_URL": "https://example.invalid/?key=secret"]))
        XCTAssertThrowsError(try StudioGeneratorVariables.save(["DNS_CAPACITY": "1"]))
        XCTAssertThrowsError(try StudioGeneratorVariables.save(["TEST_URL": "https://x.invalid/?token=secret"]))
        try StudioGeneratorVariables.save([
            "GEMINI_NODES": "Gemini",
            "TEST_MODE": "failover",
            "DNS_RACE": "true",
        ])
        XCTAssertEqual(StudioGeneratorVariables.load()["GEMINI_NODES"], "Gemini")
        XCTAssertTrue(StudioGeneratorVariables.lines().contains("TEST_MODE=failover"))
    }
    func testNativeFieldLabelsAndSelectorsAreHumanReadable() {
        XCTAssertEqual(StudioHumanFields.label("domain_suffix"), "Домены и поддомены")
        XCTAssertEqual(StudioHumanFields.label("ip_cidr"), "IP-адреса и подсети")
        XCTAssertEqual(StudioHumanFields.label("outbounds"), "Участники")
        XCTAssertEqual(StudioHumanFields.kind("openconnect"), "Корпоративный OpenConnect")
        XCTAssertEqual(StudioHumanFields.mode("round_robin"), "Чередование узлов")
        XCTAssertEqual(StudioHumanFields.mode("and"), "Все условия (И)")
        XCTAssertEqual(StudioHumanFields.action("hijack-dns"), "Перехватить DNS")
        XCTAssertEqual(StudioHumanFields.display("least_test", key: "mode"), "Самый быстрый доступный")
    }

    func testNativeScalarDisplayRedactsSecretsAndSeparatesBooleanFromNumeric() {
        XCTAssertEqual(StudioHumanFields.display("abcdefgh", key: "password"), "••••••")
        XCTAssertEqual(StudioHumanFields.display("client-uuid", key: "uuid"), "••••••")
        XCTAssertEqual(StudioHumanFields.display(NSNumber(value: 175), key: "tolerance"), "175 мс")
        XCTAssertTrue(StudioHumanFields.isBoolean(NSNumber(value: true)))
        XCTAssertFalse(StudioHumanFields.isBoolean(NSNumber(value: 1)))
        XCTAssertEqual(StudioHumanFields.display(NSNumber(value: true), key: "enabled"), "Включено")
    }

    func testNestedObjectsRetainFieldsWithoutUserFacingJSONFallback() throws {
        let document = try StudioDocument(content: fixture)
        let dns = try XCTUnwrap(document.categories.first(where: { $0.path == "dns.rules" }))
        let rule = try XCTUnwrap(dns.items.first)
        let options = try XCTUnwrap(rule.raw as? [String: Any])
        XCTAssertEqual(options["action"] as? String, "evaluate")
        XCTAssertEqual(options["server"] as? String, "dns")
        XCTAssertEqual(dns.items.count, 1)
        let nested = StudioDocumentFormatter.sanitized(document.root)
        XCTAssertNotNil(nested as? [String: Any])
    }

}
#endif
