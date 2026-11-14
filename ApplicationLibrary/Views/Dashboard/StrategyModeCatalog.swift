import Foundation

// gru: pure mapping between the four dashboard mode switches and the actual
// selector tags of the generated profile (Dashboard TZ 14.11.2026, stage 4).
// Candidate lists cover both production and pending generator names:
// «Авто · Белые» is the v1.4.46-lx rename of «Авто · Только белые»; guest
// profiles expose the single «Авто» (a rename of the Базовая clone) and their
// Gemini group has no «Gemini • Super • A», so auto modes fall back to
// «Gemini • Авто». Kept free of SwiftUI so the mode/tag correspondence is
// unit-testable.

public struct StrategyModeSpec: Hashable, Identifiable {
    public let title: String
    public let strategyCandidates: [String]
    public let geminiCandidates: [String]

    public init(title: String, strategyCandidates: [String], geminiCandidates: [String]) {
        self.title = title
        self.strategyCandidates = strategyCandidates
        self.geminiCandidates = geminiCandidates
    }

    public var id: String { title }
}

public enum StrategyModeCatalog {
    public static let strategyGroupTag = "Стратегия"
    public static let geminiGroupTag = "Gemini"

    public static let modes: [StrategyModeSpec] = [
        StrategyModeSpec(
            title: "Авто • Базовая",
            strategyCandidates: ["Авто · Базовая", "Авто"],
            geminiCandidates: ["Gemini • Super • A", "Gemini • Авто"]
        ),
        StrategyModeSpec(
            title: "Авто • Белые",
            strategyCandidates: ["Авто · Белые", "Авто · Только белые"],
            geminiCandidates: ["Gemini • Super • A", "Gemini • Авто"]
        ),
        StrategyModeSpec(
            title: "Авто • Полная",
            strategyCandidates: ["Авто · Полная"],
            geminiCandidates: ["Gemini • Super • A", "Gemini • Авто"]
        ),
        StrategyModeSpec(
            title: "Ручной режим",
            strategyCandidates: ["Ручной выбор"],
            geminiCandidates: ["Gemini • Выбор"]
        ),
    ]

    /// The outbound the mode would actually select inside «Стратегия» for the
    /// given group membership, or nil when the profile lacks the group.
    public static func strategyTarget(_ mode: StrategyModeSpec, strategyTags: [String]) -> String? {
        mode.strategyCandidates.first { strategyTags.contains($0) }
    }

    public static func geminiTarget(_ mode: StrategyModeSpec, geminiTags: [String]?) -> String? {
        guard let geminiTags else { return nil }
        return mode.geminiCandidates.first { geminiTags.contains($0) }
    }

    public static func isAvailable(_ mode: StrategyModeSpec, strategyTags: [String], geminiTags: [String]?) -> Bool {
        guard strategyTarget(mode, strategyTags: strategyTags) != nil else { return false }
        if let geminiTags {
            return geminiTarget(mode, geminiTags: geminiTags) != nil
        }
        return true
    }

    /// The single mode matching the live selector state of both groups, or
    /// nil when the configuration is mixed / manually changed.
    public static func activeMode(strategySelected: String, geminiSelected: String?, strategyTags: [String], geminiTags: [String]?) -> StrategyModeSpec? {
        modes.first { mode in
            guard mode.strategyCandidates.contains(strategySelected) else { return false }
            if let geminiTags, let geminiSelected {
                return mode.geminiCandidates.contains(geminiSelected)
            }
            return true
        }
    }
}
