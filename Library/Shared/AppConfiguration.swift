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
        "\(packageName).update_profiles"
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

    /// Bundle identifier of the host application. Valid in both the app process and
    /// extension processes (extensions live inside <Host>.app/PlugIns/*.appex).
    private static let resolvedHostBundleID: String? = {
        let bundle = Bundle.main
        if bundle.bundleURL.pathExtension == "appex" {
            var url = bundle.bundleURL
            while url.pathComponents.count > 1 {
                url = url.deletingLastPathComponent()
                if url.pathExtension == "app" {
                    return Bundle(url: url)?.bundleIdentifier
                }
            }
            return nil
        }
        return bundle.bundleIdentifier
    }()

    /// Identifier of the embedded packet-tunnel extension, discovered from the app
    /// bundle contents instead of assuming the ".extension" suffix.
    private static let resolvedExtensionBundleID: String? = {
        let bundle = Bundle.main
        if bundle.bundleURL.pathExtension == "appex" {
            return bundle.bundleIdentifier
        }
        guard let plugins = bundle.builtInPlugInsURL,
              let items = try? FileManager.default.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil) else {
            return nil
        }
        for item in items where item.pathExtension == "appex" {
            guard let info = Bundle(url: item)?.infoDictionary else { continue }
            guard let ext = info["NSExtension"] as? [String: Any] else { continue }
            guard ext["NSExtensionPointIdentifier"] as? String == "com.apple.networkextension.packet-tunnel" else { continue }
            return info["CFBundleIdentifier"] as? String
        }
        return nil
    }()

    /// First app group (sorted for determinism across processes) that this process
    /// can actually access according to its signed entitlements.
    private static let resolvedAppGroupID: String? = {
        let groups = SignedEntitlements.stringArray("com.apple.security.application-groups").sorted()
        for group in groups {
            if FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) != nil {
                return group
            }
        }
        return nil
    }()
}
