#if os(iOS)
import Foundation
import XCTest
@testable import ApplicationLibrary

@MainActor
final class LocalGeneratorEngineTests: XCTestCase {
    private let offlineNodes = """
    {"outbounds":[
      {"type":"vless","tag":"🇩🇪 Германия","server":"de.example.invalid","server_port":443,"uuid":"11111111-1111-4111-8111-111111111111","flow":"xtls-rprx-vision","tls":{"enabled":true,"server_name":"example.invalid","reality":{"enabled":true,"public_key":"AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA","short_id":"0123456789abcdef"}}},
      {"type":"vless","tag":"🇨🇭 Gemini","server":"ch.example.invalid","server_port":443,"uuid":"11111111-1111-4111-8111-111111111111","flow":"xtls-rprx-vision","tls":{"enabled":true,"server_name":"example.invalid","reality":{"enabled":true,"public_key":"AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA","short_id":"0123456789abcdef"}}},
      {"type":"vless","tag":"🇫🇷 Франция","server":"fr.example.invalid","server_port":443,"uuid":"11111111-1111-4111-8111-111111111111","flow":"xtls-rprx-vision","tls":{"enabled":true,"server_name":"example.invalid","reality":{"enabled":true,"public_key":"AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA","short_id":"0123456789abcdef"}}}
    ]}
    """

    func testEnvironmentInputAllowsEqualsInSubscriptionToken() throws {
        let values = try LocalGeneratorEngine.parseVariables(
            "SUB_URL=https://example.invalid/sub?key=abcdef==\n" +
            "# this is a comment\n" +
            "CONNECT_TIMEOUT=2\n" +
            "SELECTOR_INTERRUPT=false"
        )
        XCTAssertEqual(values["CONNECT_TIMEOUT"], "2")
        XCTAssertEqual(values["SUB_URL"], "https://example.invalid/sub?key=abcdef==")
        XCTAssertEqual(values["SELECTOR_INTERRUPT"], "false")
        XCTAssertThrowsError(try LocalGeneratorEngine.parseVariables("BAD KEY=not allowed"))
        XCTAssertThrowsError(try LocalGeneratorEngine.parseVariables("TEST=1\nTEST=2"))
    }

    func testStreamingSubscriptionLimitRejectsBeforeAppendingExtraByte() throws {
        var data = Data()
        for byte in [UInt8(1), 2, 3] {
            try LocalGeneratorEngine.appendLimitedSubscriptionByte(byte, to: &data, limit: 3)
        }
        XCTAssertEqual(data, Data([1, 2, 3]))
        XCTAssertThrowsError(
            try LocalGeneratorEngine.appendLimitedSubscriptionByte(4, to: &data, limit: 3)
        )
        // The fourth byte was not allocated into the accumulated buffer.
        XCTAssertEqual(data, Data([1, 2, 3]))
    }

    func testBundledGeneratorZlibPayloadIsValidAndRunnable() throws {
        // Isolate the compressed bundle from WKWebView lifecycle. Older
        // versions passed the RFC 1950 zlib header to a raw DEFLATE decoder,
        // so the JS loader failed before the generator could execute.
        let script = try LocalGeneratorBundle.javascript()
        XCTAssertGreaterThan(script.utf8.count, 4_096)
        XCTAssertTrue(script.contains("__localYcGenerator"))
        // A second decode must produce identical source, not mutable state.
        XCTAssertEqual(script, try LocalGeneratorBundle.javascript())
    }

    func testBundledGeneratorContainsR6Modules() throws {
        let script = try LocalGeneratorBundle.javascript()
        XCTAssertTrue(script.contains("v1.4.48r6"))
        XCTAssertTrue(script.contains("mskix-dns"))
        XCTAssertTrue(script.contains("mskix-dns-backup"))
        XCTAssertFalse(script.contains("karing-direct-dns"))
        XCTAssertTrue(script.contains("bootstrap-direct-dns-group"))
        XCTAssertTrue(script.contains("Gemini • Super • A"))
        XCTAssertTrue(script.contains("__localYcGenerator"))
    }

