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
        guard let manager = try await loadManager() else {
            throw nodeError("VPN-конфигурация не найдена")
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

    private static func loadManager() async throws -> NETunnelProviderManager? {
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        return managers.first
    }
}
