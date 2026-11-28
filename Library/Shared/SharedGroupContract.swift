import Foundation

/// The same source is compiled into Library, File Provider and Widget. Resolve
/// signing intent against the installed bundle tree before consulting the local sandbox.
enum SharedGroupContract {
    enum Role: String, CaseIterable {
        case app = "APP", tunnel = "TUNNEL", files = "FILEPROVIDER", widget = "WIDGET"
        case intents = "INTENTS", share = "SHARE", action = "ACTION"

        init?(extensionPoint: String) {
            switch extensionPoint {
            case "com.apple.networkextension.packet-tunnel": self = .tunnel
            case "com.apple.fileprovider-nonui": self = .files
            case "com.apple.widgetkit-extension": self = .widget
            case "com.apple.appintents-extension": self = .intents
            case "com.apple.share-services": self = .share
            case "com.apple.ui-services": self = .action
            default: return nil
            }
        }
    }

    struct Member {
        let role: Role
        let bundleID: String
        let declared: String?
        let documentGroup: String?
        let groups: Set<String>
        let source: String
    }

    struct Decision {
        let group: String?
        let reason: String
        let candidates: Set<String>
    }

    static func decide(_ members: [Member]) -> Decision {
        for role in Role.allCases {
            let matches = members.filter { $0.role == role }
            guard matches.count == 1 else {
                return Decision(group: nil, reason: "bundleCount.\(role.rawValue).\(matches.count)", candidates: [])
            }
            guard !matches[0].groups.isEmpty else {
                return Decision(group: nil, reason: "noSignedGroup.\(role.rawValue)", candidates: [])
            }
        }
        let common = members.dropFirst().reduce(members[0].groups) { $0.intersection($1.groups) }
        guard !common.isEmpty else { return Decision(group: nil, reason: "noCommonEntitlement", candidates: []) }
        if common.count == 1 {
            return Decision(group: common.first, reason: "onlyCommonEntitlement", candidates: common)
        }
        // A signer may rewrite the standard File Provider key while custom plist
        // keys stay stale. Conflicting *authorized* declarations are never guessed.
        let declarations = Set(members.compactMap(\.declared) + members.compactMap(\.documentGroup))
        let valid = common.intersection(declarations)
        if valid.count == 1 {
            return Decision(group: valid.first, reason: "authorizedDeclaration", candidates: common)
        }
        return Decision(group: nil, reason: valid.isEmpty ? "ambiguousNoMapping" : "conflictingDeclarations", candidates: common)
    }

    static func extensionPoint(_ info: [String: Any]) -> String? {
        let legacy = info["NSExtension"] as? [String: Any]
        let modern = info["EXAppExtensionAttributes"] as? [String: Any]
        return (legacy?["NSExtensionPointIdentifier"] ?? modern?["EXExtensionPointIdentifier"]) as? String
    }

    private static func inspect(_ bundle: Bundle, role: Role) -> Member {
        let info = bundle.infoDictionary ?? [:]
        let ext = info["NSExtension"] as? [String: Any]
        let sources = SignedEntitlements.sourceDiagnostics(of: bundle)
        let read = SignedEntitlements.stringArrayResult("com.apple.security.application-groups", of: bundle)
        let groups: Set<String>
        let state: String
        switch read {
        case .present(let names):
            // XML/DER disagreement is not evidence that a peer has these rights.
            groups = sources.xmlDERMatch == .mismatch ? [] : Set(names.filter { $0.hasPrefix("group.") && !$0.contains("*") })
            state = "present"
        case .absentKey: groups = []; state = "absent"
        case .emptyValue: groups = []; state = "empty"
        case .unexpectedType: groups = []; state = "wrongType"
        case .unknown: groups = []; state = "unreadable"
        }
        return Member(role: role, bundleID: bundle.bundleIdentifier ?? "unknown",
                      declared: info["AppGroupIdentifier"] as? String,
                      documentGroup: role == .files ? ext?["NSExtensionFileProviderDocumentGroup"] as? String : nil,
                      groups: groups, source: "\(state)/xml:\(sources.xmlStatus.rawValue)/der:\(sources.derStatus.rawValue)/\(sources.xmlDERMatch.rawValue)")
    }

    static let members: [Member] = {
        var root = Bundle.main.bundleURL
        while root.pathExtension != "app" {
            let parent = root.deletingLastPathComponent()
            guard parent.path != root.path else { return [] }
            root = parent
        }
        guard let host = Bundle(url: root) else { return [] }
        var members = [inspect(host, role: .app)]
        // App Intents uses ExtensionKit's Extensions/, the others use PlugIns/.
        for directory in ["PlugIns", "Extensions"] {
            let urls = (try? FileManager.default.contentsOfDirectory(at: root.appendingPathComponent(directory),
                                                                     includingPropertiesForKeys: nil)) ?? []
            for url in urls where url.pathExtension == "appex" {
                guard let bundle = Bundle(url: url), let point = extensionPoint(bundle.infoDictionary ?? [:]),
                      let role = Role(extensionPoint: point) else { continue }
                members.append(inspect(bundle, role: role))
            }
        }
        return members.sorted { $0.role.rawValue < $1.role.rawValue }
    }()

    static let decision = decide(members)
    static func open(_ decision: Decision, lookup: (String) -> URL?) -> URL? { decision.group.flatMap(lookup) }
    static let container = open(decision) { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) }
    static let resolved = container == nil ? nil : decision.group
    static let documentGroup = members.first { $0.role == .files }?.documentGroup
    static var filesReady: Bool { resolved != nil && resolved == documentGroup }

    static var observation: String {
        "selected=\(decision.group ?? "none") resolved=\(resolved ?? "none") reason=\(decision.reason) localContainer=\(container != nil) documentGroup=\(documentGroup ?? "none") filesReady=\(filesReady)"
    }

    static var inventory: [String] {
        ["common=\(decision.candidates.sorted().joined(separator: ","))"] + members.map {
            "installed role=\($0.role.rawValue) bundle=\($0.bundleID) signed=\($0.groups.sorted().joined(separator: ",")) declared=\($0.declared ?? "none") signature=\($0.source)"
        }
    }

    static func recordAccess() {
        DiagnosticsLog.configureSharedDirectory(container)
        DiagnosticsLog.record("appgroup.access", result: container != nil ? .pass : .fail, details: observation)
    }
}
