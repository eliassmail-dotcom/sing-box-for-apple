import XCTest
import Library
@testable import ApplicationLibrary

// gru: unit tests for the mode ↔ selector-tag correspondence (Dashboard TZ
// 14.11.2026, stage 4). Fixtures mirror the actual v1.4.46 generator output
// per profile variant.

final class StrategyModeCatalogTests: XCTestCase {
    // Corporate / CD / Personal: production names (pre-rename).
    private let corporateStrategy = ["Пулы", "Авто · Базовая", "Авто · Полная", "Авто · Только белые", "Ручной выбор"]
    private let corporateGemini = ["Gemini • Авто", "Gemini • Выбор", "Gemini • Chain • A", "Gemini • Chain • M", "Gemini • Super • A"]

    // After the v1.4.46-lx rename deploys.
    private let renamedStrategy = ["Пулы", "Авто · Базовая", "Авто · Полная", "Авто · Белые", "Ручной выбор"]

    // Guest: single «Авто» (rename of the Базовая clone), no Super-A.
    private let guestStrategy = ["Пулы", "Авто", "Ручной выбор"]
    private let guestGemini = ["Gemini • Авто", "Gemini • Выбор", "Gemini • Chain • A", "Gemini • Chain • M"]

    // NB: whitelist group removed.
    private let nbStrategy = ["Пулы", "Авто · Базовая", "Авто · Полная", "Ручной выбор"]

    func testAllModesAvailableInCorporateProfile() {
        for mode in StrategyModeCatalog.modes where mode.title != "Авто • Умный" {
            XCTAssertTrue(StrategyModeCatalog.isAvailable(mode, strategyTags: corporateStrategy, geminiTags: corporateGemini), mode.title)
        }
        XCTAssertEqual(StrategyModeCatalog.strategyTarget(StrategyModeCatalog.modes[0], strategyTags: corporateStrategy), "Авто · Базовая")
        XCTAssertEqual(StrategyModeCatalog.strategyTarget(StrategyModeCatalog.modes[1], strategyTags: corporateStrategy), "Авто · Только белые")
        XCTAssertEqual(StrategyModeCatalog.strategyTarget(StrategyModeCatalog.modes[2], strategyTags: corporateStrategy), "Авто · Полная")
        XCTAssertEqual(StrategyModeCatalog.strategyTarget(StrategyModeCatalog.modes[3], strategyTags: corporateStrategy), "Ручной выбор")
        // User decision: auto modes prefer Super-A for Gemini.
        XCTAssertEqual(StrategyModeCatalog.geminiTarget(StrategyModeCatalog.modes[0], geminiTags: corporateGemini), "Gemini • Super • A")
        XCTAssertEqual(StrategyModeCatalog.geminiTarget(StrategyModeCatalog.modes[3], geminiTags: corporateGemini), "Gemini • Выбор")
    }

    func testOptionalPriorityStrategy() {
        let mode = try! XCTUnwrap(StrategyModeCatalog.modes.first { $0.title == "Авто • Умный" })
        XCTAssertFalse(StrategyModeCatalog.isAvailable(mode, strategyTags: corporateStrategy, geminiTags: corporateGemini))
        let withPriority = corporateStrategy + ["Авто · База → Белые"]
        XCTAssertTrue(StrategyModeCatalog.isAvailable(mode, strategyTags: withPriority, geminiTags: corporateGemini))
        XCTAssertEqual(StrategyModeCatalog.strategyTarget(mode, strategyTags: withPriority), "Авто · База → Белые")
        XCTAssertEqual(StrategyModeCatalog.activeMode(strategySelected: "Авто · База → Белые", geminiSelected: "Gemini • Super • A", strategyTags: withPriority, geminiTags: corporateGemini)?.title, "Авто • Умный")
    }

    func testRenamedWhiteGroupMatchesBothNames() {
        XCTAssertEqual(StrategyModeCatalog.strategyTarget(StrategyModeCatalog.modes[1], strategyTags: renamedStrategy), "Авто · Белые")
        XCTAssertEqual(StrategyModeCatalog.strategyTarget(StrategyModeCatalog.modes[1], strategyTags: corporateStrategy), "Авто · Только белые")
    }

    func testGuestMapsBasicToSingleAutoAndFallsBackGemini() {
        let basic = StrategyModeCatalog.modes[0]
        XCTAssertTrue(StrategyModeCatalog.isAvailable(basic, strategyTags: guestStrategy, geminiTags: guestGemini))
        XCTAssertEqual(StrategyModeCatalog.strategyTarget(basic, strategyTags: guestStrategy), "Авто")
        // Guest has no Super-A: auto modes fall back to Gemini • Авто.
        XCTAssertEqual(StrategyModeCatalog.geminiTarget(basic, geminiTags: guestGemini), "Gemini • Авто")
        for mode in [StrategyModeCatalog.modes[1], StrategyModeCatalog.modes[2]] {
            XCTAssertFalse(StrategyModeCatalog.isAvailable(mode, strategyTags: guestStrategy, geminiTags: guestGemini), mode.title)
        }
        XCTAssertTrue(StrategyModeCatalog.isAvailable(StrategyModeCatalog.modes[3], strategyTags: guestStrategy, geminiTags: guestGemini))
    }

