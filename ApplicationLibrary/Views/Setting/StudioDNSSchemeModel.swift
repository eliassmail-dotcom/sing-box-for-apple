#if os(iOS)
import Foundation

/// A strictly read-only projection of repeatable DNS rule sequences.
///
/// An observed scheme is extracted only from a contiguous
/// evaluate(tag) -> respond(match_response: tag) -> ... -> route sequence
/// with identical DNS query conditions on evaluate/route entries.
/// Other rules stay in the original ordered DNS rule view.
///
/// This is deliberately NOT a compiler or a new runtime JSON object.
struct StudioDNSSchemeCatalog {
    struct Step: Identifiable {
        let index: Int
        let raw: [String: Any]
        var id: Int { index }
        var action: String { raw["action"] as? String ?? "route" }
        var server: String? { raw["server"] as? String }
        var timeout: String? { raw["timeout"] as? String }
        var responseTag: String? { raw["match_response"] as? String }
        var isRace: Bool { raw["race"] as? Bool == true }
        var isSpeculative: Bool { raw["speculative"] as? Bool == true }
    }

    struct Binding: Identifiable {
        let ruleIndexes: [Int]
        let conditions: [String: Any]
        var id: Int { ruleIndexes.first ?? -1 }
        var description: String {
            StudioDNSExplanation.conditionsDescription(conditions)
        }
    }

    struct Scheme: Identifiable {
        let id: String
        let title: String
        let template: [Step]
        var bindings: [Binding]

        var serversInOrder: [String] {
            template.compactMap(\.server)
        }

        var hasExplicitRace: Bool {
            template.contains { $0.isRace }
        }
    }

    let schemes: [Scheme]
    let ungroupedRuleIndexes: [Int]

    func linkedSchemes(forDNSRules ruleIndexes: [Int]) -> [Scheme] {
        let indexes = Set(ruleIndexes)
        guard !indexes.isEmpty else { return [] }
        return schemes.filter { scheme in
            scheme.bindings.contains { binding in
                !Set(binding.ruleIndexes).isDisjoint(with: indexes)
            }
        }
    }

    init(document: StudioDocument) {
        let dns = document.root["dns"] as? [String: Any] ?? [:]
        let rules = dns["rules"] as? [[String: Any]] ?? []
        var built: [Scheme] = []
        var fingerprints: [String: Int] = [:]
        var covered = Set<Int>()
        var cursor = 0

        while cursor < rules.count {
            let first = rules[cursor]
            guard Self.isNamedEvaluate(first) else {
                cursor += 1
                continue
            }
            let condition = Self.queryConditions(first)
            // A completely unqualified evaluate may be part of a global
            // response filter. Do not fabricate a fallback chain from it.
            guard !condition.isEmpty,
                  let conditionFingerprint = Self.canonical(condition) else {
                cursor += 1
                continue
            }

            var steps: [Step] = []
            var evaluateTags = Set<String>()
            var end: Int?
            var scan = cursor

            while scan < rules.count {
                let rule = rules[scan]
                let action = rule["action"] as? String ?? "route"
                if Self.isNamedEvaluate(rule),
                   Self.canonical(Self.queryConditions(rule)) == conditionFingerprint,
                   let tag = rule["tag"] as? String {
                    evaluateTags.insert(tag)
                    steps.append(Step(index: scan, raw: rule))
                } else if action == "respond",
                          let sourceTag = rule["match_response"] as? String,
                          evaluateTags.contains(sourceTag) {
                    steps.append(Step(index: scan, raw: rule))
                } else if action == "route",
                          rule["server"] as? String != nil,
                          Self.canonical(Self.queryConditions(rule)) == conditionFingerprint {
                    steps.append(Step(index: scan, raw: rule))
                    end = scan
                    break
                } else {
                    break
                }
                scan += 1
            }

            guard let end, steps.contains(where: { $0.action == "evaluate" }) else {
                cursor += 1
                continue
            }

            // An actual scheme is the operation pattern, not a domain filter.
            // Distinct address groups with the same DNS program reuse one
            // read-only scheme. Preserve individual original rule indices.
            let fingerprint = Self.operationFingerprint(steps)
            let binding = Binding(ruleIndexes: steps.map(\.index), conditions: condition)
            if let fingerprint, let existing = fingerprints[fingerprint] {
                built[existing].bindings.append(binding)
            } else {
                let number = built.count + 1
                let prefix = String(format: "%02d", number)
                let title = "DNS-схема \(prefix)"
                if let fingerprint { fingerprints[fingerprint] = built.count }
                built.append(Scheme(id: "observed-\(prefix)",
                                    title: title, template: steps,
                                    bindings: [binding]))
            }
            for step in steps { covered.insert(step.index) }
            cursor = end + 1
        }

        schemes = built
        ungroupedRuleIndexes = rules.indices.filter { !covered.contains($0) }
    }

    private static let executionFields: Set<String> = [
        "action", "server", "tag", "timeout", "race", "speculative"
    ]

    private static func queryConditions(_ raw: [String: Any]) -> [String: Any] {
        var result = raw.filter { !executionFields.contains($0.key) }
        // The string form references a preceding evaluate, and is NOT a
        // condition shared between address groups. The boolean form IS
        // an actual response-dependent matching condition.
        if result["match_response"] is String {
            result.removeValue(forKey: "match_response")
        }
        return result
    }

    private static func isNamedEvaluate(_ raw: [String: Any]) -> Bool {
        raw["action"] as? String == "evaluate"
            && (raw["server"] as? String)?.isEmpty == false
            && (raw["tag"] as? String)?.isEmpty == false
    }

    private static func operationFingerprint(_ steps: [Step]) -> String? {
        var tagIndexes: [String: Int] = [:]
        var canonicalSteps: [[String: Any]] = []
        for (position, step) in steps.enumerated() {
            var operation = step.raw
            if step.action == "evaluate" || step.action == "route" {
                for key in queryConditions(step.raw).keys {
                    operation.removeValue(forKey: key)
                }
            }
            if let tag = step.raw["tag"] as? String {
                tagIndexes[tag] = position
                operation["tag"] = "eval-\(position)"
            }
            if let ref = step.raw["match_response"] as? String,
               let source = tagIndexes[ref] {
                operation["match_response"] = "eval-\(source)"
            }
            canonicalSteps.append(operation)
        }
        return canonical(canonicalSteps)
    }

    private static func canonical(_ object: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(
                  withJSONObject: object, options: [.sortedKeys]
              ) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
#endif
