import Foundation

public enum AppConfiguration {
    public static let packageName: String = {
        // Prefer the actual runtime bundle identifier: re-signing tools rename
        // bundle identifiers to match the signing profile, while the custom
        // Info.plist placeholders below keep their build-time values.
        if let id = resolvedHostBundleID, !id.isEmpty {
            return id
        }
        guard let value = Bundle.main.object(forInfoDictionaryKey: "BasePackageIdentifier") as? String else {
            fatalError("Missing BasePackageIdentifier in Info.plist")
        }
        return value
    }()

    public static let appGroupID: String = {
        // Prefer an app group this binary is actually entitled to: re-signing
        // tools rewrite entitlements to groups available in the signing profile.
        if let id = resolvedAppGroupID {
            return id
        }
        guard let value = Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String else {
            fatalError("Missing AppGroupIdentifier in Info.plist")
        }
        return value
    }()

    public static var teamID: String {
        guard let dotIndex = appGroupID.firstIndex(of: ".") else {
            fatalError("Invalid appGroupID format: \(appGroupID)")
        }
        return String(appGroupID[..<dotIndex])
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
        "\(packageName).profile"
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
        "iCloud.\(packageName)"
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
        if Bundle.main.bundleURL.pathExtension == "appex" {
            return Bundle.main
        }
        guard let plugins = Bundle.main.builtInPlugInsURL,
              let items = try? FileManager.default.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil) else {
            return nil
        }
        for item in items where item.pathExtension == "appex" {
            guard let info = Bundle(url: item)?.infoDictionary else { continue }
            guard let ext = info["NSExtension"] as? [String: Any] else { continue }
            guard ext["NSExtensionPointIdentifier"] as? String == "com.apple.networkextension.packet-tunnel" else { continue }
            return Bundle(url: item)
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
        var candidates = SignedEntitlements.stringArray("com.apple.security.application-groups")
        let peerGroups = peerBundle.map { SignedEntitlements.stringArray("com.apple.security.application-groups", of: $0) } ?? []
        if !peerGroups.isEmpty {
            candidates = Array(Set(candidates).intersection(Set(peerGroups)))
        }
        return candidates
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
    private static let resolvedAppGroupID: String? = {
        if let preferredAppGroup {
            return preferredAppGroup
        }
        return usableAppGroups.first
    }()

    /// True when several app groups remained eligible and none was preferred:
    /// the chosen group is deterministic, but not provably the intended one.
    public static var appGroupSelectionAmbiguous: Bool {
        preferredAppGroup == nil && usableAppGroups.count > 1
    }
}