    func testR6TwoGeminiNodesAndBootstrapOnDevice() async throws {
        // Two Gemini exits plus one normal node must create four members:
        // two direct paths and two chains. No external subscription is fetched.
        let nodes = offlineNodes.replacingOccurrences(
            of: "🇫🇷 Франция", with: "🇦🇹 Gemini"
        )
        let result = try await LocalGeneratorEngine().generate(
            variables: [
                "GEMINI_NODES": "Gemini",
                "NET_FALLBACK": "true",
                "CONNECT_TIMEOUT": "2",
                "SELECTOR_INTERRUPT": "false",
                "TEST_INTERVAL": "5",
            ],
            subscription: nodes,
            variant: "personal",
            core: "lx",
            platform: "ios",
            log: "info"
        )
        let json = try XCTUnwrap(result.json)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(json.utf8)
        ) as? [String: Any])
        let route = try XCTUnwrap(root["route"] as? [String: Any])
        XCTAssertEqual(route["auto_detect_interface"] as? Bool, true)
        let outbounds = try XCTUnwrap(root["outbounds"] as? [[String: Any]])
        let superA = try XCTUnwrap(outbounds.first {
            ($0["tag"] as? String) == "Gemini • Super • A"
        })
        let members = try XCTUnwrap(superA["outbounds"] as? [String])
        XCTAssertEqual(members.count, 4)
        XCTAssertEqual(Set(members).count, 4)
        XCTAssertEqual(members.filter { $0.hasPrefix("C • ") }.count, 2)
        XCTAssertTrue(outbounds.filter { ($0["type"] as? String) == "vless" }.allSatisfy {
            ($0["domain_resolver"] as? String) == "bootstrap-direct-dns-group"
        })
        let dns = try XCTUnwrap(root["dns"] as? [String: Any])
        let servers = try XCTUnwrap(dns["servers"] as? [[String: Any]])
        for tag in ["bootstrap-cloudflare-doh", "bootstrap-google-doh"] {
            let server = try XCTUnwrap(servers.first { ($0["tag"] as? String) == tag })
            XCTAssertNil(server["detour"], "DoH bootstrap detour must not be emitted for LX")
        }
        XCTAssertTrue(servers.contains { ($0["tag"] as? String) == "mskix-dns" })
        XCTAssertTrue(servers.contains { ($0["tag"] as? String) == "mskix-dns-backup" })
        XCTAssertFalse(servers.contains { ($0["tag"] as? String) == "karing-direct-dns" })
    }

    func testBundledGeneratorBuildsRealJSONOfflineWithoutYandex() async throws {
        let engine = LocalGeneratorEngine()
        let generated = try await engine.generate(
            variables: [
                "GEMINI_NODES": "Gemini",
                "CONNECT_TIMEOUT": "2",
                "SELECTOR_INTERRUPT": "false",
                "TEST_INTERVAL": "5",
            ],
            subscription: offlineNodes,
            variant: "personal",
            core: "lx",
            platform: "ios",
            log: "info"
        )
        XCTAssertTrue(generated.ok)
        let json = try XCTUnwrap(generated.json)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(json.utf8)
        ) as? [String: Any])
        let out = try XCTUnwrap(root["outbounds"] as? [[String: Any]])
        XCTAssertTrue(out.contains { ($0["tag"] as? String) == "Стратегия" })
        XCTAssertTrue(out.contains { ($0["tag"] as? String) == "Gemini+" })
        let route = try XCTUnwrap(root["route"] as? [String: Any])
        XCTAssertEqual(route["final"] as? String, "Стратегия")
        XCTAssertFalse((root["endpoints"] as? [[String: Any]] ?? []).contains {
            ($0["tag"] as? String) == "corporate-vpn"
        })
        // Creating a profile is a distinct, explicit user action.
        // This test intentionally does not write to ProfileManager.
    }
}
#endif
