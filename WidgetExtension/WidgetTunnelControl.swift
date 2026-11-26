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

    static func candidateAppGroups(
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

    static let appGroupID: String = {
        // Mirror the host/tunnel negotiation; the widget may validate only
        // the selected common group, never independently choose another.
        var url = Bundle.main.bundleURL
        while url.pathComponents.count > 1 && url.pathExtension != "app" {
            url = url.deletingLastPathComponent()
        }
        guard url.pathExtension == "app", let host = Bundle(url: url),
              let plugins = host.builtInPlugInsURL,
              let items = try? FileManager.default.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil)
        else { return "" }
        let bundles = items.filter { $0.pathExtension == "appex" }.compactMap { Bundle(url: $0) }
        guard let tunnel = bundles.first(where: {
            ($0.infoDictionary?["NSExtension"] as? [String: Any])?["NSExtensionPointIdentifier"] as? String == "com.apple.networkextension.packet-tunnel"
        }) else { return "" }
        let hostDeclared = host.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String
        let tunnelDeclared = tunnel.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String
        let documents = Set(bundles.compactMap { bundle -> String? in
            guard let ext = bundle.infoDictionary?["NSExtension"] as? [String: Any],
                  ext["NSExtensionPointIdentifier"] as? String == "com.apple.fileprovider-nonui",
                  let group = ext["NSExtensionFileProviderDocumentGroup"] as? String,
                  SignedEntitlements.stringArray("com.apple.security.application-groups", of: bundle).contains(group)
            else { return nil }
            return group
        })
        let candidates = candidateAppGroups(
            ownSigned: SignedEntitlements.stringArray("com.apple.security.application-groups", of: host),
            peerSigned: SignedEntitlements.stringArray("com.apple.security.application-groups", of: tunnel),
            hostConfigured: hostDeclared, tunnelConfigured: tunnelDeclared,
            hostProvisioned: SignedEntitlements.provisionedAppGroups(of: host),
            tunnelProvisioned: SignedEntitlements.provisionedAppGroups(of: tunnel)
        )
        guard let group = selectDeclaredAppGroup(candidates: candidates,
                    hostConfigured: hostDeclared, tunnelConfigured: tunnelDeclared,
                    documentConfigured: documents.count == 1 ? documents.first : nil)
        else { return "" }
        let own = SignedEntitlements.stringArray("com.apple.security.application-groups")
        guard own.isEmpty || own.contains(group),
              FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) != nil
        else { return "" }
        return group
    }()

    static var widgetControlKind: String {
        "\(packageName).widget.ServiceToggle"
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
    /// Widget/Control Center process diagnostics. The control is a separate
    /// start path for the tunnel (no app process, snapshot-only options), so
    /// its outcomes must be visible in the shared diagnostics log.
    static func configureDiagnostics() {
        let group = WidgetAppConfiguration.appGroupID
        DiagnosticsLog.configureSharedDirectory(
            group.isEmpty ? nil : FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
        )
    }

    static func currentIsStarted() async throws -> Bool {
        configureDiagnostics()
        guard let manager = try await loadManager() else {
            // A missing app-owned VPN configuration is distinct from "stopped".
            // Controls may be visible before a VPN profile has been installed.
            NSLog("[WidgetTunnelControl] No app-owned tunnel configuration for status query")
            return false
        }
        return manager.connection.status.isStarted
    }

    static func setStarted(_ started: Bool) async throws {
        configureDiagnostics()
        DiagnosticsLog.record("widget.vpn.set", result: .unknown, details: "requested=\(started ? "on" : "off")")
        guard let manager = try await loadManager() else {
            NSLog("[WidgetTunnelControl] No tunnel configuration found")
            DiagnosticsLog.record("widget.vpn.set", result: .fail, errorDomain: "WidgetTunnelControl", errorCode: 1,
                                details: "tunnel configuration not found")
            throw NSError(domain: "WidgetTunnelControl", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Tunnel configuration not found",
            ])
        }

        if started {
            var preferencesChanged = false
            if !manager.isEnabled {
                manager.isEnabled = true
                preferencesChanged = true
            }
            if let proto = manager.protocolConfiguration as? NETunnelProviderProtocol,
               let config = proto.providerConfiguration,
               config["wasOnDemandEnabled"] as? Bool == true
            {
                var newConfig = config
                newConfig.removeValue(forKey: "wasOnDemandEnabled")
                proto.providerConfiguration = newConfig
                manager.isOnDemandEnabled = true
                preferencesChanged = true
            }
            if preferencesChanged {
                try await manager.saveToPreferences()
                // The NE preferences manager needs to be refreshed after a
                // save. Otherwise a stale configuration can cause VPN start
                // errors, especially from a short-lived widget process.
                try await manager.loadFromPreferences()
            }
            if !manager.connection.status.isStarted {
                do {
                    try manager.connection.startVPNTunnel()
                    DiagnosticsLog.record("widget.vpn.set", result: .pass, details: "requested=on startIssued")
                } catch {
                    NSLog("[WidgetTunnelControl] startVPNTunnel failed: \(error.localizedDescription)")
                    let nsError = error as NSError
                    DiagnosticsLog.record("widget.vpn.set", result: .fail, errorDomain: nsError.domain,
                        errorCode: nsError.code, details: "startVPNTunnel failed")
                    throw error
                }
            } else {
                DiagnosticsLog.record("widget.vpn.set", result: .pass, details: "requested=on alreadyStarted")
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
                try await manager.loadFromPreferences()
            }
            manager.connection.stopVPNTunnel()
            DiagnosticsLog.record("widget.vpn.set", result: .pass, details: "requested=off stopIssued")
        }
    }

    /// Sends a command to the already-running PacketTunnel extension. Using
    /// sendProviderMessage avoids importing Libbox into the widget target,
    /// starting a second VPN session, or modifying subscription settings.
    static func changeNode() async throws {
        configureDiagnostics()
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

        DiagnosticsLog.record("widget.node.ipc.send", result: .unknown)
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

        DiagnosticsLog.record("widget.node.ipc.reply", result: .pass)
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
        let managers: [NETunnelProviderManager]
        do {
            managers = try await NETunnelProviderManager.loadAllFromPreferences()
        } catch {
            // This is often a signature-specific failure: iOS evaluates the
            // WidgetExtension's entitlements, not only the host app's.
            let declaredInXML = SignedEntitlements.stringArray(
                "com.apple.developer.networking.networkextension"
            ).contains("packet-tunnel-provider")
            let nsError = error as NSError
            DiagnosticsLog.record("widget.vpn.prefs", result: .fail, errorDomain: nsError.domain,
                errorCode: nsError.code,
                details: "widgetNEInXML=\(declaredInXML) — VPN preferences unavailable in widget process")
            NSLog("[WidgetTunnelControl] VPN preferences unavailable; widgetNEInXML=\(declaredInXML); error=\(error.localizedDescription)")
            throw NSError(domain: "WidgetTunnelControl", code: 2, userInfo: [
                NSLocalizedDescriptionKey:
                    "Пункт управления не может прочитать VPN. Проверьте Network Extension entitlement в подписи WidgetExtension.",
                NSUnderlyingErrorKey: error,
            ])
        }
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
        // Never select unrelated or stale VPN profiles by a generic serverAddress.
        // The embedded extension's real signed Bundle ID is authoritative.
        let candidates = managers.filter { manager in
            guard let tunnel = manager.protocolConfiguration as? NETunnelProviderProtocol,
                  let provider = tunnel.providerBundleIdentifier else { return false }
            return expectedIDs.contains(provider) || provider == WidgetAppConfiguration.packetTunnelBundleID
        }
        if candidates.isEmpty {
            NSLog("[WidgetTunnelControl] No matching tunnel: storedManagers=\(managers.count), expectedProviders=\(expectedIDs.count), embeddedTunnelFound=\(WidgetAppConfiguration.packetTunnelBundleID != nil)")
            DiagnosticsLog.record("widget.vpn.manager", result: .fail,
                details: "storedManagers=\(managers.count) expectedProviders=\(expectedIDs.count) embeddedTunnelFound=\(WidgetAppConfiguration.packetTunnelBundleID != nil)")
            return nil
        }
        if connectedOnly {
            return candidates.first(where: { $0.connection.status == .connected })
        }
        return candidates.first(where: { $0.connection.status.isStarted }) ?? candidates.first
    }
}
