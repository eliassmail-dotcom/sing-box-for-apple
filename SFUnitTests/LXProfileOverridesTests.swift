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

    func testModeOverrideRejectsLeakedNativeAdaptiveFields() throws {
        let source = """
        {"outbounds":[
          {"type":"urltest","tag":"Auto","outbounds":["a","b"],"mode":"least_test",
           "tolerance":20,"tolerance_percent":25,"min_hold":"30s",
           "priority_outbounds":["a"],"passive_guard":true,
           "balancer":{"pool":2,"pool_tolerance":175}},
          {"type":"vless","tag":"a"},{"type":"vless","tag":"b"}
        ]}
        """
        for mode in ["failover", "round_robin"] {
            var store = LXOverridesStore()
            var settings = LXProfileSettings()
            settings.urlTestDefault.mode = mode
            store.profiles["42"] = settings
            let root = try parsed(LXProfileOverrides.apply(source, profileID: 42, storedJSON: store.encode()))
            let groups = try XCTUnwrap(root["outbounds"] as? [[String: Any]])
            let group = groups[0]
            XCTAssertEqual(group["mode"] as? String, mode)
            for field in ["tolerance", "tolerance_percent", "min_hold", "priority_outbounds"] {
                XCTAssertNil(group[field], "\(mode) leaked \(field)")
            }
            if mode == "failover" {
                XCTAssertNil(group["balancer"])
                XCTAssertEqual(group["passive_guard"] as? Bool, true)
            } else {
                XCTAssertNotNil(group["balancer"])
                XCTAssertNil(group["passive_guard"])
            }
        }
    }

    func testInheritedModeNormalizationWhenOtherOverrideChangesProfile() throws {
        let source = """
        {"outbounds":[
          {"type":"urltest","tag":"Failover","outbounds":["a"],"mode":"failover",
           "tolerance_percent":20,"min_hold":"30s","balancer":{"pool":2},"custom_extra":"keep"},
          {"type":"urltest","tag":"RoundRobin","outbounds":["a"],"mode":"round_robin",
           "tolerance":20,"priority_outbounds":["a"],"passive_guard":true},
          {"type":"urltest","tag":"Least","outbounds":["a"],"mode":"least_test",
           "balancer":{"pool":2},"tolerance_percent":20},
          {"type":"vless","tag":"a"}
        ]}
        """
        var store = LXOverridesStore()
        var settings = LXProfileSettings()
        settings.probeURLs = "https://health.example/ping"
        store.profiles["42"] = settings
        let root = try parsed(LXProfileOverrides.apply(source, profileID: 42, storedJSON: store.encode()))
        let groups = try XCTUnwrap(root["outbounds"] as? [[String: Any]])
        XCTAssertNil(groups[0]["tolerance_percent"])
        XCTAssertNil(groups[0]["min_hold"])
        XCTAssertNil(groups[0]["balancer"])
        XCTAssertEqual(groups[0]["custom_extra"] as? String, "keep")
        XCTAssertNil(groups[1]["tolerance"])
        XCTAssertNil(groups[1]["priority_outbounds"])
        XCTAssertNil(groups[1]["passive_guard"])
        XCTAssertNil(groups[2]["balancer"])
        XCTAssertEqual(groups[2]["tolerance_percent"] as? Int, 20)
        for group in groups.prefix(3) {
            XCTAssertEqual(group["urls"] as? [String], ["https://health.example/ping"])
        }
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
        XCTAssertEqual(reserve["priority_outbounds"] as? [String], ["a"])
        XCTAssertEqual(reserve["outbounds"] as? [String], ["a", "w"])
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

    func testSmartFallbackFlattensNestedURLTestGroupsAndDeduplicatesTiers() throws {
        let source = """
        {"outbounds":[
          {"type":"selector","tag":"Стратегия","outbounds":["Авто · Базовая","Авто · Белые"]},
          {"type":"urltest","tag":"Авто · Базовая","outbounds":["base-a","Базовая подгруппа"],"url":"https://base.example/health","interval":"5s"},
          {"type":"urltest","tag":"Базовая подгруппа","outbounds":["base-b","base-c"],"url":"https://nested.example/health"},
          {"type":"urltest","tag":"Авто · Белые","outbounds":["white-a","base-a"],"url":"https://white.example/health"},
          {"type":"vless","tag":"base-a"}, {"type":"vless","tag":"base-b"},
          {"type":"vless","tag":"base-c"}, {"type":"vless","tag":"white-a"}
        ],"route":{"final":"Стратегия"}}
        """
        XCTAssertTrue(LXProfileOverrides.supportsWhiteFallback(source))
        let root = try parsed(LXProfileOverrides.apply(source, profileID: 42, storedJSON: ""))
        let outbounds = try XCTUnwrap(root["outbounds"] as? [[String: Any]])
        let smart = try XCTUnwrap(outbounds.first {
            ($0["tag"] as? String) == LXProfileOverrides.preferredFallbackTag
        })
        XCTAssertEqual(smart["outbounds"] as? [String], ["base-a", "base-b", "base-c", "white-a"])
        XCTAssertEqual(smart["priority_outbounds"] as? [String], ["base-a", "base-b", "base-c"])
        XCTAssertEqual(smart["mode"] as? String, "least_test")
        XCTAssertEqual(smart["interval"] as? String, "5s")
        XCTAssertEqual(
            smart["urls"] as? [String],
            ["https://base.example/health", "https://nested.example/health", "https://white.example/health"]
        )
        // Source groups are retained, but Smart no longer nests them.
        XCTAssertEqual(
            outbounds.first(where: { ($0["tag"] as? String) == "Авто · Базовая" })?["outbounds"] as? [String],
            ["base-a", "Базовая подгруппа"]
        )
        XCTAssertEqual(
            outbounds.first(where: { ($0["tag"] as? String) == "Авто · Белые" })?["outbounds"] as? [String],
            ["white-a", "base-a"]
        )
    }

    func testSmartFallbackMigratesPreviousNestedGeneratedGroup() throws {
        let source = """
        {"outbounds":[
          {"type":"selector","tag":"Стратегия","outbounds":["Авто · Базовая","Авто · Белые","Авто · База → Белые"]},
          {"type":"urltest","tag":"Авто · Базовая","outbounds":["a"]},
          {"type":"urltest","tag":"Авто · Белые","outbounds":["w"]},
          {"type":"urltest","tag":"Авто · База → Белые","outbounds":["Авто · Базовая","Авто · Белые"],"mode":"least_test","priority_outbounds":["Авто · Базовая"]},
          {"type":"vless","tag":"a"}, {"type":"vless","tag":"w"}
        ],"route":{"final":"Стратегия"}}
        """
        var settings = LXProfileSettings()
        settings.urlTestDefault.mode = "round_robin"
        settings.urlTestDefault.pool = 2
        var store = LXOverridesStore()
        store.profiles["42"] = settings
        let root = try parsed(LXProfileOverrides.apply(source, profileID: 42, storedJSON: store.encode()))
        let outbounds = try XCTUnwrap(root["outbounds"] as? [[String: Any]])
        let smartGroups = outbounds.filter {
            ($0["tag"] as? String) == LXProfileOverrides.preferredFallbackTag
        }
        XCTAssertEqual(smartGroups.count, 1)
        XCTAssertEqual(smartGroups.first?["outbounds"] as? [String], ["a", "w"])
        XCTAssertEqual(smartGroups.first?["priority_outbounds"] as? [String], ["a"])
        XCTAssertEqual(smartGroups.first?["mode"] as? String, "least_test")
        XCTAssertNil(smartGroups.first?["balancer"])
        XCTAssertEqual(outbounds.first(where: { ($0["tag"] as? String) == "Авто · Базовая" })?["mode"] as? String, "round_robin")
        let selector = try XCTUnwrap(outbounds.first { ($0["tag"] as? String) == "Стратегия" })
        XCTAssertEqual(
            (selector["outbounds"] as? [String])?.filter { $0 == LXProfileOverrides.preferredFallbackTag }.count,
            1
        )
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
        XCTAssertEqual(smart["outbounds"] as? [String], ["a", "b"])
        XCTAssertEqual(smart["priority_outbounds"] as? [String], ["a"])
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



    func testLegacyFalsePoliciesInheritSourceConfiguration() throws {
        let source = """
        {"outbounds":[
          {"type":"urltest","tag":"Auto","outbounds":["a"],"mode":"least_test","tolerance_percent":25,"min_hold":"20s","passive_guard":true},
          {"type":"urltest","tag":"Gemini+","outbounds":["a"]},
          {"type":"selector","tag":"Gemini","outbounds":["Gemini • Chain • A"]},
          {"type":"chain","tag":"Gemini • Chain • A","outbounds":["a","a"]},
          {"type":"vless","tag":"a"}
        ]}
        """
        let legacy = #"{"profiles":{"42":{"adaptiveTolerancePercent":0,"minHoldSeconds":0,"passiveGuardEnabled":false,"geminiChainsEnabled":false}}}"#
        let settings = try XCTUnwrap(LXOverridesStore.decode(legacy).profiles["42"])
        XCTAssertNil(settings.adaptiveToleranceOverride)
        XCTAssertNil(settings.minHoldOverride)
        XCTAssertNil(settings.passiveGuardOverride)
        XCTAssertNil(settings.geminiChainsOverride)
        XCTAssertEqual(try LXProfileOverrides.apply(source, profileID: 42, storedJSON: legacy), source)
    }

    func testExplicitOffPoliciesArePersistedAndRemoveSourceFields() throws {
        let source = """
        {"outbounds":[
          {"type":"urltest","tag":"Auto","outbounds":["a"],"mode":"least_test","tolerance_percent":25,"min_hold":"20s","passive_guard":true},
          {"type":"selector","tag":"Стратегия","outbounds":["Auto"]},
          {"type":"urltest","tag":"Gemini+","outbounds":["a"]},
          {"type":"selector","tag":"Gemini","outbounds":["Gemini • Chain • A"]},
          {"type":"chain","tag":"Gemini • Chain • A","outbounds":["a","a"]},
          {"type":"vless","tag":"a"}
        ],"route":{"final":"Стратегия"}}
        """
        var settings = LXProfileSettings()
        settings.adaptiveToleranceOverride = false
        settings.minHoldOverride = false
        settings.passiveGuardOverride = false
        settings.geminiChainsOverride = false
        var store = LXOverridesStore()
        store.profiles["42"] = settings
        let saved = try LXOverridesStore.decode(store.encode()).profiles["42"]
        XCTAssertEqual(saved?.adaptiveToleranceOverride, false)
        XCTAssertEqual(saved?.minHoldOverride, false)
        XCTAssertEqual(saved?.passiveGuardOverride, false)
        XCTAssertEqual(saved?.geminiChainsOverride, false)

        let root = try parsed(LXProfileOverrides.apply(source, profileID: 42, storedJSON: store.encode()))
        let outbounds = try XCTUnwrap(root["outbounds"] as? [[String: Any]])
        let auto = try XCTUnwrap(outbounds.first { ($0["tag"] as? String) == "Auto" })
        XCTAssertNil(auto["tolerance_percent"])
        XCTAssertNil(auto["min_hold"])
        XCTAssertNil(auto["passive_guard"])
        let geminiRoot = try XCTUnwrap(outbounds.first { ($0["tag"] as? String) == "Gemini" })
        XCTAssertFalse((geminiRoot["outbounds"] as? [String] ?? []).contains("Gemini • Chain • A"))
        XCTAssertFalse(outbounds.contains { ($0["tag"] as? String) == "Gemini • Chain • A" })
    }

    func testModeSwitchStripsIncompatibleURLTestOptions() throws {
        let source = """
        {"outbounds":[
          {"type":"urltest","tag":"Auto","outbounds":["a"],"mode":"least_test",
           "tolerance":50,"tolerance_percent":25,"min_hold":"20s",
           "priority_outbounds":["a"],"passive_guard":true},
          {"type":"vless","tag":"a"}
        ]}
        """
        for mode in ["failover", "round_robin"] {
            var settings = LXProfileSettings()
            var override = LXURLTestOverride()
            override.mode = mode
            settings.urlTests["Auto"] = override
            var store = LXOverridesStore()
            store.profiles["42"] = settings
            let root = try parsed(LXProfileOverrides.apply(source, profileID: 42, storedJSON: store.encode()))
            let group = try XCTUnwrap((root["outbounds"] as? [[String: Any]])?.first)
            XCTAssertEqual(group["mode"] as? String, mode)
            for key in ["tolerance", "tolerance_percent", "min_hold", "priority_outbounds"] {
                XCTAssertNil(group[key], "\(mode) must remove incompatible \(key)")
            }
            if mode == "round_robin" {
                XCTAssertNil(group["passive_guard"])
                XCTAssertNotNil(group["balancer"])
            } else {
                XCTAssertEqual(group["passive_guard"] as? Bool, true)
                XCTAssertNil(group["balancer"])
            }
        }
    }

}


    func testDesiredSnapshotRejectsStaleRollbackWhenOnlyNonConfigOptionChanged() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(ExtensionStartOptions.snapshotFileName)

        let original: [String: NSObject] = [
            "configContent": NSString(string: "{\\"outbounds\\":[]}"),
            "systemProxyEnabled": NSNumber(value: false),
        ]
        let newer: [String: NSObject] = [
            "configContent": NSString(string: "{\\"outbounds\\":[]}"),
            "systemProxyEnabled": NSNumber(value: true),
        ]

        try ExtensionStartOptions.writeSnapshot(original, to: url, expectedCurrent: nil)
        try ExtensionStartOptions.writeSnapshot(newer, to: url, expectedCurrent: original)

        XCTAssertThrowsError(
            try ExtensionStartOptions.writeSnapshot(original, to: url, expectedCurrent: original)
        )

        let stored = try XCTUnwrap(ExtensionStartOptions.readSnapshot(from: url))
        XCTAssertEqual(stored["systemProxyEnabled"] as? Bool, true)
    }

    func testDesiredSnapshotAllowsIdempotentCommitButRejectsMissingExpectedSnapshot() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(ExtensionStartOptions.snapshotFileName)

        let candidate: [String: NSObject] = [
            "configContent": NSString(string: "{\\"outbounds\\":[]}"),
            "includeAllNetworks": NSNumber(value: false),
        ]

        try ExtensionStartOptions.writeSnapshot(candidate, to: url, expectedCurrent: nil)
        // Repeating the same commit is safe even if the original expected
        // snapshot has already been replaced by this exact candidate.
        try ExtensionStartOptions.writeSnapshot(candidate, to: url, expectedCurrent: nil)

        let missingURL = directory.appendingPathComponent("missing.plist")
        XCTAssertThrowsError(
            try ExtensionStartOptions.writeSnapshot(candidate, to: missingURL, expectedCurrent: candidate)
        )
    }