    func testNBHasNoWhiteGroup() {
        XCTAssertFalse(StrategyModeCatalog.isAvailable(StrategyModeCatalog.modes[1], strategyTags: nbStrategy, geminiTags: corporateGemini))
        XCTAssertTrue(StrategyModeCatalog.isAvailable(StrategyModeCatalog.modes[0], strategyTags: nbStrategy, geminiTags: corporateGemini))
    }

    func testActiveModeDetection() {
        func active(_ strategy: String, _ gemini: String, strategyTags: [String] = corporateStrategy, geminiTags: [String] = corporateGemini) -> String? {
            StrategyModeCatalog.activeMode(strategySelected: strategy, geminiSelected: gemini, strategyTags: strategyTags, geminiTags: geminiTags)?.title
        }
        XCTAssertEqual(active("Авто · Базовая", "Gemini • Super • A"), "Авто • Базовая")
        XCTAssertEqual(active("Авто · Только белые", "Gemini • Super • A"), "Авто • Белые")
        XCTAssertEqual(active("Авто · Полная", "Gemini • Авто"), "Авто • Полная")
        XCTAssertEqual(active("Ручной выбор", "Gemini • Выбор"), "Ручной режим")
        // Mixed: groups point at different modes.
        XCTAssertNil(active("Авто · Базовая", "Gemini • Выбор"))
        XCTAssertNil(active("Пулы", "Gemini • Super • A"))
        // Guest: Базовая via «Авто» + Gemini fallback.
        XCTAssertEqual(active("Авто", "Gemini • Авто", strategyTags: guestStrategy, geminiTags: guestGemini), "Авто • Базовая")
        XCTAssertNil(active("Авто", "Gemini • Chain • A", strategyTags: guestStrategy, geminiTags: guestGemini))
    }

    func testNoGeminiGroupTolerated() {
        // A profile without the Gemini selector: modes resolve by Strategy alone.
        let basic = StrategyModeCatalog.modes[0]
        XCTAssertTrue(StrategyModeCatalog.isAvailable(basic, strategyTags: corporateStrategy, geminiTags: nil))
        XCTAssertNil(StrategyModeCatalog.geminiTarget(basic, geminiTags: nil))
        XCTAssertEqual(
            StrategyModeCatalog.activeMode(strategySelected: "Ручной выбор", geminiSelected: nil, strategyTags: corporateStrategy, geminiTags: nil)?.title,
            "Ручной режим"
        )
    }
    func testActiveModeManualNextNodeCyclesAmongHealthyCandidates() {
        let candidates: [(tag: String, delayMs: UInt16)] = [
            ("a", 120), ("dead", 0), ("b", 70), ("c", 85)
        ]
        XCTAssertEqual(
            StrategyNodeChange.nextHealthyManualTag(current: "a", candidates: candidates),
            "b"
        )
        XCTAssertEqual(
            StrategyNodeChange.nextHealthyManualTag(current: "b", candidates: candidates),
            "c"
        )
        XCTAssertEqual(
            StrategyNodeChange.nextHealthyManualTag(current: "c", candidates: candidates),
            "a"
        )
        XCTAssertEqual(
            StrategyNodeChange.nextHealthyManualTag(current: "dead", candidates: candidates),
            "a"
        )
    }

    func testActiveModeNoHealthyAlternativeDoesNotSelectSameNode() {
        XCTAssertNil(StrategyNodeChange.nextHealthyManualTag(
            current: "a", candidates: [("a", 100)]
        ))
        XCTAssertNil(StrategyNodeChange.nextHealthyManualTag(
            current: "a", candidates: [("a", 100), ("b", 0)]
        ))
        XCTAssertEqual(StrategyNodeChange.nextHealthyManualTag(
            current: "dead", candidates: [("a", 100), ("dead", 0)]
        ), "a")
        XCTAssertNil(StrategyNodeChange.nextHealthyManualTag(
            current: "dead", candidates: [("a", 0), ("dead", 0)]
        ))
    }

    func testControlCenterUsesSameHealthyManualCycleAsDashboard() {
        let candidates: [(tag: String, delayMs: UInt16)] = [
            ("a", 90), ("dead", 0), ("a", 90), ("b", 110), ("c", 150)
        ]
        // Duplicate leaf tags must never count as two different nodes.
        XCTAssertEqual(
            LXNextNodeSelection.nextHealthyTag(current: "a", candidates: candidates),
            "b"
        )
        XCTAssertEqual(
            LXNextNodeSelection.nextHealthyTag(current: "b", candidates: candidates),
            "c"
        )
        XCTAssertEqual(
            LXNextNodeSelection.nextHealthyTag(current: "c", candidates: candidates),
            "a"
        )
        XCTAssertNil(
            LXNextNodeSelection.nextHealthyTag(
                current: "only", candidates: [("only", 40), ("down", 0)]
            )
        )
        XCTAssertEqual(
            LXNextNodeSelection.commandTag, StrategyNodeChange.nextNodeCommand
        )
        XCTAssertEqual(LXNextNodeSelection.strategyGroupTag, "Стратегия")
    }

}
