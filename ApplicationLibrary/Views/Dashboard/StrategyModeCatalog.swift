import Foundation
import Library

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

// UI-only choice for a selector-backed Manual mode. Automatic URLTest modes
// use the LX core command below and never change the top-level Strategy tag.
public enum StrategyNodeChange {
    // SelectOutbound RPC's reserved LX URLTest command. Must match the core's
    // group.LXNextNodeTag; no protobuf change or subscription edit is needed.
    public static let nextNodeCommand = LXNextNodeSelection.commandTag

    public static func nextHealthyManualTag(
        current: String,
        candidates: [(tag: String, delayMs: UInt16)]
    ) -> String? {
        LXNextNodeSelection.nextHealthyTag(current: current, candidates: candidates)
    }
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
        StrategyModeSpec(
            title: "Авто • 🔗 Цепочки",
            strategyCandidates: ["Ru 🔗 Авто"],
            geminiCandidates: ["Gemini • Super • A", "Gemini • Авто"]
        ),
        StrategyModeSpec(
            title: "Авто • Умный",
            strategyCandidates: ["Авто · Умный", "Авто · База → Белые"],
            geminiCandidates: ["Gemini • Super • A", "Gemini • Авто"]
        ),
    ]

    /// The outbound the mode would actually select inside «Стратегия» for the
    /// given group membership, or nil when the profile lacks the group.
    // Smart is a flat URLTest pool. Its selection is usually a leaf, not
    // the source URLTest tag. Resolve membership in the same priority order
    // as the generated pool, including legacy nested URLTest profiles.
    public static func smartTier(selected: String, tiers: [String], members: [String: [String]]) -> String? {
        guard !selected.isEmpty else { return nil }
        // Explicit nested group selection takes precedence over leaf lookup.
        if tiers.contains(selected) { return selected }
        for tier in tiers {
            var pending = [tier]
            var visited = Set<String>()
            while let tag = pending.popLast() {
                guard visited.insert(tag).inserted else { continue }
                if tag == selected { return tier }
                pending.append(contentsOf: members[tag] ?? [])
            }
        }
        return nil
    }

    public static func strategyTarget(_ mode: StrategyModeSpec, strategyTags: [String]) -> String? {
        mode.strategyCandidates.first { strategyTags.contains($0) }
    }

    public static func geminiTarget(_ mode: StrategyModeSpec, geminiTags: [String]?) -> String? {
        guard let geminiTags else { return nil }
        return mode.geminiCandidates.first { geminiTags.contains($0) }
    }

    public static func isAvailable(_ mode: StrategyModeSpec, strategyTags: [String], geminiTags: [String]?) -> Bool {
        // Availability belongs to the main Strategy selector. Gemini may
        // be absent, have a manual selection, or expose different groups.
        strategyTarget(mode, strategyTags: strategyTags) != nil
    }

    /// Match the live main Strategy selector only. A manual Gemini selection
    /// must not clear the active tile or turn a node-rotation tap into a mode
    /// change that would overwrite the user's Gemini selection.
    public static func activeMode(strategySelected: String, geminiSelected: String?, strategyTags: [String], geminiTags: [String]?) -> StrategyModeSpec? {
        modes.first { mode in
            mode.strategyCandidates.contains(strategySelected)
        }
    }
}
