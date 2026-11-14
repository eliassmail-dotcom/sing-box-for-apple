import Foundation
import NetworkExtension

enum WidgetAppConfiguration {
    static let packageName: String = {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "BasePackageIdentifier") as? String else {
            fatalError("Missing BasePackageIdentifier in Info.plist")
        }
        return value
    }()

    static let appGroupID: String = {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String else {
            fatalError("Missing AppGroupIdentifier in Info.plist")
        }
        return value
    }()

    static var widgetControlKind: String {
        "\(packageName).widget.ServiceToggle"
    }

    static var widgetNextNodeKind: String {
        "\(packageName).widget.NextNode"
    }
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
        let expectedIDs: Set<String> = [
            "\(WidgetAppConfiguration.packageName).extension",
            "\(WidgetAppConfiguration.packageName).system",
        ]
        let matching = managers.filter { manager in
            guard let tunnel = manager.protocolConfiguration as? NETunnelProviderProtocol,
                  let provider = tunnel.providerBundleIdentifier else { return false }
            // The serverAddress is written by ExtensionProfile.install and
            // remains stable after third-party IPA resigning.
            return expectedIDs.contains(provider) ||
                (tunnel.serverAddress == "sing-box" &&
                 (provider.hasSuffix(".extension") || provider.hasSuffix(".system")))
        }
        // Never control a different VPN just because it was listed first.
        let candidates = matching
        if connectedOnly {
            return candidates.first(where: { $0.connection.status == .connected })
        }
        return candidates.first(where: { $0.connection.status.isStarted }) ?? candidates.first
    }
}
