import XCTest
@testable import ApplicationLibrary

final class ModeRespondingNodeCounterTests: XCTestCase {
    func testCountsOnlyRespondingNodesAndNotGroups() {
        let groups = [
            ModeLatencyGroup(tag: "Авто · Базовая", members: [
                ModeLatencyItem(tag: "Пул A", delayMs: 147),
                ModeLatencyItem(tag: "живой", delayMs: 65),
                ModeLatencyItem(tag: "без ответа", delayMs: 0),
            ]),
            ModeLatencyGroup(tag: "Пул A", members: [
                ModeLatencyItem(tag: "другой", delayMs: 223),
                ModeLatencyItem(tag: "без ответа", delayMs: 0),
            ]),
        ]
        XCTAssertEqual(ModeRespondingNodeCounter.count(rootTag: "Авто · Базовая", groups: groups), 2)
    }

    func testUniqueNodesAcrossNestedGroupsAndCycles() {
        let groups = [
            ModeLatencyGroup(tag: "Ручной выбор", members: [
                ModeLatencyItem(tag: "Пул A", delayMs: 0),
                ModeLatencyItem(tag: "Пул B", delayMs: 0),
            ]),
            ModeLatencyGroup(tag: "Пул A", members: [
                ModeLatencyItem(tag: "узел 1", delayMs: 108),
                ModeLatencyItem(tag: "Пул B", delayMs: 0),
            ]),
            ModeLatencyGroup(tag: "Пул B", members: [
                ModeLatencyItem(tag: "узел 1", delayMs: 154),
                ModeLatencyItem(tag: "узел 2", delayMs: 300),
                ModeLatencyItem(tag: "Ручной выбор", delayMs: 0),
            ]),
        ]
        XCTAssertEqual(ModeRespondingNodeCounter.count(rootTag: "Ручной выбор", groups: groups), 2)
        XCTAssertEqual(ModeRespondingNodeCounter.count(rootTag: "неизвестно", groups: groups), 0)
    }

    func testZeroWhenNoSuccessfulTests() {
        let groups = [ModeLatencyGroup(tag: "Gemini", members: [
            ModeLatencyItem(tag: "vless 1", delayMs: 0),
            ModeLatencyItem(tag: "vless 2", delayMs: 0),
        ])]
        XCTAssertEqual(ModeRespondingNodeCounter.count(rootTag: "Gemini", groups: groups), 0)
    }
}
