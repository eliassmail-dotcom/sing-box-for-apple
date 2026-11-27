import Foundation
import XCTest
@testable import Library

final class LXGeminiBuilderTests: XCTestCase {
    private let source = """
    {
      "outbounds": [
        {"type":"selector","tag":"Стратегия","outbounds":["Авто · Базовая"],"default":"Авто · Базовая"},
        {"type":"urltest","tag":"Авто · Базовая","outbounds":["France"],"url":"https://example.org/health"},
        {"type":"vless","tag":"France","server":"fr.example.org","server_port":443,"uuid":"unit"},
        {"type":"urltest","tag":"Gemini+","outbounds":["Swiss (Gemini)","Austria (Gemini)"],"url":"https://example.org/generate_204","interval":"5s"},
        {"type":"vless","tag":"Swiss (Gemini)","server":"ch.example.org","server_port":443,"uuid":"unit"},
        {"type":"vless","tag":"Austria (Gemini)","server":"at.example.org","server_port":443,"uuid":"unit"},
        {"type":"selector","tag":"Gemini","outbounds":["Gemini • Chain • A","Gemini • Авто"],"default":"Gemini • Chain • A"},
        {"type":"urltest","tag":"Gemini • Chain • A","outbounds":["Legacy Chain"]},
        {"type":"chain","tag":"Legacy Chain","outbounds":["France","Swiss (Gemini)"]}
      ],
      "route": {
        "final":"Стратегия",
        "rules":[{"domain":["gemini.google.com"],"outbound":"Gemini"}]
      }
    }
    """

