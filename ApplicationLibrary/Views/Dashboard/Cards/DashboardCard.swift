import Foundation
import SwiftUI

public enum DashboardCard: String, CaseIterable, Identifiable, Codable, Hashable {
    case status
    case connections
    case uploadTraffic
    case downloadTraffic
    case httpProxy
    case clashMode
    case currentRoutes
    case strategyMode
    case resilience
    case profile

    public var id: String {
        rawValue
    }

    public var title: LocalizedStringKey {
        switch self {
        case .status:
            return "Состояние"
        case .connections:
            return "Подключения"
        case .uploadTraffic:
            return "Отправлено"
        case .downloadTraffic:
            return "Получено"
        case .httpProxy:
            return "Системный HTTP-прокси"
        case .clashMode:
            return "Маршрутизация Google"
        case .currentRoutes:
            return "Текущие маршруты"
        case .strategyMode:
            return "Режимы подключения"
        case .resilience:
            return "Устойчивость"
        case .profile:
            return "Конфигурация"
        }
    }

    public var systemImage: String {
        switch self {
        case .status:
            return "info.circle.fill"
        case .connections:
            return "link.circle.fill"
        case .uploadTraffic:
            return "arrow.up.circle.fill"
        case .downloadTraffic:
            return "arrow.down.circle.fill"
        case .httpProxy:
            return "network"
        case .clashMode:
            return "circle.grid.2x2.fill"
        case .currentRoutes:
            return "network"
        case .strategyMode:
            return "wand.and.stars"
        case .resilience:
            return "shield.lefthalf.filled"
        case .profile:
            return "doc.text.fill"
        }
    }

    public var pairGroup: DashboardCardPairGroup? {
        switch self {
        case .uploadTraffic, .downloadTraffic:
            return .traffic
        case .status, .connections:
            return .statistics
        case .httpProxy, .clashMode, .currentRoutes, .strategyMode, .resilience, .profile:
            return nil
        }
    }

    public static func groupIntoRows(_ cards: [DashboardCard]) -> [[DashboardCard]] {
        var rows: [[DashboardCard]] = []
        var index = 0
        while index < cards.count {
            let card = cards[index]
            if let pairGroup = card.pairGroup, index + 1 < cards.count, cards[index + 1].pairGroup == pairGroup {
                rows.append([card, cards[index + 1]])
                index += 2
            } else {
                rows.append([card])
                index += 1
            }
        }
        return rows
    }

    public static var defaultCards: [DashboardCard] {
        allCases
    }

    public static var defaultOrder: [DashboardCard] {
        [.currentRoutes, .strategyMode, .resilience, .clashMode, .uploadTraffic, .downloadTraffic, .status, .connections, .httpProxy, .profile]
    }
}

public enum DashboardCardPairGroup {
    case traffic
    case statistics
}
