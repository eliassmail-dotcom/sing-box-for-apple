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

    func testGlobalOverrideAndPerGroupException() throws {
        var store = LXOverridesStore()
        var settings = LXProfileSettings()
        settings.urlTestDefault.mode = "failover"
        var gemini = LXURLTestOverride()
        gemini.mode = "least_test"
        settings.urlTests["Gemini"] = gemini
        store.profiles["42"] = settings
        let root = try parsed(LXProfileOverrides.apply(config, profileID: 42, storedJSON: store.encode()))
        let groups = try XCTUnwrap(root["outbounds"] as? [[String: Any]])
        XCTAssertEqual(groups[0]["mode"] as? String, "failover")
        XCTAssertNil(groups[0]["balancer"])
        XCTAssertEqual(groups[1]["mode"] as? String, "least_test")
        XCTAssertEqual(groups[1]["interrupt_exist_connections"] as? Bool, nil)
    }

    func testExplicitProfileOptOutOfGlobal() throws {
        var store = LXOverridesStore()
        var settings = LXProfileSettings()
        settings.urlTestDefault.mode = "least_test"
        var exclude = LXURLTestOverride()
        exclude.mode = "profile"
        settings.urlTests["Auto"] = exclude
        store.profiles["42"] = settings
        let root = try parsed(LXProfileOverrides.apply(config, profileID: 42, storedJSON: store.encode()))
        let groups = try XCTUnwrap(root["outbounds"] as? [[String: Any]])
        XCTAssertEqual(groups[0]["mode"] as? String, "round_robin")
        XCTAssertNotNil(groups[0]["balancer"])
        XCTAssertEqual(groups[1]["mode"] as? String, "least_test")
    }

    func testGlobalRoundRobinParametersInheritedByGroups() throws {
        var store = LXOverridesStore()
        var settings = LXProfileSettings()
        settings.urlTestDefault.mode = "round_robin"
        settings.urlTestDefault.pool = 4
        settings.urlTestDefault.poolTolerance = 175
        settings.urlTestDefault.sticky = false
        store.profiles["42"] = settings
        let root = try parsed(LXProfileOverrides.apply(config, profileID: 42, storedJSON: store.encode()))
        let groups = try XCTUnwrap(root["outbounds"] as? [[String: Any]])
        for group in groups.prefix(2) {
            XCTAssertEqual(group["mode"] as? String, "round_robin")
            let balancer = try XCTUnwrap(group["balancer"] as? [String: Any])
            XCTAssertEqual(balancer["pool"] as? Int, 4)
            XCTAssertEqual(balancer["pool_tolerance"] as? Int, 175)
            XCTAssertEqual(balancer["sticky_hash"] as? [String], ["none"])
        }
    }

    func testLegacySavedSettingsDecodeAndRemainScoped() throws {
        let legacy = """
        {"profiles":{"42":{"urlTests":{"Auto":{"mode":"failover","pool":3,"poolTolerance":0,"sticky":true}},"dnsGroups":{},"wgIdle":"profile"}}}
        """
        let store = try LXOverridesStore.decode(legacy)
        XCTAssertEqual(store.profiles["42"]?.urlTestDefault.mode, "profile")
        let output = try LXProfileOverrides.apply(config, profileID: 42, storedJSON: legacy)
        let root = try parsed(output)
        let groups = try XCTUnwrap(root["outbounds"] as? [[String: Any]])
        XCTAssertEqual(groups[0]["mode"] as? String, "failover")
        XCTAssertEqual(groups[1]["mode"] as? String, "failover")
        XCTAssertEqual(try LXProfileOverrides.apply(config, profileID: 43, storedJSON: legacy), config)
        XCTAssertNoThrow(try LXOverridesStore.decode(store.encode()))
    }


    func testWhiteFallbackInjectionAndBackwardCompatibility() throws {
        let source = """
        {"outbounds":[
          {"type":"selector","tag":"Стратегия","outbounds":["Авто · Базовая","Авто · Белые"],"default":"Авто · Базовая"},
          {"type":"urltest","tag":"Авто · Базовая","outbounds":["a"],"mode":"failover","interval":"5s"},
          {"type":"urltest","tag":"Авто · Белые","outbounds":["w"],"mode":"failover"},
          {"type":"vless","tag":"a"}, {"type":"vless","tag":"w"}
        ],"route":{"final":"Стратегия"}}
        """
        XCTAssertTrue(LXProfileOverrides.supportsWhiteFallback(source))
        // No settings or extra Apply action required: the group is available on first start.
        let transformed = try LXProfileOverrides.apply(source, profileID: 42, storedJSON: "")
        let root = try parsed(transformed)
        let outbounds = try XCTUnwrap(root["outbounds"] as? [[String: Any]])
        let reserve = try XCTUnwrap(outbounds.first(where: { ($0["tag"] as? String) == LXProfileOverrides.preferredFallbackTag }))
        XCTAssertEqual(reserve["priority_outbounds"] as? [String], ["Авто · Базовая"])
        XCTAssertEqual(reserve["outbounds"] as? [String], ["Авто · Базовая", "Авто · Белые"])
        XCTAssertEqual(reserve["interval"] as? String, "5s")
        XCTAssertEqual(reserve["interrupt_exist_connections"] as? Bool, false)
        let selector = try XCTUnwrap(outbounds.first(where: { ($0["tag"] as? String) == "Стратегия" }))
        XCTAssertEqual((selector["outbounds"] as? [String])?.last, LXProfileOverrides.preferredFallbackTag)
        XCTAssertEqual(selector["default"] as? String, "Авто · Базовая")
        XCTAssertEqual((root["route"] as? [String: Any])?["final"] as? String, "Стратегия")
        // Old per-profile toggle is ignored: both prior enabled and disabled
        // preferences produce the same effective group, with no duplicate.
        let legacyOn = #"{"profiles":{"42":{"whiteFallbackEnabled":true}}}"#
        let legacyOff = #"{"profiles":{"42":{"whiteFallbackEnabled":false}}}"#
        let withLegacyOn = try LXProfileOverrides.apply(source, profileID: 42, storedJSON: legacyOn)
        let withLegacyOff = try LXProfileOverrides.apply(source, profileID: 42, storedJSON: legacyOff)
        XCTAssertEqual(try parsed(withLegacyOn)["outbounds"] as? [[String: Any]] != nil, true)
        XCTAssertEqual(try parsed(withLegacyOff)["outbounds"] as? [[String: Any]] != nil, true)
        let onOutbounds = try XCTUnwrap(parsed(withLegacyOn)["outbounds"] as? [[String: Any]])
        let offOutbounds = try XCTUnwrap(parsed(withLegacyOff)["outbounds"] as? [[String: Any]])
        XCTAssertEqual(onOutbounds.filter { ($0["tag"] as? String) == LXProfileOverrides.preferredFallbackTag }.count, 1)
        XCTAssertEqual(offOutbounds.filter { ($0["tag"] as? String) == LXProfileOverrides.preferredFallbackTag }.count, 1)
        XCTAssertEqual(try LXProfileOverrides.apply(source, profileID: 12, storedJSON: ""), transformed)
    }

    func testWhiteFallbackRequiresBothGroupsAndRootSelector() throws {
        XCTAssertFalse(LXProfileOverrides.supportsWhiteFallback(config))
        // Unrelated profiles remain byte-identical, even without saved settings.
        XCTAssertEqual(try LXProfileOverrides.apply(config, profileID: 42, storedJSON: ""), config)
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
    func testAdaptiveHealthOverridesOnlyLeastTestAndKeepSource() throws {
        var store = LXOverridesStore()
        var settings = LXProfileSettings()
        var auto = LXURLTestOverride()
        auto.mode = "least_test"
        settings.urlTests["Auto"] = auto
        settings.adaptiveTolerancePercent = 30
        settings.minHoldSeconds = 30
        settings.probeURLs = "https://example.org/generate_204, https://example.net/health"
        store.profiles["42"] = settings
        let root = try parsed(LXProfileOverrides.apply(config, profileID: 42, storedJSON: store.encode()))
        let groups = try XCTUnwrap(root["outbounds"] as? [[String: Any]])
        XCTAssertEqual(groups[0]["mode"] as? String, "least_test")
        XCTAssertEqual(groups[0]["tolerance_percent"] as? Int, 30)
        XCTAssertEqual(groups[0]["min_hold"] as? String, "30s")
        XCTAssertEqual(groups[0]["urls"] as? [String], ["https://example.org/generate_204", "https://example.net/health"])
        XCTAssertNil(groups[0]["url"])
        XCTAssertNil(groups[1]["tolerance_percent"])
        XCTAssertNil(groups[1]["min_hold"])
        XCTAssertEqual(groups[1]["mode"] as? String, "failover")
        XCTAssertEqual(groups[1]["urls"] as? [String], ["https://example.org/generate_204", "https://example.net/health"])
        XCTAssertEqual(try LXProfileOverrides.apply(config, profileID: 41, storedJSON: store.encode()), config)
    }

    func testAdaptiveHealthInvalidURLAndBackwardCompatibility() throws {
        let oldJSON = #"{"profiles":{"42":{"urlTests":{},"dnsGroups":{},"wgIdle":"profile"}}}"#
        let oldStore = try LXOverridesStore.decode(oldJSON)
        XCTAssertEqual(oldStore.profiles["42"]?.adaptiveTolerancePercent, 0)
        XCTAssertEqual(oldStore.profiles["42"]?.minHoldSeconds, 0)
        XCTAssertEqual(oldStore.profiles["42"]?.probeURLs, "")
        for urls in ["https://example.org,https://example.org",
                     "ftp://example.org",
                     "http://a,http://b,http://c,http://d"] {
            var settings = LXProfileSettings()
            settings.probeURLs = urls
            var store = LXOverridesStore()
            store.profiles["42"] = settings
            XCTAssertThrowsError(try LXProfileOverrides.apply(config, profileID: 42, storedJSON: store.encode()))
        }
    }

    func testGeneratedSmartFallbackReceivesAdaptiveHealthOverrides() throws {
        let source = """
        {"outbounds":[
          {"type":"selector","tag":"Стратегия","outbounds":["Авто · Базовая","Авто · Белые"]},
          {"type":"urltest","tag":"Авто · Базовая","outbounds":["a"],"mode":"failover"},
          {"type":"urltest","tag":"Авто · Белые","outbounds":["b"],"mode":"failover"},
          {"type":"vless","tag":"a"}, {"type":"vless","tag":"b"}
        ],"route":{"final":"Стратегия"}}
        """
        var store = LXOverridesStore()
        var settings = LXProfileSettings()
        settings.adaptiveTolerancePercent = 30
        settings.minHoldSeconds = 30
        settings.probeURLs = "https://example.org/health,https://example.net/health"
        store.profiles["42"] = settings
        let root = try parsed(LXProfileOverrides.apply(source, profileID: 42, storedJSON: store.encode()))
        let outbounds = try XCTUnwrap(root["outbounds"] as? [[String: Any]])
        let smart = try XCTUnwrap(outbounds.first(where: { ($0["tag"] as? String) == LXProfileOverrides.preferredFallbackTag }))
        XCTAssertEqual(smart["mode"] as? String, "least_test")
        XCTAssertEqual(smart["tolerance_percent"] as? Int, 30)
        XCTAssertEqual(smart["min_hold"] as? String, "30s")
        XCTAssertEqual(smart["urls"] as? [String], ["https://example.org/health", "https://example.net/health"])
        XCTAssertEqual(outbounds.first(where: { ($0["tag"] as? String) == "Авто · Базовая" })?["mode"] as? String, "failover")
    }

    func testPassiveGuardOptInSkipsRoundRobinAndPersistsPerProfile() throws {
        let oldJSON = #"{"profiles":{"42":{"urlTests":{},"dnsGroups":{},"wgIdle":"profile"}}}"#
        XCTAssertEqual(try LXOverridesStore.decode(oldJSON).profiles["42"]?.passiveGuardEnabled, false)
        XCTAssertEqual(try LXProfileOverrides.apply(config, profileID: 42, storedJSON: ""), config)

        var store = LXOverridesStore()
        var settings = LXProfileSettings()
        settings.passiveGuardEnabled = true
        store.profiles["42"] = settings
        let applied = try parsed(LXProfileOverrides.apply(config, profileID: 42, storedJSON: store.encode()))
        let groups = try XCTUnwrap(applied["outbounds"] as? [[String: Any]])
        XCTAssertNil(groups[0]["passive_guard"]) // round_robin rejects guard
        XCTAssertEqual(groups[1]["passive_guard"] as? Bool, true) // failover
        XCTAssertEqual(try LXProfileOverrides.apply(config, profileID: 41, storedJSON: store.encode()), config)
    }

    func testGeneratedSmartFallbackReceivesPassiveGuardWhenEnabled() throws {
        let source = """
        {"outbounds":[
            {"type":"selector","tag":"Стратегия","outbounds":["Авто · Базовая","Авто · Белые"]},
            {"type":"urltest","tag":"Авто · Базовая","outbounds":["a"],"mode":"least_test"},
            {"type":"urltest","tag":"Авто · Белые","outbounds":["b"],"mode":"failover"},
            {"type":"vless","tag":"a"}, {"type":"vless","tag":"b"}
        ],"route":{"final":"Стратегия"}}
        """
        var store = LXOverridesStore()
        var settings = LXProfileSettings()
        settings.passiveGuardEnabled = true
        store.profiles["42"] = settings
        let applied = try parsed(LXProfileOverrides.apply(source, profileID: 42, storedJSON: store.encode()))
        let groups = try XCTUnwrap(applied["outbounds"] as? [[String: Any]])
        for tag in ["Авто · Базовая", "Авто · Белые", LXProfileOverrides.preferredFallbackTag] {
            XCTAssertEqual(
                groups.first(where: { ($0["tag"] as? String) == tag })?["passive_guard"] as? Bool,
                true
            )
        }
    }


    func testDashboardResiliencePresetPreservesOtherProfileOverrides() throws {
        var store = LXOverridesStore()
        var current = LXProfileSettings()
        current.geminiChainsEnabled = true
        current.probeURLs = "https://example.org/health"
        current.urlTestDefault.mode = "failover"
        var customGroup = LXURLTestOverride()
        customGroup.mode = "least_test"
        current.urlTests["Gemini"] = customGroup
        current.dnsGroups["dns"] = "stable"
        store.profiles["42"] = current

        var otherProfile = LXProfileSettings()
        otherProfile.applyResiliencePreset("antiblock")
        store.profiles["77"] = otherProfile

        current.applyResiliencePreset("balance")
        store.profiles["42"] = current
        let saved = try LXOverridesStore.decode(store.encode())

        XCTAssertEqual(saved.profiles["42"]?.resiliencePreset, "balance")
        XCTAssertEqual(saved.profiles["42"]?.adaptiveTolerancePercent, 20)
        XCTAssertEqual(saved.profiles["42"]?.minHoldSeconds, 30)
        XCTAssertEqual(saved.profiles["42"]?.passiveGuardEnabled, false)
        XCTAssertEqual(saved.profiles["42"]?.geminiChainsEnabled, true)
        XCTAssertEqual(saved.profiles["42"]?.probeURLs, "https://example.org/health")
        XCTAssertEqual(saved.profiles["42"]?.urlTestDefault.mode, "failover")
        XCTAssertEqual(saved.profiles["42"]?.urlTests["Gemini"]?.mode, "least_test")
        XCTAssertEqual(saved.profiles["42"]?.dnsGroups["dns"], "stable")
        XCTAssertEqual(saved.profiles["77"], otherProfile)

        current.applyResiliencePreset("economy") // Stable label, legacy storage ID.
        XCTAssertEqual(current.adaptiveTolerancePercent, 0)
        XCTAssertEqual(current.minHoldSeconds, 60)
        XCTAssertEqual(current.passiveGuardEnabled, false)

        current.applyResiliencePreset("antiblock")
        XCTAssertEqual(current.adaptiveTolerancePercent, 35)
        XCTAssertEqual(current.minHoldSeconds, 10)
        XCTAssertEqual(current.passiveGuardEnabled, true)
    }


}
