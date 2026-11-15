import XCTest
@testable import ApplicationLibrary

/// Dashboard migration relies on stable card IDs, not on SwiftUI view order.
final class ResilienceDashboardCardTests: XCTestCase {
    func testResilienceIsIndependentCardImmediatelyAfterStrategyByDefault() {
        let cards = DashboardCard.defaultOrder
        guard let modeIndex = cards.firstIndex(of: .strategyMode) else {
            return XCTFail("Strategy card missing from Dashboard")
        }
        XCTAssertEqual(cards[modeIndex + 1], .resilience)
        XCTAssertTrue(DashboardCard.allCases.contains(.resilience))
        XCTAssertNotEqual(DashboardCard.resilience.rawValue, DashboardCard.strategyMode.rawValue)
    }

    func testResilienceIsNotPairedWithTrafficOrStatusWidgets() {
        XCTAssertNil(DashboardCard.resilience.pairGroup)
        XCTAssertTrue(DashboardCard.groupIntoRows([.strategyMode, .resilience]).allSatisfy {
            $0.count == 1
        })
    }

    func testCardNameSurvivesPersistence() {
        let stored = DashboardCard.resilience.rawValue
        XCTAssertEqual(DashboardCard(rawValue: stored), .resilience)
    }
}
