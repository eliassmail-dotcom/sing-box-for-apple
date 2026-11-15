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
        // Empty means no entitled group; FilePath falls back safely to local storage.
        return Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String ?? ""
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

    /// App groups usable in this process: entitled per this binary's signature,
    /// intersected with the peer binary's signed groups (when discoverable),
    /// with a live container, sorted for determinism.
    private static let usableAppGroups: [String] = {
        // Never assume a local-only group is usable by the VPN extension.
        guard let peerBundle else { return [] }
        let own = Set(SignedEntitlements.stringArray("com.apple.security.application-groups"))
        let peer = Set(SignedEntitlements.stringArray("com.apple.security.application-groups", of: peerBundle))
        return own.intersection(peer)
            .filter { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) != nil }
            .sorted()
    }()

    /// The build-time AppGroupIdentifier, when it is still entitled and usable
    /// under the current signature (priority 1).
    private static let preferredAppGroup: String? = {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String,
              !value.isEmpty,
              usableAppGroups.contains(value) else {
            return nil
        }
        return value
    }()

    /// App group resolved from the signed entitlements, with priority:
    /// 1. build-time AppGroupIdentifier if still usable;
    /// 2. intersection of the host/extension signed groups;
    /// 3. the single remaining usable group;
    /// 4. with several remaining, a deterministic (sorted) choice - see
    ///    appGroupSelectionAmbiguous for diagnostics.
    /// A shared group is selected only when both host and tunnel are entitled.
    /// Never silently pick an arbitrary group if more than one is eligible.
    public static let resolvedAppGroupID: String? = {
        if let preferredAppGroup { return preferredAppGroup }
        return usableAppGroups.count == 1 ? usableAppGroups[0] : nil
    }()

    /// True when several app groups remained eligible and none was preferred:
    /// the chosen group is deterministic, but not provably the intended one.
    public static var appGroupSelectionAmbiguous: Bool {
        preferredAppGroup == nil && usableAppGroups.count > 1
    }
}
