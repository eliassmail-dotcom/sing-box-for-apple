import Foundation

public enum AppConfiguration {
    public static let packageName: String = {
        // Prefer the actual runtime bundle identifier: re-signing tools rename
        // bundle identifiers to match the signing profile, while the custom
        // Info.plist placeholders below keep their build-time values.
        if let id = resolvedHostBundleID, !id.isEmpty {
            return id
        }
        // GBox may rewrite/remove custom Info.plist values.
        return Bundle.main.object(forInfoDictionaryKey: "BasePackageIdentifier") as? String
            ?? Bundle.main.bundleIdentifier
            ?? "sing-box"
    }()

    public static let appGroupID: String = {
        // Prefer an app group this binary is actually entitled to: re-signing
        // tools rewrite entitlements to groups available in the signing profile.
        if let id = resolvedAppGroupID {
            return id
        }
        // Do not advertise an unverified build-time group as usable.
        // When no shared group is accessible, FilePath uses process-local storage.
        return ""
    }()

    /// Team ID is a signing entitlement, NEVER the prefix of an App Group.
    public static var teamID: String {
        let entitlements = hostBundle.flatMap { SignedEntitlements.load(of: $0) }
        if let team = entitlements?["com.apple.developer.team-identifier"] as? String, !team.isEmpty {
            return team
        }
        if let appIdentifier = entitlements?["application-identifier"] as? String,
           let dot = appIdentifier.firstIndex(of: ".") {
            return String(appIdentifier[..<dot])
        }
        return ""
    }

    public static var extensionBundleID: String {
        // Actual identifier of the packet-tunnel extension, following any
        // re-signing rename; falls back to the conventional suffix.
        if let id = resolvedExtensionBundleID {
            return id
        }
        return "\(packageName).extension"
    }

    public static var systemExtensionBundleID: String {
        "\(packageName).system"
    }

    #if os(macOS)
        /// After a system-extension replace, launchd keeps the previous version's per-version provider job
        /// registered and still owning the NEMachServiceName endpoint; it refuses to let the new version
        /// reclaim a fixed endpoint name, so the app reaches the dead old listener. The version suffix gives
        /// each build its own endpoint. Must equal NEMachServiceName in SystemExtension/Info.plist, which is
        /// baked from $(APP_GROUP_IDENTIFIER).system.$(MARKETING_VERSION); Bundle.version is that same value.
        public static var systemExtensionMachServiceName: String {
            "\(appGroupID).system.\(Bundle.main.version)"
        }
    #endif

    public static var packetTunnelBundleIDs: [String] {
        if extensionBundleID == systemExtensionBundleID {
            return [extensionBundleID]
        }
        return [extensionBundleID, systemExtensionBundleID]
    }

    public static var fileProviderDomainID: String {
        "\(packageName).workingdir"
    }

    public static var widgetControlKind: String {
        "\(packageName).widget.ServiceToggle"
    }

    public static var profileUTType: String {
        // Re-signing may change CFBundleIdentifier but not registered UTI declarations.
        // The actual plist registration is authoritative for document import.
        let items = hostBundle?.object(forInfoDictionaryKey: "UTExportedTypeDeclarations") as? [[String: Any]]
        if let identifier = items?.compactMap({ $0["UTTypeIdentifier"] as? String }).first,
           !identifier.isEmpty {
            return identifier
        }
        return "\(packageName).profile"
    }

