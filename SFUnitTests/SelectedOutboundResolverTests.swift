import XCTest
@testable import ApplicationLibrary

// gru: unit tests for the pure SelectedOutboundResolver (Dashboard TZ
// 14.11.2026, Stage 2). No Libbox/CommandClient involvement: the resolver is
// fed with a synthetic config graph + live group states.

final class SelectedOutboundResolverTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func live(_ tag: String, _ selected: String, type: String = "selector", delays: [String: UInt16] = [:]) -> OutboundLiveGroup {
        OutboundLiveGroup(tag: tag, ownType: type, selected: selected, itemDelays: delays, itemTimes: delays.isEmpty ? [:] : delays.mapValues { _ in now }, itemTypes: delays.isEmpty ? [:] : delays.mapValues { _ in "vless" })
    }

    // Стратегия → Пулы → Пул B → 🇩🇪 Германия
    private func corporateGraph() -> [OutboundConfigNode] {
        [
            OutboundConfigNode(tag: "Стратегия", type: "selector", members: ["Пулы", "Авто · Базовая", "Авто · Полная", "Ручной выбор", "Gemini-"], defaultMember: "Авто · Базовая"),
            OutboundConfigNode(tag: "Пулы", type: "selector", members: ["Пул A", "Пул B"], defaultMember: "Пул A"),
            OutboundConfigNode(tag: "Пул A", type: "urltest", members: ["🇫🇷 Франция"], defaultMember: "🇫🇷 Франция"),
            OutboundConfigNode(tag: "Пул B", type: "urltest", members: ["🇩🇪 Германия", "🇳🇱 Нидерланды"], defaultMember: "🇩🇪 Германия"),
            OutboundConfigNode(tag: "Авто · Базовая", type: "urltest", members: ["🇩🇪 Германия"], defaultMember: "🇩🇪 Германия"),
            OutboundConfigNode(tag: "Авто · Полная", type: "urltest", members: ["🇩🇪 Германия", "🇫🇷 Франция"], defaultMember: "🇩🇪 Германия"),
            OutboundConfigNode(tag: "Ручной выбор", type: "selector", members: ["🇩🇪 Германия", "🇫🇷 Франция"], defaultMember: "🇩🇪 Германия"),
            OutboundConfigNode(tag: "Gemini-", type: "urltest", members: ["🇩🇪 Германия", "🇫🇷 Франция"], defaultMember: "🇩🇪 Германия"),
            OutboundConfigNode(tag: "🇩🇪 Германия", type: "vless"),
            OutboundConfigNode(tag: "🇫🇷 Франция", type: "vless"),
            OutboundConfigNode(tag: "🇳🇱 Нидерланды", type: "vless"),
        ]
    }

    func testResolvesNestedGroupsToFinalNode() {
        let resolver = SelectedOutboundResolver(nodes: corporateGraph())
        let live = [
            live("Стратегия", "Пулы"),
            live("Пулы", "Пул B", type: "selector"),
            live("Пул B", "🇩🇪 Германия", type: "urltest", delays: ["🇩🇪 Германия": 127, "🇳🇱 Нидерланды": 210]),
        ]
        let result = resolver.resolve(rootTag: "Стратегия", live: live)
        XCTAssertEqual(result.status, .resolved)
        XCTAssertEqual(result.groupPath, ["Стратегия", "Пулы", "Пул B"])
        XCTAssertEqual(result.selectedTag, "🇩🇪 Германия")
        XCTAssertEqual(result.selectedType, "vless")
        XCTAssertEqual(result.chainHops, [])
        XCTAssertEqual(result.latencyMs, 127)
        XCTAssertEqual(result.latencyMeasuredAt, now)
    }

    func testGuestSingleAutoGroupResolves() {
        let resolver = SelectedOutboundResolver(nodes: [
            OutboundConfigNode(tag: "Стратегия", type: "selector", members: ["Пулы", "Авто", "Ручной выбор"], defaultMember: "Авто"),
            OutboundConfigNode(tag: "Авто", type: "urltest", members: ["🇩🇪 Германия", "🇫🇷 Франция"], defaultMember: "🇩🇪 Германия"),
            OutboundConfigNode(tag: "Ручной выбор", type: "selector", members: ["🇩🇪 Германия"], defaultMember: "🇩🇪 Германия"),
            OutboundConfigNode(tag: "🇩🇪 Германия", type: "vless"),
            OutboundConfigNode(tag: "🇫🇷 Франция", type: "vless"),
        ])
        let result = resolver.resolve(rootTag: "Стратегия", live: [live("Стратегия", "Авто"), live("Авто", "🇫🇷 Франция", type: "urltest", delays: ["🇫🇷 Франция": 143])])
        XCTAssertEqual(result.status, .resolved)
        XCTAssertEqual(result.groupPath, ["Стратегия", "Авто"])
        XCTAssertEqual(result.selectedTag, "🇫🇷 Франция")
        XCTAssertEqual(result.latencyMs, 143)
    }

    func testDetourChainResolvesEntryAndExit() {
        let resolver = SelectedOutboundResolver(nodes: [
            OutboundConfigNode(tag: "Gemini", type: "selector", members: ["Gemini • Super • A"], defaultMember: "Gemini • Super • A"),
            OutboundConfigNode(tag: "Gemini • Super • A", type: "selector", members: ["C • 🇦🇹 Австрия (Gemini)"], defaultMember: "C • 🇦🇹 Австрия (Gemini)"),
            OutboundConfigNode(tag: "Gemini-", type: "urltest", members: ["🇩🇪 Германия"], defaultMember: "🇩🇪 Германия"),
            OutboundConfigNode(tag: "🇩🇪 Германия", type: "vless"),
            OutboundConfigNode(tag: "C • 🇦🇹 Австрия (Gemini)", type: "vless", detour: "Gemini-"),
        ])
        let live = [
            live("Gemini", "Gemini • Super • A"),
            live("Gemini • Super • A", "C • 🇦🇹 Австрия (Gemini)", type: "selector"),
            live("Gemini-", "🇩🇪 Германия", type: "urltest", delays: ["🇩🇪 Германия": 95]),
        ]
        let result = resolver.resolve(rootTag: "Gemini", live: live)
        XCTAssertEqual(result.status, .resolved)
        XCTAssertEqual(result.selectedTag, "C • 🇦🇹 Австрия (Gemini)")
        // Packet order: the transport entry first, the chained exit last.
        XCTAssertEqual(result.chainHops, ["🇩🇪 Германия", "C • 🇦🇹 Австрия (Gemini)"])
        // Latency of the exit node only; never the transport group's value.
        XCTAssertNil(result.latencyMs)
    }

    func testUnresolvableDetourIsFlaggedIncomplete() {
        let resolver = SelectedOutboundResolver(nodes: [
            OutboundConfigNode(tag: "Gemini", type: "selector", members: ["C • exit"], defaultMember: "C • exit"),
            OutboundConfigNode(tag: "C • exit", type: "vless", detour: "Gemini-"),
        ])
        let result = resolver.resolve(rootTag: "Gemini", live: [live("Gemini", "C • exit")])
        XCTAssertEqual(result.status, .incomplete(.unresolvedChainHop("Gemini-")))
        XCTAssertEqual(result.selectedTag, "C • exit")
    }

    func testCycleDetection() {
        let resolver = SelectedOutboundResolver(nodes: [
            OutboundConfigNode(tag: "A", type: "selector", members: ["B"], defaultMember: "B"),
            OutboundConfigNode(tag: "B", type: "selector", members: ["A"], defaultMember: "A"),
        ])
        let result = resolver.resolve(rootTag: "A", live: [live("A", "B"), live("B", "A")])
        XCTAssertEqual(result.status, .incomplete(.cycle("A")))
        XCTAssertNil(result.selectedTag)
    }

    func testUnknownReference() {
        let resolver = SelectedOutboundResolver(nodes: [
            OutboundConfigNode(tag: "Стратегия", type: "selector", members: ["ghost"], defaultMember: "ghost"),
        ])
        let result = resolver.resolve(rootTag: "Стратегия", live: [live("Стратегия", "ghost")])
        XCTAssertEqual(result.status, .incomplete(.unknownReference("ghost")))
        XCTAssertEqual(result.selectedTag, "ghost")
    }

    func testRootMissing() {
        let resolver = SelectedOutboundResolver(nodes: corporateGraph())
        let result = resolver.resolve(rootTag: "Нет такой группы", live: [])
        XCTAssertEqual(result.status, .incomplete(.rootMissing))
    }

    func testNoLiveStateFallsBackToConfigDefault() {
        let resolver = SelectedOutboundResolver(nodes: corporateGraph())
        let result = resolver.resolve(rootTag: "Стратегия", live: [])
        // Стратегия → Авто · Базовая (default) → 🇩🇪 Германия (default)
        XCTAssertEqual(result.status, .resolved)
        XCTAssertEqual(result.groupPath, ["Стратегия", "Авто · Базовая"])
        XCTAssertEqual(result.selectedTag, "🇩🇪 Германия")
        XCTAssertNil(result.latencyMs)
    }

    func testNoSelectionAnywhere() {
        let resolver = SelectedOutboundResolver(nodes: [
            OutboundConfigNode(tag: "Пустая", type: "selector", members: []),
        ])
        let result = resolver.resolve(rootTag: "Пустая", live: [live("Пустая", "")])
        XCTAssertEqual(result.status, .incomplete(.noSelection("Пустая")))
    }

    func testParsesRunningConfigJSON() throws {
        let json = """
        {
          "outbounds": [
            { "tag": "Стратегия", "type": "selector", "outbounds": ["Авто · Полная", "Ручной выбор"], "default": "Авто · Полная" },
            { "tag": "Авто · Полная", "type": "urltest", "outbounds": ["🇩🇪 Германия"] },
            { "tag": "Ручной выбор", "type": "selector", "outbounds": ["🇩🇪 Германия"], "default": "🇩🇪 Германия" },
            { "tag": "Gemini-", "type": "urltest", "outbounds": ["🇩🇪 Германия"] },
            { "tag": "🇩🇪 Германия", "type": "vless" },
            { "tag": "C • exit", "type": "vless", "detour": "Gemini-" }
          ]
        }
        """
        let graph = try OutboundConfigGraph.parse(content: json)
        XCTAssertEqual(graph.count, 6)
        XCTAssertEqual(graph["Стратегия"]?.defaultMember, "Авто · Полная")
        XCTAssertEqual(graph["Авто · Полная"]?.members, ["🇩🇪 Германия"])
        XCTAssertEqual(graph["C • exit"]?.detour, "Gemini-")
        XCTAssertNil(graph["Авто · Полная"]?.defaultMember)

        let resolver = SelectedOutboundResolver(nodes: Array(graph.values))
        let result = resolver.resolve(rootTag: "Стратегия", live: [live("Стратегия", "Авто · Полная"), live("Авто · Полная", "🇩🇪 Германия", type: "urltest", delays: ["🇩🇪 Германия": 88])])
        XCTAssertEqual(result.status, .resolved)
        XCTAssertEqual(result.selectedTag, "🇩🇪 Германия")
        XCTAssertEqual(result.latencyMs, 88)
    }

    func testParseRejectsEmptyDocument() {
        XCTAssertThrowsError(try OutboundConfigGraph.parse(content: #"{"outbounds":[]}"#))
        XCTAssertThrowsError(try OutboundConfigGraph.parse(content: "not json"))
    }
}
