import Foundation
import NetworkExtension

enum WidgetAppConfiguration {
    static let packageName: String = {
        // Prefer the actual host bundle identifier: re-signing tools rename bundle
        // identifiers to match the signing profile; the widget lives inside the host
        // app, so resolve the host the same way the main app does.
        if let id = resolvedHostBundleID, !id.isEmpty {
            return id
        }
        guard let value = Bundle.main.object(forInfoDictionaryKey: "BasePackageIdentifier") as? String else {
            fatalError("Missing BasePackageIdentifier in Info.plist")
        }
        return value
    }()

    static let appGroupID: String = {
        // Same priority as the main app: prefer the build-time group when still
        // entitled under the current signature, then the intersection of the
        // host app / packet-tunnel extension signed groups, then the single
        // remaining usable group. The widget, the app and the tunnel must all
        // resolve the same group.
        let ownGroups = SignedEntitlements.stringArray("com.apple.security.application-groups")
        var candidates = ownGroups
        if let peerGroups = peerBundleGroups(), !peerGroups.isEmpty {
            candidates = Array(Set(candidates).intersection(Set(peerGroups)))
        }
        let usable = candidates
            .filter { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) != nil }
            .sorted()
        if let preferred = Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String,
           !preferred.isEmpty, usable.contains(preferred) {
            return preferred
        }
        if !usable.isEmpty {
            return usable[0]
        }
        guard let value = Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String else {
            fatalError("Missing AppGroupIdentifier in Info.plist")
        }
        return value
    }()

    static var widgetControlKind: String {
        "\(packageName).widget.ServiceToggle"
    }

    /// Signed app groups of the packet-tunnel extension inside the host app
    /// (the widget is an .appex inside PlugIns, so the host is reachable by
    /// walking up the bundle tree).
    private static func peerBundleGroups() -> [String]? {
        var url = Bundle.main.bundleURL
        var hostURL: URL?
        while url.pathComponents.count > 1 {
            url = url.deletingLastPathComponent()
            if url.pathExtension == "app" {
                hostURL = url
                break
            }
        }
        guard let hostURL, let plugins = Bundle(url: hostURL)?.builtInPlugInsURL,
              let items = try? FileManager.default.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil) else {
            return nil
        }
        for item in items where item.pathExtension == "appex" {
            guard let info = Bundle(url: item)?.infoDictionary else { continue }
            guard let ext = info["NSExtension"] as? [String: Any] else { continue }
            guard ext["NSExtensionPointIdentifier"] as? String == "com.apple.networkextension.packet-tunnel" else { continue }
            guard let bundle = Bundle(url: item) else { continue }
            return SignedEntitlements.stringArray("com.apple.security.application-groups", of: bundle)
        }
        return nil
    }

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
}

extension NEVPNStatus {
    var isStarted: Bool {
        switch self {
        case .connecting, .connected, .reasserting:
            return true
        default:
            return false
        }
    }
}

enum WidgetTunnelControl {
    static func currentIsStarted() async throws -> Bool {
        guard let manager = try await loadManager() else {
            return false
        }
        return manager.connection.status.isStarted
    }

    static func setStarted(_ started: Bool) async throws {
        guard let manager = try await loadManager() else {
            NSLog("[WidgetTunnelControl] No tunnel configuration found")
            throw NSError(domain: "WidgetTunnelControl", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Tunnel configuration not found",
            ])
        }

        if started {
            if manager.isEnabled == false {
                manager.isEnabled = true
            }
            if let proto = manager.protocolConfiguration as? NETunnelProviderProtocol,
               let config = proto.providerConfiguration,
               config["wasOnDemandEnabled"] as? Bool == true
            {
                var newConfig = config
                newConfig.removeValue(forKey: "wasOnDemandEnabled")
                proto.providerConfiguration = newConfig
                manager.isOnDemandEnabled = true
            }
            try await manager.saveToPreferences()
            do {
                try manager.connection.startVPNTunnel()
            } catch {
                NSLog("[WidgetTunnelControl] startVPNTunnel failed: \(error.localizedDescription)")
                throw error
            }
        } else {
            if manager.isOnDemandEnabled {
                if let proto = manager.protocolConfiguration as? NETunnelProviderProtocol {
                    var config = proto.providerConfiguration ?? [:]
                    config["wasOnDemandEnabled"] = true
                    proto.providerConfiguration = config
                }
                manager.isOnDemandEnabled = false
                try await manager.saveToPreferences()
            }
            manager.connection.stopVPNTunnel()
        }
    }

    private static func loadManager() async throws -> NETunnelProviderManager? {
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        return managers.first
    }
}