    public static var backgroundTaskID: String {
        // Must match the Info.plist BGTaskSchedulerPermittedIdentifiers entry
        // exactly. Re-signing tools rename the bundle identifier but leave this
        // key untouched, so deriving it from packageName would desync from the
        // plist after re-signing; read the actual plist value instead.
        if let items = Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String],
           let first = items.first, !first.isEmpty {
            return first
        }
        return "\(packageName).update_profiles"
    }

    public static var iCloudContainerID: String {
        // iCloud container IDs are also provisioned at signing time.
        // Prefer the original registered value; do not derive an unprovisioned one.
        if let containers = hostBundle?.object(forInfoDictionaryKey: "NSUbiquitousContainers") as? [String: Any],
           let registered = containers.keys.sorted().first {
            return registered
        }
        return "iCloud.\(packageName)"
    }

    #if os(macOS) || JAILBREAK
        public static var rootHelperBundleID: String {
            "\(packageName).helper"
        }

        public static var rootHelperMachService: String {
            "\(appGroupID).helper"
        }
    #endif

    // MARK: - Runtime identifier resolution
    //
    // Re-signing tools (GBox, ESign, SideStore, ...) rewrite CFBundleIdentifier and
    // entitlements to match the signing certificate's provisioning profile, but leave
    // custom Info.plist keys untouched. The resolvers below prefer the actual signed
    // values so the app keeps working no matter which certificate signed it.

    /// Bundle of the host application. Valid in both the app process and
    /// extension processes (extensions live inside <Host>.app/PlugIns/*.appex).
    private static let hostBundle: Bundle? = {
        let bundle = Bundle.main
        if bundle.bundleURL.pathExtension == "appex" {
            var url = bundle.bundleURL
            while url.pathComponents.count > 1 {
                url = url.deletingLastPathComponent()
                if url.pathExtension == "app" {
                    return Bundle(url: url)
                }
            }
            return nil
        }
        return bundle
    }()

    /// Bundle of the embedded packet-tunnel extension, discovered from the app
    /// bundle contents instead of assuming the ".extension" suffix. In the
    /// extension process itself this is Bundle.main.
    private static let packetTunnelBundle: Bundle? = {
        let current = Bundle.main
        if current.bundleURL.pathExtension == "appex",
           let info = current.infoDictionary,
           let ext = info["NSExtension"] as? [String: Any],
           ext["NSExtensionPointIdentifier"] as? String == "com.apple.networkextension.packet-tunnel" {
            return current
        }
        guard let plugins = hostBundle?.builtInPlugInsURL,
              let items = try? FileManager.default.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil) else {
            return nil
        }
        for item in items where item.pathExtension == "appex" {
            guard let bundle = Bundle(url: item),
                  let ext = bundle.infoDictionary?["NSExtension"] as? [String: Any],
                  ext["NSExtensionPointIdentifier"] as? String == "com.apple.networkextension.packet-tunnel" else {
                continue
            }
            return bundle
        }
        return nil
    }()

    /// The peer binary for app-group negotiation: the packet-tunnel extension
    /// when running in the app process, the host app when running in an
    /// extension process. The main app and the tunnel must agree on the same
    /// group, and their signatures may come from different profiles, so each
    /// side intersects its own groups with the peer's.
    private static let peerBundle: Bundle? = {
        if Bundle.main.bundleURL.pathExtension == "appex" {
            return hostBundle
        }
        return packetTunnelBundle
    }()

    private static let resolvedHostBundleID: String? = hostBundle?.bundleIdentifier

    private static let resolvedExtensionBundleID: String? = packetTunnelBundle?.bundleIdentifier

    /// Builds an ordered set of candidate group identifiers. XML entitlements
    /// are only one way to discover names: some re-signers produce DER-only
    /// code signatures. A candidate still MUST open as a real iOS App Group
    /// container in the current process before it can be selected.
    ///
    /// When both signed sets are readable, a mismatch is authoritative and
    /// must not be papered over with unsigned Info.plist placeholders.
    public static func candidateAppGroups(
        ownSigned: [String],
        peerSigned: [String],
        hostConfigured: String?,
        tunnelConfigured: String?,
        hostProvisioned: [String] = [],
        tunnelProvisioned: [String] = []
    ) -> [String] {
        let own = Set(ownSigned.filter { !$0.isEmpty })
        let peer = Set(peerSigned.filter { !$0.isEmpty })
        if !own.isEmpty && !peer.isEmpty {
            return own.intersection(peer).sorted()
        }
        if !own.isEmpty { return own.sorted() }
        if !peer.isEmpty { return peer.sorted() }

        // DER-only signatures do not give us XML names. Discover candidate
        // names from the two embedded provisioning profiles, when available.
        // This does not grant any rights: containerURL remains the gate.
        let hostNames = Set(hostProvisioned)
        let tunnelNames = Set(tunnelProvisioned)
        if !hostNames.isEmpty && !tunnelNames.isEmpty {
            return hostNames.intersection(tunnelNames).sorted()
        }
        if !hostNames.isEmpty { return hostNames.sorted() }
        if !tunnelNames.isEmpty { return tunnelNames.sorted() }

        // No readable signing metadata. Try a common declared group only,
        // rather than manufacture an identifier from the signing Team ID.
        guard let hostConfigured, !hostConfigured.isEmpty,
              let tunnelConfigured, hostConfigured == tunnelConfigured else {
            return []
        }
        return [hostConfigured]
    }

    /// Select from the SAME signed candidate set in every process, before the
    /// process-local container check. Never resolve ambiguous rights by ordering.
    static func selectDeclaredAppGroup(
        candidates: [String], hostConfigured: String?, tunnelConfigured: String?,
        documentConfigured: String?
    ) -> String? {
        let candidates = Set(candidates.filter { !$0.isEmpty })
        if candidates.count == 1 { return candidates.first }
        if let hostConfigured, hostConfigured == tunnelConfigured,
           candidates.contains(hostConfigured) { return hostConfigured }
        let declared = Set([hostConfigured, tunnelConfigured, documentConfigured]
            .compactMap { $0 }.filter { candidates.contains($0) })
        return declared.count == 1 ? declared.first : nil
    }

    private static let hostDeclaredGroup = hostBundle?.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String
    private static let tunnelDeclaredGroup = packetTunnelBundle?.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String

    // File Provider's explicit document group is meaningful only if the
    // embedded extension is signed for it. It cannot grant a new entitlement.
    private static let documentDeclaredGroup: String? = {
        #if os(iOS)
            guard let plugins = hostBundle?.builtInPlugInsURL,
                  let items = try? FileManager.default.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil)
            else { return nil }
            let declarations = items.compactMap { item -> String? in
                guard item.pathExtension == "appex", let bundle = Bundle(url: item),
                      let ext = bundle.infoDictionary?["NSExtension"] as? [String: Any],
                      ext["NSExtensionPointIdentifier"] as? String == "com.apple.fileprovider-nonui",
                      let group = ext["NSExtensionFileProviderDocumentGroup"] as? String,
                      SignedEntitlements.stringArray("com.apple.security.application-groups", of: bundle).contains(group)
                else { return nil }
                return group
            }
            let unique = Set(declarations)
            return unique.count == 1 ? unique.first : nil
        #else
            return nil
        #endif
    }()

    private static let signedCandidateGroups: [String] = {
        guard let hostBundle, let packetTunnelBundle else { return [] }
        return candidateAppGroups(
            ownSigned: SignedEntitlements.stringArray("com.apple.security.application-groups", of: hostBundle),
            peerSigned: SignedEntitlements.stringArray("com.apple.security.application-groups", of: packetTunnelBundle),
            hostConfigured: hostDeclaredGroup, tunnelConfigured: tunnelDeclaredGroup,
            hostProvisioned: SignedEntitlements.provisionedAppGroups(of: hostBundle),
            tunnelProvisioned: SignedEntitlements.provisionedAppGroups(of: packetTunnelBundle)
        )
    }()

    private static let usableAppGroups = signedCandidateGroups.filter {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) != nil
    }

    private static let selectedCandidateGroup: String? = selectDeclaredAppGroup(
        candidates: signedCandidateGroups,
        hostConfigured: hostDeclaredGroup,
        tunnelConfigured: tunnelDeclaredGroup,
        documentConfigured: documentDeclaredGroup
    )

    public static let resolvedAppGroupID: String? = {
        // A different set of live-accessible groups must never cause the app
        // and tunnel to pick different containers.
        guard let group = selectedCandidateGroup, usableAppGroups.contains(group) else { return nil }
        return group
    }()

    public static var appGroupSelectionAmbiguous: Bool {
        selectedCandidateGroup == nil && signedCandidateGroups.count > 1
    }

    /// Non-sensitive diagnostics for GBox/other re-signing tools.
    /// Does not claim that the extension can access a container merely because
    /// the host can; the extension repeats the same live access check.
    /// Includes per-blob source diagnostics so a DER-only or mismatched
    /// re-signature is visible without re-reading the Mach-O images.
    public static var signingDiagnostics: String {
        let own = SignedEntitlements.stringArray("com.apple.security.application-groups")
        let peer = peerBundle.map {
            SignedEntitlements.stringArray("com.apple.security.application-groups", of: $0)
        } ?? []
        let ownSources = SignedEntitlements.sourceDiagnostics()
        let peerSources = peerBundle.map { SignedEntitlements.sourceDiagnostics(of: $0) }
        return "host=\(packageName); tunnel=\(extensionBundleID); " +
            "ownSignedGroups=\(own.count); peerSignedGroups=\(peer.count); " +
            "ownSources=xml:\(ownSources.xmlStatus.rawValue)/der:\(ownSources.derStatus.rawValue) " +
            "selected:\(ownSources.selectedSource.rawValue) match:\(ownSources.xmlDERMatch.rawValue); " +
            "peerSources=xml:\(peerSources?.xmlStatus.rawValue ?? "unknown")/der:\(peerSources?.derStatus.rawValue ?? "unknown") " +
            "selected:\(peerSources?.selectedSource.rawValue ?? "unknown") match:\(peerSources?.xmlDERMatch.rawValue ?? "unknown"); " +
            "hostDeclared=\(hostDeclaredGroup ?? "none"); tunnelDeclared=\(tunnelDeclaredGroup ?? "none"); " +
            "documentDeclaredAuthorized=\(documentDeclaredGroup ?? "none"); " +
            "candidateGroups=\(signedCandidateGroups.joined(separator: ",")); " +
            "usableGroups=\(usableAppGroups.count); " +
            "resolved=\(resolvedAppGroupID ?? "none"); " +
            "ambiguous=\(appGroupSelectionAmbiguous)"
    }

}
