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
        return Bundle.main.object(forInfoDictionaryKey: "BasePackageIdentifier") as? String ?? Bundle.main.bundleIdentifier ?? ""
    }()

    static let appGroupID: String = {
        // Same priority as the main app: prefer the build-time group when still
        // entitled under the current signature, then the intersection of the
        // host app / packet-tunnel extension signed groups, then the single
        // remaining usable group. The widget, the app and the tunnel must all
        // resolve the same group.
        // DER-only re-signatures can omit the XML slot entirely. Treat
        // provisioning groups only as candidate *names* and require a live
        // App Group container to confirm actual entitlement in this process.
        let ownXML = SignedEntitlements.stringArray("com.apple.security.application-groups")
        let ownGroups = ownXML.isEmpty
            ? SignedEntitlements.provisionedAppGroups(of: Bundle.main) : ownXML
        let peerGroups = peerBundleGroups() ?? []
        var candidates = ownGroups
        if !peerGroups.isEmpty {
            candidates = candidates.isEmpty ? peerGroups
                : Array(Set(candidates).intersection(Set(peerGroups)))
        }
        if candidates.isEmpty && ownGroups.isEmpty && peerGroups.isEmpty,
           let preferred = Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String {
            candidates = [preferred]
        }
        let usable = candidates
            .filter { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) != nil }
            .sorted()
        if let preferred = Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String,
           !preferred.isEmpty, usable.contains(preferred) {
            return preferred
        }
        if usable.count == 1 {
            return usable[0]
        }
        return ""
    }()

    static var widgetControlKind: String {
        "\(packageName).widget.ServiceToggle"
    }

    static var widgetNextNodeKind: String {
        "\(packageName).widget.NextNode"
    }

    /// Locate the actual signed tunnel extension after re-signing.
    static var packetTunnelBundleID: String? {
        var url = Bundle.main.bundleURL
        while url.pathComponents.count > 1 {
            url = url.deletingLastPathComponent()
            if url.pathExtension == "app" { break }
        }
        guard url.pathExtension == "app",
              let plugins = Bundle(url: url)?.builtInPlugInsURL,
              let items = try? FileManager.default.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil) else { return nil }
        for item in items where item.pathExtension == "appex" {
            guard let bundle = Bundle(url: item),
                  let ext = bundle.infoDictionary?["NSExtension"] as? [String: Any],
                  ext["NSExtensionPointIdentifier"] as? String == "com.apple.networkextension.packet-tunnel" else { continue }
            return bundle.bundleIdentifier
        }
        return nil
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
            let xml = SignedEntitlements.stringArray("com.apple.security.application-groups", of: bundle)
            return xml.isEmpty ? SignedEntitlements.provisionedAppGroups(of: bundle) : xml
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

    /// Sends a command to the already-running PacketTunnel extension. Using
    /// sendProviderMessage avoids importing Libbox into the widget target,
    /// starting a second VPN session, or modifying subscription settings.
    static func changeNode() async throws {
        guard let manager = try await loadManager(connectedOnly: true) else {
            throw nodeError("Подключённый туннель sing-box не найден")
        }
        guard manager.connection.status == .connected,
              let session = manager.connection as? NETunnelProviderSession else {
            throw nodeError("Сначала подключите VPN")
        }
        let command = try JSONSerialization.data(withJSONObject: [
            "lxControl": "changeNode",
            "version": 1,
        ])

        let response: Data = try await withCheckedThrowingContinuation { continuation in
            do {
                try session.sendProviderMessage(command) { data in
                    guard let data else {
                        continuation.resume(throwing: nodeError("Туннель не ответил на команду"))
                        return
                    }
                    continuation.resume(returning: data)
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }

        guard let reply = try JSONSerialization.jsonObject(with: response) as? [String: Any] else {
            throw nodeError("Получен некорректный ответ туннеля")
        }
        if reply["ok"] as? Bool == true {
            guard let previous = reply["previousNode"] as? String,
                  let selected = reply["selectedNode"] as? String,
                  !selected.isEmpty, selected != previous else {
                throw nodeError("Туннель не подтвердил смену активного узла")
            }
            NSLog("[WidgetTunnelControl] LX Next Node confirmed")
            return
        }
        let reason = reply["error"] as? String ?? "Не удалось сменить узел"
        throw nodeError(reason)
    }

    private static func nodeError(_ message: String) -> NSError {
        NSError(domain: "LXNextNodeControl", code: 1, userInfo: [
            NSLocalizedDescriptionKey: message,
        ])
    }

    /// Use the tunnel owned by this app instead of loadAllFromPreferences().first.
    /// iOS may retain old or additional VPN profiles; sending the LX command to
    /// one of those silently leaves the Dashboard's running route unchanged.
    private static func loadManager(connectedOnly: Bool = false) async throws -> NETunnelProviderManager? {
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        // GBox/other signing tools can rewrite the actual CFBundleIdentifier
        // while leaving BasePackageIdentifier in Info.plist unchanged.
        // Derive the installed package from this signed .widget extension too.
        var packageNames = [WidgetAppConfiguration.packageName]
        if let signedWidgetID = Bundle.main.bundleIdentifier,
           signedWidgetID.hasSuffix(".widget") {
            let signedBase = String(signedWidgetID.dropLast(".widget".count))
            if !packageNames.contains(signedBase) {
                packageNames.insert(signedBase, at: 0)
            }
        }
        let expectedIDs = Set(packageNames.flatMap { base in
            ["\(base).extension", "\(base).system"]
        })
        let exact = managers.filter { manager in
            guard let tunnel = manager.protocolConfiguration as? NETunnelProviderProtocol,
                  let provider = tunnel.providerBundleIdentifier else { return false }
            return expectedIDs.contains(provider)
        }
        // Never select unrelated or stale VPN profiles by a generic serverAddress.
        // The embedded extension's real signed Bundle ID is authoritative.
        let candidates = managers.filter { manager in
            guard let tunnel = manager.protocolConfiguration as? NETunnelProviderProtocol,
                  let provider = tunnel.providerBundleIdentifier else { return false }
            return expectedIDs.contains(provider) || provider == WidgetAppConfiguration.packetTunnelBundleID
        }
        if connectedOnly {
            return candidates.first(where: { $0.connection.status == .connected })
        }
        return candidates.first(where: { $0.connection.status.isStarted }) ?? candidates.first
    }
}
