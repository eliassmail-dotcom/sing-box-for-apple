import Foundation
import Libbox
import NetworkExtension
import os
#if os(iOS)
    import FileProvider
#endif

private let logger = Logger(category: "ExtensionProfile")

@MainActor
public class ExtensionProfile: ObservableObject {
    public static let controlKind = AppConfiguration.widgetControlKind

    private let manager: NEVPNManager?
    private var connection: NEVPNConnection?
    private var observer: Any?
    private var observesStatus = false
    private let isMock: Bool

    @Published public var status: NEVPNStatus
    @Published public var connectedDate: Date?

    public init(_ manager: NEVPNManager) {
        self.manager = manager
        connection = manager.connection
        status = manager.connection.status
        connectedDate = manager.connection.connectedDate
        isMock = false
    }

    private init(mockStatus: NEVPNStatus, mockConnectedDate: Date?) {
        manager = nil
        connection = nil
        status = mockStatus
        connectedDate = mockConnectedDate
        isMock = true
    }

    private static var _mock: ExtensionProfile?

    public static var mock: ExtensionProfile {
        if _mock == nil {
            _mock = ExtensionProfile(mockStatus: .connected, mockConnectedDate: Date().addingTimeInterval(-3600))
        }
        return _mock!
    }

    public func register() {
        guard !isMock else { return }
        observesStatus = true
        rebindConnection()
    }

