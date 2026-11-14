import XCTest
@testable import Library

final class LXProfileOverridesTests: XCTestCase {
    private let config = """
    {
      "outbounds": [
        {"type":"urltest","tag":"Auto","outbounds":["a","b","c"],"mode":"round_robin","balancer":{"pool":2,"pool_tolerance":100,"sticky_hash":["none"]},"interrupt_exist_connections":false},
        {"type":"urltest","tag":"Gemini","outbounds":["g1","g2"],"mode":"failover"},
        {"type":"chain","tag":"chain","outbounds":["a","g1"]},
        {"type":"vless","tag":"a","transport":{"type":"xhttp"},"encryption":"mlkem768x25519plus.test"}
      ],
      "endpoints":[{"type":"wireguard","tag":"wg"}],
      "dns":{"servers":[{"type":"group","tag":"dns","servers":["a","b"],"mode":"stable"}]},
      "lx":{"mtu_align":"clamp","wg":{"idle_suspend":"45s","lazy_build":true}}
    }
    """

    private func parsed(_ json: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    func testNoOverridesAreByteIdenticalAndProfileScoped() throws {
        XCTAssertEqual(try LXProfileOverrides.apply(config, profileID: 42, storedJSON: ""), config)
        var store = LXOverridesStore()
        var profile = LXProfileSettings()
        var item = LXURLTestOverride()
        item.mode = "failover"
        profile.urlTests["Auto"] = item
        store.profiles["999"] = profile
        XCTAssertEqual(try LXProfileOverrides.apply(config, profileID: 42, storedJSON: store.encode()), config)
    }

    func testFailoverRemovesBalancerAndPreservesOtherFields() throws {
        var store = LXOverridesStore()
        var profile = LXProfileSettings()
        var item = LXURLTestOverride()
        item.mode = "failover"
        profile.urlTests["Auto"] = item
        store.profiles["42"] = profile
        let root = try parsed(LXProfileOverrides.apply(config, profileID: 42, storedJSON: store.encode()))
        let groups = try XCTUnwrap(root["outbounds"] as? [[String: Any]])
        XCTAssertEqual(groups[0]["mode"] as? String, "failover")
        XCTAssertNil(groups[0]["balancer"])
        XCTAssertEqual(groups[0]["interrupt_exist_connections"] as? Bool, false)
        XCTAssertEqual(groups[1]["mode"] as? String, "failover")
        XCTAssertEqual(groups[2]["type"] as? String, "chain")
    }

    func testRoundRobinStickyDisabledUsesNone() throws {
        var store = LXOverridesStore()
        var profile = LXProfileSettings()
        var item = LXURLTestOverride()
        item.mode = "round_robin"
        item.pool = 3
        item.poolTolerance = 175
        item.sticky = false
        profile.urlTests["Gemini"] = item
        store.profiles["42"] = profile
        let root = try parsed(LXProfileOverrides.apply(config, profileID: 42, storedJSON: store.encode()))
        let groups = try XCTUnwrap(root["outbounds"] as? [[String: Any]])
        let balancer = try XCTUnwrap(groups[1]["balancer"] as? [String: Any])
        XCTAssertEqual(balancer["pool"] as? Int, 3)
        XCTAssertEqual(balancer["pool_tolerance"] as? Int, 175)
        XCTAssertEqual(balancer["sticky_hash"] as? [String], ["none"])
    }

    func testDNSAndWGOnOffPreserveMTU() throws {
        var store = LXOverridesStore()
        var profile = LXProfileSettings()
        profile.dnsGroups["dns"] = "fastest"
        profile.wgIdle = "on"
        store.profiles["42"] = profile
        var root = try parsed(LXProfileOverrides.apply(config, profileID: 42, storedJSON: store.encode()))
        var lx = try XCTUnwrap(root["lx"] as? [String: Any])
        XCTAssertEqual(lx["mtu_align"] as? String, "clamp")
        XCTAssertEqual((lx["wg"] as? [String: Any])?["idle_suspend"] as? String, "30s")
        profile.wgIdle = "off"
        store.profiles["42"] = profile
        root = try parsed(LXProfileOverrides.apply(config, profileID: 42, storedJSON: store.encode()))
        lx = try XCTUnwrap(root["lx"] as? [String: Any])
        XCTAssertNil(lx["wg"])
        XCTAssertEqual(lx["mtu_align"] as? String, "clamp")
        let dns = try XCTUnwrap(root["dns"] as? [String: Any])
        XCTAssertEqual((dns["servers"] as? [[String: Any]])?.first?["mode"] as? String, "fastest")
    }

    func testInspectorAndInvalidOptions() throws {
        let summary = try LXProfileOverrides.inspect(config)
        XCTAssertEqual(summary.urlTests.map(\.tag), ["Auto", "Gemini"])
        XCTAssertEqual(summary.dnsGroups.map(\.tag), ["dns"])
        XCTAssertEqual(summary.wireGuardCount, 1)
        XCTAssertEqual(summary.chainCount, 1)
        XCTAssertEqual(summary.xhttpCount, 1)
        XCTAssertEqual(summary.encryptedVlessCount, 1)
        var store = LXOverridesStore()
        var profile = LXProfileSettings()
        var item = LXURLTestOverride()
        item.mode = "round_robin"
        item.pool = -1
        profile.urlTests["Auto"] = item
        store.profiles["42"] = profile
        XCTAssertThrowsError(try LXProfileOverrides.apply(config, profileID: 42, storedJSON: store.encode()))
        XCTAssertThrowsError(try LXProfileOverrides.apply("invalid json", profileID: 42, storedJSON: store.encode()))
    }
}