    private func document(_ content: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any])
    }

    private func outbounds(_ root: [String: Any]) throws -> [[String: Any]] {
        try XCTUnwrap(root["outbounds"] as? [[String: Any]])
    }

    private func item(_ tag: String, in outbounds: [[String: Any]]) throws -> [String: Any] {
        try XCTUnwrap(outbounds.first { ($0["tag"] as? String) == tag })
    }

    private func transformed(chains: Bool) throws -> [String: Any] {
        var settings = LXProfileSettings()
        settings.geminiChainsEnabled = chains
        var store = LXOverridesStore()
        store.profiles["42"] = settings
        return try document(LXProfileOverrides.apply(source, profileID: 42, storedJSON: store.encode()))
    }

    func testLocallyBuildsOrdinaryGeminiFromOnlyGeminiPlus() throws {
        let root = try transformed(chains: false)
        let out = try outbounds(root)
        let original = try document(source)
        let srcGroup = try item("Gemini+", in: out)
        XCTAssertEqual(srcGroup["outbounds"] as? [String], ["Swiss (Gemini)", "Austria (Gemini)"])
        XCTAssertEqual(
            try item("Gemini • Авто", in: out)["outbounds"] as? [String],
            ["Swiss (Gemini)", "Austria (Gemini)"]
        )
        XCTAssertEqual(
            try item("Gemini • Super • A", in: out)["outbounds"] as? [String],
            ["Swiss (Gemini)", "Austria (Gemini)"]
        )
        XCTAssertEqual(
            try item("Gemini", in: out)["outbounds"] as? [String],
            ["Gemini • Super • A", "Gemini • Авто", "Gemini • Выбор"]
        )
        XCTAssertEqual(try item("Gemini • Авто", in: out)["interval"] as? String, "5s")
        XCTAssertEqual(try item("Gemini • Авто", in: out)["url"] as? String, "https://example.org/generate_204")
        XCTAssertFalse(out.contains { ($0["tag"] as? String) == "Gemini • Chain • A" })
        XCTAssertFalse(out.contains { ($0["tag"] as? String)?.hasPrefix("LX • Gemini • Chain • ") == true })
        XCTAssertEqual(
            (root["route"] as? [String: Any])?["final"] as? String,
            (original["route"] as? [String: Any])?["final"] as? String
        )
        XCTAssertEqual(
            ((root["route"] as? [String: Any])?["rules"] as? [[String: Any]])?.first?["outbound"] as? String,
            "Gemini"
        )
    }

    func testGeminiChainsUseDynamicStrategyAsFirstHop() throws {
        let root = try transformed(chains: true)
        let out = try outbounds(root)
        let leaves = ["Swiss (Gemini)", "Austria (Gemini)"]
        let chains = leaves.map { "LX • Gemini • Chain • " + $0 }
        XCTAssertEqual(try item("Gemini • Chain • A", in: out)["outbounds"] as? [String], chains)
        XCTAssertEqual(try item("Gemini • Super • A", in: out)["outbounds"] as? [String], leaves + chains)
        XCTAssertEqual(try item("Gemini • Выбор", in: out)["outbounds"] as? [String], leaves + chains)
        for (name, exit) in zip(chains, leaves) {
            let chain = try item(name, in: out)
            XCTAssertEqual(chain["type"] as? String, "chain")
            // A strategy change must automatically affect hop #0; never freeze
            // its current VLESS leaf at subscription-refresh/start time.
            let exitCopy = "LX • Gemini • Exit • " + exit
            XCTAssertEqual(chain["outbounds"] as? [String], ["Стратегия", exitCopy])
            XCTAssertEqual(chain["interrupt_exist_connections"] as? Bool, false)
            XCTAssertNil(chain["idle_timeout"])
            XCTAssertNil(chain["detour"])
            let original = try item(exit, in: out)
            let copied = try item(exitCopy, in: out)
            XCTAssertEqual(copied["type"] as? String, original["type"] as? String)
            XCTAssertEqual(copied["server"] as? String, original["server"] as? String)
            XCTAssertEqual(copied["uuid"] as? String, original["uuid"] as? String)
            XCTAssertNil(original["detour"])
        }
        XCTAssertEqual(
            try item("Gemini", in: out)["default"] as? String,
            "Gemini • Super • A"
        )
        XCTAssertEqual(try item("Gemini+", in: out)["outbounds"] as? [String], leaves)
        // Resilience settings are applied after building all local groups.
        var profile = LXProfileSettings()
        profile.geminiChainsEnabled = true
        profile.applyResiliencePreset("antiblock")
        var store = LXOverridesStore()
        store.profiles["42"] = profile
        let tuned = try outbounds(document(LXProfileOverrides.apply(
            source, profileID: 42, storedJSON: store.encode()
        )))
        let auto = try item("Gemini • Super • A", in: tuned)
        XCTAssertEqual(auto["passive_guard"] as? Bool, true)
        XCTAssertEqual(auto["min_hold"] as? String, "10s")
        XCTAssertEqual(auto["tolerance_percent"] as? Int, 35)
        // Legacy per-source group remains available to any external references.
        XCTAssertNotNil(try? item("Legacy Chain", in: tuned))
    }

    func testGeminiChainExitsAreIsolatedIncludingRetainedChain() throws {
        var root = try transformed(chains: true)
        let before = try outbounds(root)
        let direct = ["Swiss (Gemini)", "Austria (Gemini)"]
        let chains = before.filter { $0["type"] as? String == "chain" }
        let upper = chains.flatMap { ($0["outbounds"] as? [String] ?? []).dropFirst() }
        XCTAssertEqual(Set(upper).count, upper.count)
        XCTAssertTrue(Set(upper).isDisjoint(with: direct))
        XCTAssertEqual(try item("Gemini • Авто", in: before)["outbounds"] as? [String], direct)
        XCTAssertTrue(try LXGeminiBuilder.apply(to: &root, chainsEnabled: true))
        let after = try outbounds(root)
        XCTAssertEqual(Set(before.compactMap { $0["tag"] as? String }), Set(after.compactMap { $0["tag"] as? String }))
        for leaf in direct {
            XCTAssertNil(try item(leaf, in: after)["detour"])
        }
        XCTAssertTrue(try LXGeminiBuilder.apply(to: &root, chainsEnabled: false))
        let disabled = try outbounds(root)
        XCTAssertFalse(disabled.contains { ($0["tag"] as? String)?.hasPrefix("LX • Gemini • Exit • ") == true })
        let retained = try item("Legacy Chain", in: disabled)
        let exit = try XCTUnwrap((retained["outbounds"] as? [String])?.last)
        XCTAssertNotNil(try? item(exit, in: disabled))
        XCTAssertFalse(direct.contains(exit))
    }

    func testWireGuardStaysDirectAndIsNeverDuplicated() throws {
        var root = try document(source)
        var out = try outbounds(root)
        out.append(["type": "wireguard", "tag": "WG"])
        let index = try XCTUnwrap(out.firstIndex { $0["tag"] as? String == "Gemini+" })
        out[index]["outbounds"] = ["Swiss (Gemini)", "WG"]
        root["outbounds"] = out
        XCTAssertTrue(try LXGeminiBuilder.apply(to: &root, chainsEnabled: true))
        let built = try outbounds(root)
        XCTAssertEqual(try item("Gemini • Авто", in: built)["outbounds"] as? [String], ["Swiss (Gemini)", "WG"])
        XCTAssertEqual(try item("Gemini • Chain • A", in: built)["outbounds"] as? [String], ["LX • Gemini • Chain • Swiss (Gemini)"])
        XCTAssertEqual(built.filter { $0["type"] as? String == "wireguard" }.count, 1)

        out[index]["outbounds"] = ["WG"]
        var onlyWG = try document(source)
        onlyWG["outbounds"] = out
        XCTAssertThrowsError(try LXGeminiBuilder.apply(to: &onlyWG, chainsEnabled: true))
        XCTAssertTrue(try LXGeminiBuilder.apply(to: &onlyWG, chainsEnabled: false))
    }

    func testSharedLegacyUpperGroupIsRejectedInsteadOfRedirectingDirectGemini() throws {
        var root = try document(source)
        var out = try outbounds(root)
        let legacy = try XCTUnwrap(out.firstIndex { $0["tag"] as? String == "Legacy Chain" })
        out[legacy]["outbounds"] = ["France", "Gemini+"]
        root["outbounds"] = out
        XCTAssertThrowsError(try LXGeminiBuilder.apply(to: &root, chainsEnabled: true))
    }

    func testToggleAndSavedSettingsAreScopedToProfile() throws {
        var settings = LXProfileSettings()
        XCTAssertFalse(settings.geminiChainsEnabled)
        XCTAssertEqual(settings.resiliencePreset, "custom")
        settings.geminiChainsEnabled = true
        var store = LXOverridesStore()
        store.profiles["42"] = settings
        let reloaded = try LXOverridesStore.decode(store.encode())
        XCTAssertEqual(reloaded.profiles["42"]?.geminiChainsEnabled, true)
        let configured = try document(LXProfileOverrides.apply(source, profileID: 42, storedJSON: store.encode()))
        let untouched = try document(LXProfileOverrides.apply(source, profileID: 41, storedJSON: store.encode()))
        XCTAssertTrue(try outbounds(configured).contains {
            ($0["tag"] as? String) == "Gemini • Chain • A"
        })
        // No opt-in/out on profile 41: inheritance preserves the source
        // exactly, including its legacy Gemini • Chain • A group.
        // The client-generated LX chains must remain scoped to profile 42.
        XCTAssertEqual(try LXProfileOverrides.apply(source, profileID: 41, storedJSON: store.encode()), source)
        XCTAssertFalse(try outbounds(untouched).contains {
            ($0["tag"] as? String)?.hasPrefix("LX • Gemini • Chain • ") == true
        })
    }

    func testLegacyProfileWithoutGeminiPlusStaysUntouched() throws {
        let legacy = #"{"outbounds":[{"type":"selector","tag":"Gemini","outbounds":["direct"]},{"type":"direct","tag":"direct"}],"route":{"final":"Gemini"}}"#
        XCTAssertFalse(LXGeminiBuilder.hasSource(legacy))
        XCTAssertEqual(try LXProfileOverrides.apply(legacy, profileID: 42, storedJSON: ""), legacy)
        var settings = LXProfileSettings()
        settings.geminiChainsEnabled = true
        var store = LXOverridesStore()
        store.profiles["42"] = settings
        XCTAssertThrowsError(try LXProfileOverrides.apply(legacy, profileID: 42, storedJSON: store.encode()))
    }

    func testResiliencePresetsAreExplicitAndPreserveRoutingControls() {
        var settings = LXProfileSettings()
        settings.probeURLs = "https://probe.example.org/health"
        settings.urlTestDefault.mode = "failover"
        settings.geminiChainsEnabled = true

        settings.applyResiliencePreset("economy")
        XCTAssertEqual(settings.minHoldSeconds, 60)
        XCTAssertEqual(settings.adaptiveTolerancePercent, 0)
        XCTAssertFalse(settings.passiveGuardEnabled)

        settings.applyResiliencePreset("balance")
        XCTAssertEqual(settings.minHoldSeconds, 30)
        XCTAssertEqual(settings.adaptiveTolerancePercent, 20)
        XCTAssertFalse(settings.passiveGuardEnabled)

        settings.applyResiliencePreset("antiblock")
        XCTAssertEqual(settings.minHoldSeconds, 10)
        XCTAssertEqual(settings.adaptiveTolerancePercent, 35)
        XCTAssertTrue(settings.passiveGuardEnabled)
        XCTAssertEqual(settings.probeURLs, "https://probe.example.org/health")
        XCTAssertEqual(settings.urlTestDefault.mode, "failover")
        XCTAssertTrue(settings.geminiChainsEnabled)

        settings.applyResiliencePreset("custom")
        XCTAssertEqual(settings.minHoldSeconds, 10)
        XCTAssertTrue(settings.passiveGuardEnabled)
    }

    func testGeminiPlusNestedGroupsAreFlattenedAndDeduplicated() throws {
        var root = try document(source)
        var out = try outbounds(root)
        out.append(["type":"selector","tag":"Gemini subgroup",
                    "outbounds":["Swiss (Gemini)","Austria (Gemini)","Swiss (Gemini)"]])
        let index = try XCTUnwrap(out.firstIndex {
            ($0["tag"] as? String) == "Gemini+"
        })
        out[index]["outbounds"] = ["Gemini subgroup", "Swiss (Gemini)"]
        root["outbounds"] = out
        XCTAssertTrue(try LXGeminiBuilder.apply(to: &root, chainsEnabled: true))
        let built = try outbounds(root)
        XCTAssertEqual(
            try item("Gemini • Авто", in: built)["outbounds"] as? [String],
            ["Swiss (Gemini)", "Austria (Gemini)"]
        )
    }
}