    // Reloading NE preferences may replace manager.connection.
    // Observe the reloaded session rather than a stale connection.
    private func rebindConnection() {
        guard !isMock, let manager else { return }
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        connection = manager.connection
        status = manager.connection.status
        connectedDate = manager.connection.connectedDate
        guard observesStatus else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSNotification.Name.NEVPNStatusDidChange,
            object: manager.connection,
            queue: nil
        ) { [weak self] notification in
            guard let connection = notification.object as? NEVPNConnection else {
                return
            }
            Task { @MainActor in
                guard let self else {
                    return
                }
                self.connection = connection
                self.status = connection.status
                self.connectedDate = connection.connectedDate
                if connection.status == .disconnected {
                    Self.schedulePromoteOOMDraft()
                }
                #if os(iOS)
                    if #available(iOS 16.0, *) {
                        if connection.status == .connected || connection.status == .disconnected {
                            Self.signalFileProviderChanges()
                        }
                    }
                #endif
            }
        }
    }

    private static func schedulePromoteOOMDraft() {
        Task.detached {
            try? await Task.sleep(nanoseconds: 2 * NSEC_PER_SEC)
            #if os(macOS)
                if Variant.useSystemExtension {
                    guard HelperServiceManager.rootHelperStatus == .enabled else {
                        return
                    }
                    do {
                        try RootHelperClient.shared.promoteOOMDraft()
                    } catch {
                        logger.warning("promote OOM draft: \(error.localizedDescription)")
                    }
                    return
                }
            #endif
            LibboxPromoteOOMDraft()
        }
    }

    #if os(iOS)
        @available(iOS 16.0, *)
        private static func signalFileProviderChanges() {
            Task.detached {
                guard let domain = try? await NSFileProviderManager.domains()
                    .first(where: { $0.identifier.rawValue == AppConfiguration.fileProviderDomainID }),
                    let manager = NSFileProviderManager(for: domain)
                else {
                    return
                }
                try? await manager.signalEnumerator(for: .workingSet)
            }
        }
    #endif

    nonisolated deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private static func makeDefaultOnDemandRules() -> [NEOnDemandRule] {
        let rule = NEOnDemandRuleConnect()
        rule.interfaceTypeMatch = .any
        rule.probeURL = URL(string: "http://captive.apple.com")
        return [rule]
    }

    private func setOnDemandRules(useDefaultRules: Bool) async {
        guard let manager else { return }
        if useDefaultRules {
            manager.onDemandRules = Self.makeDefaultOnDemandRules()
        } else {
            let rules = await SharedPreferences.onDemandRules.get()
            manager.onDemandRules = rules.isEmpty ? Self.makeDefaultOnDemandRules() : rules.map { $0.toNERule() }
        }
    }

    public func updateOnDemand(enabled: Bool, useDefaultRules: Bool) async throws {
        guard let manager else { return }
        manager.isOnDemandEnabled = enabled
        if !enabled {
            if let proto = manager.protocolConfiguration as? NETunnelProviderProtocol {
                var config = proto.providerConfiguration ?? [:]
                if config.removeValue(forKey: "wasOnDemandEnabled") != nil {
                    proto.providerConfiguration = config
                }
            }
        }
        await setOnDemandRules(useDefaultRules: useDefaultRules)
        try await manager.saveToPreferences()
    }

    private func applyProtocolConfiguration() async {
        #if !os(tvOS)
            guard let protocolConfiguration = manager?.protocolConfiguration else { return }
            protocolConfiguration.includeAllNetworks = await SharedPreferences.includeAllNetworks.get()
            protocolConfiguration.excludeLocalNetworks = await SharedPreferences.excludeLocalNetworks.get()
            protocolConfiguration.enforceRoutes = await SharedPreferences.enforceRoutes.get()
            if #available(iOS 16.4, macOS 13.3, *) {
                protocolConfiguration.excludeAPNs = await SharedPreferences.excludeAPNs.get()
                protocolConfiguration.excludeCellularServices = await SharedPreferences.excludeCellularServices.get()
            }
            if #available(iOS 17.4, macOS 14.4, *) {
                protocolConfiguration.excludeDeviceCommunication = await SharedPreferences.excludeDeviceCommunication.get()
            }
        #endif
    }

    public func updateProtocolConfiguration() async throws {
        guard let manager else { return }
        await applyProtocolConfiguration()
        try await manager.saveToPreferences()
    }

    @available(iOS 16.0, macOS 13.0, tvOS 17.0, *)
    public func fetchLastDisconnectError() async throws {
        guard let connection else { return }
        try await connection.fetchLastDisconnectError()
    }

    public func start() async throws {
        if isMock {
            status = .connecting
            try await Task.sleep(nanoseconds: 500_000_000)
            status = .connected
            connectedDate = Date()
            return
        }
        #if os(iOS)
            // A shared container is preferred for cross-process commands, but
            // NOT an iOS prerequisite for launching a Packet Tunnel. The app
            // passes the validated config directly in startVPNTunnel(options:).
            // Without App Group the extension stores its own last-good snapshot.
            if !FilePath.hasSharedContainer {
                logger.warning("VPN starting in isolated container mode: \(AppConfiguration.signingDiagnostics)")
            }
        #else
            guard FilePath.hasSharedContainer else {
                throw NSError(domain: "SigningCompatibility", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Shared application container is unavailable.",
                ])
            }
        #endif
        // Capture the current snapshot before preparing the candidate. The
        // post-connect write is compare-and-swap: a newer concurrent change wins.
        let expectedDesiredOptions = currentDesiredStartOptionsForWrite()
        // Build and validate the complete effective configuration before
        // asking NetworkExtension to start. Never persist an unvalidated candidate.
        let options = try await prepareStartOptions()
        do {
            try await connectWithOneSessionRecovery(options)
        } catch {
            throw await makeStartDiagnosticError(error, fallbackStage: "start / wait for connected / recovery")
        }
        if FilePath.hasSharedContainer {
            do {
                try persistDesiredStartOptions(options, expectedCurrent: expectedDesiredOptions)
            } catch {
                // The tunnel is already connected. A snapshot sync failure must
                // not turn a successful VPN start into a reported start failure.
                logger.warning("VPN connected, but desired snapshot was not updated: \(error.localizedDescription)")
            }
        }
    }

    /// The first Packet Tunnel launch after replacing a re-signed IPA can fail
    /// while iOS is still disposing a previous PluginKit session. Do not report
    /// a successful session as failed, and never loop indefinitely. This only
    /// retries once after iOS has returned to the disconnected state; a bad
    /// entitlement or config will still surface as an error.
    private func connectWithOneSessionRecovery(_ options: [String: NSObject]) async throws {
        do {
            try await start(with: options)
            try await awaitConnected()
            return
        } catch {
            let firstError = error as NSError
            // Never reset a live or still-connecting tunnel.
            guard let manager, connection?.status == .disconnected else {
                throw error
            }
            logger.warning("Initial VPN start failed (\(firstError.domain, privacy: .public)/\(firstError.code)); reloading NetworkExtension preferences and retrying once")
            try await Task.sleep(nanoseconds: 800_000_000)
            do {
                try await manager.loadFromPreferences()
                rebindConnection()
                // A delayed system On Demand start may have begun in the meantime.
                if connection?.status == .connected { return }
                try await start(with: options)
                try await awaitConnected()
            } catch {
                let secondError = error as NSError
                throw NSError(
                    domain: "ExtensionProfile.FirstStartRecovery",
                    code: secondError.code,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Initial start: \(firstError.domain) code=\(firstError.code): \(firstError.localizedDescription)\\n" +
                            "Single recovery attempt: \(secondError.domain) code=\(secondError.code): \(secondError.localizedDescription)",
                        NSUnderlyingErrorKey: secondError
                    ]
                )
            }
        }
    }

    // Surface NetworkExtension diagnostics in the app's error alert. The
    // standard "Copy" action only copies NSError.localizedDescription, so
    // technical fields must be included in that description explicitly.
    private func makeStartDiagnosticError(_ error: Error, fallbackStage: String) async -> NSError {
        let startError = error as NSError
        let nested = startError.userInfo[NSUnderlyingErrorKey] as? NSError
        let stage = startError.userInfo["VPNStartStage"] as? String ?? fallbackStage
        let disconnect: String
        if let connection, #available(iOS 16.0, macOS 13.0, tvOS 17.0, *) {
            do {
                try await connection.fetchLastDisconnectError()
                disconnect = "none reported"
            } catch {
                let value = error as NSError
                disconnect = "\(value.domain) code=\(value.code): \(value.localizedDescription)"
            }
        } else {
            disconnect = "unavailable on this OS or VPN session"
        }
        let statusValue = connection?.status.rawValue ?? -1
        let details = [
            "Stage: \(stage)",
            "NSError: \(startError.domain) code=\(startError.code)",
            "Underlying: \(nested.map { "\($0.domain) code=\($0.code): \($0.localizedDescription)" } ?? "none")",
            "Last disconnect: \(disconnect)",
            "VPN status: \(statusValue)",
            "Shared App Group: \(FilePath.hasSharedContainer ? "available" : "unavailable")"
        ].joined(separator: "\n")
        logger.error("VPN start diagnostics: \(details, privacy: .public)")
        return NSError(
            domain: "ExtensionProfile.StartDiagnostics",
            code: startError.code,
            userInfo: [
                NSLocalizedDescriptionKey: "\(startError.localizedDescription)\n\n--- VPN diagnostics ---\n\(details)",
                NSUnderlyingErrorKey: error
            ]
        )
    }

    // startVPNTunnel returning does not prove that the extension started.
    private func awaitConnected(timeout: TimeInterval = 20) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard let connection else {
                throw NSError(domain: "ExtensionProfile.Start", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "VPN session was lost during startup."
                ])
            }
            status = connection.status
            connectedDate = connection.connectedDate
            if connection.status == .connected { return }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        let currentStatus = connection?.status.rawValue ?? -1
        throw NSError(domain: "ExtensionProfile.Start", code: 4, userInfo: [
            NSLocalizedDescriptionKey: "VPN did not connect within \(Int(timeout)) seconds (status \(currentStatus))."
        ])
    }

    private func start(with options: [String: NSObject]) async throws {
        guard let manager else { return }
        try await fetchProfile()
        manager.isEnabled = true
        let alwaysOn = await SharedPreferences.alwaysOn.get()
        let onDemandEnabled = await SharedPreferences.onDemandEnabled.get()
        manager.isOnDemandEnabled = alwaysOn || onDemandEnabled
        if manager.isOnDemandEnabled {
            await setOnDemandRules(useDefaultRules: alwaysOn)
        }
        if let proto = manager.protocolConfiguration as? NETunnelProviderProtocol {
            var config = proto.providerConfiguration ?? [:]
            if config.removeValue(forKey: "wasOnDemandEnabled") != nil {
                proto.providerConfiguration = config
            }
        }
        await applyProtocolConfiguration()
        var stage = "saveToPreferences"
        do {
            try await manager.saveToPreferences()
            stage = "loadFromPreferences"
            try await manager.loadFromPreferences()
            rebindConnection()
            stage = "startVPNTunnel"
            guard let connection else {
                throw NSError(domain: "ExtensionProfile.Start", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "VPN session unavailable after reloading preferences."
                ])
            }
            // Saving an On Demand manager may already have started the tunnel.
            // Starting it again during .connecting can cause a spurious first-launch error.
            if connection.status == .connected || connection.status == .connecting ||
                connection.status == .reasserting {
                logger.info("Using existing NetworkExtension session, status=\(connection.status.rawValue)")
            } else {
                try connection.startVPNTunnel(options: options)
            }
        } catch {
            let nsError = error as NSError
            let nested = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
            logger.error("VPN start failed at \(stage, privacy: .public): \(nsError.domain, privacy: .public) code=\(nsError.code) underlying=\(nested?.domain ?? "none", privacy: .public)/\(nested?.code ?? 0); \(nsError.localizedDescription, privacy: .public)")
            var userInfo = nsError.userInfo
            userInfo["VPNStartStage"] = stage
            userInfo[NSUnderlyingErrorKey] = error
            throw NSError(domain: nsError.domain, code: nsError.code, userInfo: userInfo)
        }
    }

    /// Refresh the widget's desired configuration while the tunnel is stopped.
    /// The extension promotes this snapshot to last-good only after a successful start.
    public func refreshDesiredStartOptions() async throws {
        guard !isMock else { return }
        // Isolated app storage cannot feed a stopped extension's Control Center
        // start. Never silently claim that the new snapshot is synchronized.
        guard FilePath.hasSharedContainer else {
            throw NSError(domain: "ExtensionProfile.ConfigSync", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Нет общего App Group: нельзя обновить конфигурацию для запуска из Пункта управления при выключенном VPN. Подключите VPN из приложения после изменения настроек."
            ])
        }
        let expectedDesiredOptions = try loadDesiredStartOptions()
        let options = try await prepareStartOptions()
        try persistDesiredStartOptions(options, expectedCurrent: expectedDesiredOptions)
    }

    private func loadDesiredStartOptions() throws -> [String: NSObject]? {
        guard FilePath.hasSharedContainer else { return nil }
        let url = FilePath.sharedDirectory.appendingPathComponent(ExtensionStartOptions.snapshotFileName)
        return try ExtensionStartOptions.readSnapshot(from: url)
    }

    private func currentDesiredStartOptionsForWrite() -> [String: NSObject]? {
        do {
            return try loadDesiredStartOptions()
        } catch {
            // The locked writer will reject an unreadable existing snapshot.
            logger.warning("Unable to read current desired snapshot before VPN start: \(error.localizedDescription)")
            return nil
        }
    }

    private func persistDesiredStartOptions(
        _ options: [String: NSObject],
        expectedCurrent: [String: NSObject]?
    ) throws {
        let url = FilePath.sharedDirectory.appendingPathComponent(ExtensionStartOptions.snapshotFileName)
        try ExtensionStartOptions.writeSnapshot(options, to: url, expectedCurrent: expectedCurrent)
    }

    private static func validateConfiguration(_ content: String) async throws {
        let errorMessage = await Task.detached(priority: .utility) {
            var error: NSError?
            LibboxCheckConfig(content, &error)
            return error?.localizedDescription
        }.value
        if let errorMessage {
            throw NSError(domain: "ExtensionProfile.ConfigValidation", code: 1, userInfo: [
                NSLocalizedDescriptionKey: errorMessage,
            ])
        }
    }

    public func reloadService() async throws {
        if isMock {
            return
        }
        let options = try await prepareStartOptions()
        let data = try ExtensionStartOptions.encode(options)
        guard let session = connection as? NETunnelProviderSession else {
            throw NSError(domain: "ExtensionStartOptions", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Tunnel session unavailable",
            ])
        }
        let response = try await withCheckedThrowingContinuation { continuation in
            do {
                try session.sendProviderMessage(data) { response in
                    continuation.resume(returning: response)
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
        if let response, !response.isEmpty {
            let message = String(data: response, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "ExtensionStartOptions", code: -1, userInfo: [
                NSLocalizedDescriptionKey: message,
            ])
        }
        // The Packet Tunnel provider atomically commits the desired snapshot
        // before acknowledging this message. Do not perform a second, unlocked
        // host-side write that could overwrite a newer concurrent update.
    }

    private func prepareStartOptions() async throws -> [String: NSObject] {
        var options: [String: NSObject] = [
            "manualStart": NSNumber(value: true),
            "locale": NSString(string: ApplicationLocale.preferredIdentifier),
        ]

        let profileID = await SharedPreferences.selectedProfileID.get()
        guard let profile = try await ProfileManager.get(profileID) else {
            throw NSError(domain: "ExtensionProfile", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Missing selected profile",
            ])
        }

        let originalContent = try await profile.readAsync()
        let lxSettings = await SharedPreferences.lxOverridesJSON.get()
        let configContent = try LXProfileOverrides.apply(originalContent, profileID: profileID, storedJSON: lxSettings)
        try await Self.validateConfiguration(configContent)
        options["profileID"] = NSNumber(value: profileID)
        options["configContent"] = NSString(string: configContent)

        #if os(macOS)
            options["oomKillerEnabled"] = await NSNumber(value: SharedPreferences.oomKillerEnabled.get())
            options["oomMemoryLimitMB"] = await NSNumber(value: SharedPreferences.oomMemoryLimitMB.get())
            options["oomKillerKillConnections"] = await NSNumber(value: SharedPreferences.oomKillerKillConnections.get())
        #endif
        options["powerReportEnabled"] = await NSNumber(value: SharedPreferences.powerReportEnabled.get())
        options["systemProxyEnabled"] = await NSNumber(value: SharedPreferences.systemProxyEnabled.get())
        options["excludeDefaultRoute"] = await NSNumber(value: SharedPreferences.excludeDefaultRoute.get())
        options["autoRouteUseSubRangesByDefault"] = await NSNumber(value: SharedPreferences.autoRouteUseSubRangesByDefault.get())
        options["excludeAPNsRoute"] = await NSNumber(value: SharedPreferences.excludeAPNsRoute.get())

        #if !os(tvOS)
            options["includeAllNetworks"] = await NSNumber(value: SharedPreferences.includeAllNetworks.get())
        #endif

        #if os(iOS)
            // Forward the same per-install loopback credentials as the host's
            // LibboxSetup. The tunnel must never create an unauthenticated TCP
            // command endpoint, and a signed IPA contains no fixed secret.
            if IsolatedCommandTransport.isRequired {
                let channel = try IsolatedCommandTransport.credentials()
                options["commandServerPort"] = NSNumber(value: channel.port)
                options["commandServerSecret"] = NSString(string: channel.secret)
            }
        #elseif os(tvOS)
            options["commandServerPort"] = await NSNumber(value: SharedPreferences.commandServerPort.get())
            options["commandServerSecret"] = await NSString(string: SharedPreferences.commandServerSecret.get())
        #endif

        return options
    }

    public func fetchProfile() async throws {
        let profileID = await SharedPreferences.selectedProfileID.get()
        if let profile = try await ProfileManager.get(profileID), profile.type == .icloud {
            _ = try await profile.readAsync()
        }
    }

    public func stop() async throws {
        if isMock {
            status = .disconnecting
            try await Task.sleep(nanoseconds: 300_000_000)
            status = .disconnected
            connectedDate = nil
            return
        }
        guard let manager else { return }
        if manager.isOnDemandEnabled {
            if let proto = manager.protocolConfiguration as? NETunnelProviderProtocol {
                var config = proto.providerConfiguration ?? [:]
                config["wasOnDemandEnabled"] = true
                proto.providerConfiguration = config
            }
            manager.isOnDemandEnabled = false
            try await manager.saveToPreferences()
        }
        do {
            try await Task.detached(priority: .userInitiated) {
                try LibboxNewStandaloneCommandClient()!.serviceClose()
            }.value
        } catch {
            logger.debug("serviceClose error: \(error.localizedDescription)")
        }
        manager.connection.stopVPNTunnel()
    }

    public func restart() async throws {
        if isMock {
            try await stop()
            try await start()
            return
        }
        // Keep old desired/last-good until a new connection is confirmed.
        let expectedDesiredOptions = currentDesiredStartOptionsForWrite()
        let options = try await prepareStartOptions()
        try await stop()
        var waitSeconds = 0
        while status != .disconnected {
            try await Task.sleep(nanoseconds: NSEC_PER_SEC)
            waitSeconds += 1
            if waitSeconds >= 5 {
                throw NSError(domain: "ExtensionProfile", code: 0, userInfo: [NSLocalizedDescriptionKey: String(localized: "Restart service timeout")])
            }
        }
        do {
            try await start(with: options)
            try await awaitConnected()
        } catch {
            throw await makeStartDiagnosticError(error, fallbackStage: "restart / wait for connected")
        }
        if FilePath.hasSharedContainer {
            do {
                try persistDesiredStartOptions(options, expectedCurrent: expectedDesiredOptions)
            } catch {
                // The new tunnel is already connected; do not misreport it as
                // disconnected solely because the shared snapshot could not sync.
                logger.warning("VPN restarted, but desired snapshot was not updated: \(error.localizedDescription)")
            }
        }
    }

    public static func load() async throws -> ExtensionProfile? {
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        // A re-signed installation must never attach to another application's
        // NE manager or an obsolete provider from a previous signing identity.
        let expectedIDs = Set(AppConfiguration.packetTunnelBundleIDs)
        guard let owned = managers.first(where: {
            guard let tunnel = $0.protocolConfiguration as? NETunnelProviderProtocol,
                  let provider = tunnel.providerBundleIdentifier else { return false }
            return expectedIDs.contains(provider)
        }) else { return nil }
        let profile = ExtensionProfile(owned)
        if profile.status == .disconnected {
            schedulePromoteOOMDraft()
        }
        return profile
    }

    public static func install() async throws {
        #if os(iOS)
            // Do not reject VPN installation based solely on App Group
            // signatures: NETunnelProviderManager is the authority for whether
            // the current provisioning profile permits Packet Tunnel.
            if !FilePath.hasSharedContainer {
                logger.warning("Installing VPN without App Group; isolated start required: \(AppConfiguration.signingDiagnostics)")
            }
        #else
            guard FilePath.hasSharedContainer else {
                throw NSError(domain: "SigningCompatibility", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Shared application container is unavailable.",
                ])
            }
        #endif
        let manager = NETunnelProviderManager()
        manager.localizedDescription = Variant.applicationName
        let tunnelProtocol = NETunnelProviderProtocol()
        if Variant.useSystemExtension {
            tunnelProtocol.providerBundleIdentifier = AppConfiguration.systemExtensionBundleID
        } else {
            tunnelProtocol.providerBundleIdentifier = AppConfiguration.extensionBundleID
        }
        tunnelProtocol.serverAddress = "sing-box"
        manager.protocolConfiguration = tunnelProtocol
        manager.isEnabled = true
        try await manager.saveToPreferences()
        // Ensure the first start uses the registered configuration, not a
        // stale in-memory manager from before the system VPN approval.
        try await manager.loadFromPreferences()
    }
}
