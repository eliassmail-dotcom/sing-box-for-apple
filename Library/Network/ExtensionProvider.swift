import Foundation
import Libbox
import NetworkExtension
import os.log
#if os(iOS)
    import WidgetKit
#endif
#if os(macOS)
    import CoreLocation
#endif

// Small, versioned command sent by the Control Center widget via
// NETunnelProviderSession.sendProviderMessage. Keep separate from the
// existing start-options payload; never reload the VPN for a node change.
private struct LXWidgetControlRequest: Decodable {
    let lxControl: String
    let version: Int
}

open class ExtensionProvider: NEPacketTunnelProvider {
    private static let logger = Logger(category: "ExtensionProvider")

    public private(set) var commandServer: LibboxCommandServer?
    private lazy var platformInterface = ExtensionPlatformInterface(self)
    public var tunnelOptions: [String: NSObject]?
    private var startOptionsURL: URL?
    private var lastGoodStartOptionsURL: URL?

    public struct OverridePreferences {
        public var includeAllNetworks: Bool = false
        public var systemProxyEnabled: Bool = true
        public var excludeDefaultRoute: Bool = false
        public var autoRouteUseSubRangesByDefault: Bool = false
        public var excludeAPNsRoute: Bool = false
    }

    public var overridePreferences: OverridePreferences?
    #if os(iOS)
        private var screenStateObserver: ScreenStateObserver?
    #endif

    private func applyStartOptions(_ options: [String: NSObject]) throws {
        try ApplicationLocale.apply(options["locale"] as? String)
        tunnelOptions = options
        overridePreferences = OverridePreferences(
            includeAllNetworks: (options["includeAllNetworks"] as? NSNumber)?.boolValue ?? false,
            systemProxyEnabled: (options["systemProxyEnabled"] as? NSNumber)?.boolValue ?? true,
            excludeDefaultRoute: (options["excludeDefaultRoute"] as? NSNumber)?.boolValue ?? false,
            autoRouteUseSubRangesByDefault: (options["autoRouteUseSubRangesByDefault"] as? NSNumber)?.boolValue ?? false,
            excludeAPNsRoute: (options["excludeAPNsRoute"] as? NSNumber)?.boolValue ?? false
        )
    }

    private func platformMetadata() -> String {
        var metadata: [String: Any] = [:]
        #if !os(tvOS)
            var networkExtension: [String: Any] = [
                "includeAllNetworks": protocolConfiguration.includeAllNetworks,
                "excludeLocalNetworks": protocolConfiguration.excludeLocalNetworks,
                "enforceRoutes": protocolConfiguration.enforceRoutes,
            ]
            if #available(iOS 16.4, macOS 13.3, *) {
                networkExtension["excludeAPNs"] = protocolConfiguration.excludeAPNs
                networkExtension["excludeCellularServices"] = protocolConfiguration.excludeCellularServices
            }
            if #available(iOS 17.4, macOS 14.4, *) {
                networkExtension["excludeDeviceCommunication"] = protocolConfiguration.excludeDeviceCommunication
            }
            metadata["networkExtension"] = networkExtension
        #endif
        if let overridePreferences {
            metadata["profileOverride"] = [
                "systemProxyEnabled": overridePreferences.systemProxyEnabled,
                "excludeDefaultRoute": overridePreferences.excludeDefaultRoute,
                "autoRouteUseSubRangesByDefault": overridePreferences.autoRouteUseSubRangesByDefault,
                "excludeAPNsRoute": overridePreferences.excludeAPNsRoute,
            ]
        }
        return PlatformMetadata.json(metadata)
    }

    private func persistLastGoodStartOptions(_ options: [String: NSObject]) throws {
        guard let lastGoodStartOptionsURL else { return }
        let data = try ExtensionStartOptions.encode(options)
        try data.write(to: lastGoodStartOptionsURL, options: .atomic)
    }

    private func loadStartOptions(from url: URL?) throws -> [String: NSObject]? {
        guard let url, FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        let data = try Data(contentsOf: url)
        return try ExtensionStartOptions.decode(data)
    }

    private func loadPersistedStartOptions() throws -> [String: NSObject]? {
        try loadStartOptions(from: startOptionsURL)
    }

    private func loadLastGoodStartOptions() throws -> [String: NSObject]? {
        try loadStartOptions(from: lastGoodStartOptionsURL)
    }

    private func validateStartOptions(_ options: [String: NSObject]) throws {
        guard let configContent = options["configContent"] as? String else {
            throw ExtensionStartupError("(packet-tunnel) error: missing configContent in tunnel options")
        }
        var error: NSError?
        LibboxCheckConfig(configContent, &error)
        if let error {
            throw ExtensionStartupError("(packet-tunnel) error: validate config: \(error.localizedDescription)")
        }
    }

    private func resolveStartOptions(_ startOptions: [String: NSObject]?) throws -> [String: NSObject] {
        if let startOptions, startOptions["configContent"] as? String != nil {
            return startOptions
        }
        // The desired snapshot is refreshed by the app whenever the selected
        // profile or its overrides change. If it is damaged or no longer valid,
        // retain the last successfully started configuration.
        if let desired = try? loadPersistedStartOptions() {
            do {
                try validateStartOptions(desired)
                return desired
            } catch {
                Self.logger.error("Desired start snapshot rejected: \(error.localizedDescription)")
            }
        }
        if let lastGood = try? loadLastGoodStartOptions() {
            try validateStartOptions(lastGood)
            return lastGood
        }
        #if os(iOS)
            if !FilePath.hasSharedContainer {
                throw ExtensionStartupError(
                    "(packet-tunnel) error: no saved configuration in isolated mode. Open the app and start VPN once from Dashboard before using Control Center or On Demand."
                )
            }
        #endif
        throw ExtensionStartupError("(packet-tunnel) error: missing valid start options")
    }

    #if os(macOS)
        private var xpcListener: NSXPCListener!
        private var xpcService: CommandXPCService!
        private var locationManager: CLLocationManager?
        private var locationDelegate: stubLocationDelegate?
    #endif

    override public init() {
        LibboxPrepareCrashSignalHandlers()
        #if os(macOS)
            if Variant.useSystemExtension {
                NativeCrashReporter.installForCurrentProcess(
                    basePath: FileManager.default.homeDirectoryForCurrentUser
                        .appendingPathComponent("NativeCrash")
                )
            } else {
                NativeCrashReporter.installForCurrentProcess()
            }
        #else
            NativeCrashReporter.installForCurrentProcess()
        #endif
        LibboxReinstallCrashSignalHandlers()
        super.init()
    }

    override open func startTunnel(options startOptions: [String: NSObject]?) async throws {
        #if os(iOS)
            // The validated config is supplied by the containing app through
            // startVPNTunnel(options:). A missing App Group is NOT fatal to
            // packet-tunnel setup: use this extension's private Application
            // Support container and keep its own last-good startup snapshot.
            if !FilePath.hasSharedContainer {
                Self.logger.warning("Packet Tunnel using process-local storage (no shared App Group): \(AppConfiguration.signingDiagnostics)")
            }
        #endif
        let basePath: String
        let workingPath: String
        let tempPath: String

        #if os(macOS)
            if Variant.useSystemExtension {
                let containerURL = FileManager.default.homeDirectoryForCurrentUser
                basePath = containerURL.path
                workingPath = containerURL.appendingPathComponent("Working").path
                tempPath = containerURL.appendingPathComponent("Temp").path
            } else {
                basePath = FilePath.sharedDirectory.relativePath
                workingPath = FilePath.workingDirectory.relativePath
                tempPath = FilePath.cacheDirectory.relativePath
            }
        #else
            basePath = FilePath.sharedDirectory.relativePath
            workingPath = FilePath.workingDirectory.relativePath
            tempPath = FilePath.cacheDirectory.relativePath
        #endif

        startOptionsURL = URL(fileURLWithPath: basePath).appendingPathComponent(ExtensionStartOptions.snapshotFileName)
        lastGoodStartOptionsURL = URL(fileURLWithPath: basePath).appendingPathComponent(ExtensionStartOptions.lastGoodSnapshotFileName)

        #if os(macOS)
            if Variant.useSystemExtension {
                let socketPath = basePath + "/command.sock"
                let machServiceName = AppConfiguration.systemExtensionMachServiceName
                xpcService = CommandXPCService(socketPath: socketPath)
                xpcListener = NSXPCListener(machServiceName: machServiceName)
                xpcListener.delegate = xpcService
            }
        #endif

        let effectiveOptions = try resolveStartOptions(startOptions)
        try validateStartOptions(effectiveOptions)
        try applyStartOptions(effectiveOptions)
        let options = LibboxSetupOptions()
        options.basePath = basePath
        options.workingPath = workingPath
        options.tempPath = tempPath

        options.logMaxLines = 3000
        options.debug = Variant.inDebug
        options.crashReportSource = "NetworkExtension"
        options.appVersion = Bundle.application.versionNumber
        options.appMarketingVersion = Bundle.application.version
        options.platformMetadata = platformMetadata()

        #if os(tvOS)
            if let port = effectiveOptions["commandServerPort"] as? NSNumber {
                options.commandServerListenPort = port.int32Value
            }
            if let secret = effectiveOptions["commandServerSecret"] as? String {
                options.commandServerSecret = secret
            }
        #endif

        #if os(macOS)
            options.oomKillerEnabled = (effectiveOptions["oomKillerEnabled"] as? NSNumber)?.boolValue ?? false
            let oomMemoryLimitMB = (effectiveOptions["oomMemoryLimitMB"] as? NSNumber)?.int64Value ?? 0
            options.oomMemoryLimit = oomMemoryLimitMB * 1024 * 1024
            options.oomKillerDisabled = !((effectiveOptions["oomKillerKillConnections"] as? NSNumber)?.boolValue ?? false)
        #else
            options.oomKillerEnabled = true
        #endif
        options.powerReportEnabled = (effectiveOptions["powerReportEnabled"] as? NSNumber)?.boolValue ?? false

        var setupError: NSError?
        LibboxSetup(options, &setupError)
        if let setupError {
            throw ExtensionStartupError("(packet-tunnel) error: setup service: \(setupError.localizedDescription)")
        }
        LibboxPromoteOOMDraft()
        LibboxDiscardPowerReportDraft()

        var error: NSError?
        commandServer = LibboxNewCommandServer(platformInterface, platformInterface, &error)
        if let error {
            throw ExtensionStartupError("(packet-tunnel): create command server error: \(error.localizedDescription)")
        }
        do {
            try commandServer!.start()
        } catch {
            throw ExtensionStartupError("(packet-tunnel): start command server error: \(error.localizedDescription)")
        }

        #if os(macOS)
            if Variant.useSystemExtension {
                xpcListener.resume()
                Self.logger.info("set Command Server")
                xpcService.commandServer = commandServer
            }
        #endif

        do {
            try await startService()
        } catch {
            #if os(macOS)
                if Variant.useSystemExtension {
                    xpcService.markServiceNotReady(error)
                }
            #endif
            throw error
        }
        // Promote only after the service has actually started. A failed candidate
        // must never replace the previous last-known-good configuration.
        do {
            try persistLastGoodStartOptions(effectiveOptions)
        } catch {
            Self.logger.error("Unable to persist last-good start options: \(error.localizedDescription)")
        }
        writeMessage("(packet-tunnel): Here I stand")
        #if os(iOS)
            if let commandServer {
                screenStateObserver = ScreenStateObserver(commandServer: commandServer)
            }
        #endif
        #if os(macOS)
            if Variant.useSystemExtension {
                xpcService.markServiceReady()
            }
        #endif
        #if os(iOS)
            if #available(iOS 18.0, *) {
                ControlCenter.shared.reloadControls(ofKind: ExtensionProfile.controlKind)
            }
        #endif
    }

    func writeMessage(_ message: String, level: LogLevel = .error) {
        if let commandServer {
            commandServer.writeMessage(Int32(level.rawValue), message: message)
        }
    }

    private func startService() async throws {
        guard let configContent = tunnelOptions?["configContent"] as? String else {
            throw ExtensionStartupError("(packet-tunnel) error: missing configContent in tunnel options")
        }

        let options = LibboxOverrideOptions()
        do {
            try commandServer!.startOrReloadService(configContent, options: options)
        } catch {
            throw ExtensionStartupError("(packet-tunnel) error: start service: \(error.localizedDescription)")
        }
        #if os(macOS)
            if !Variant.useSystemExtension, commandServer!.needWIFIState() {
                locationManager = CLLocationManager()
                locationDelegate = stubLocationDelegate()
                locationManager!.delegate = locationDelegate
                locationManager!.requestLocation()
            }
        #endif
    }

    #if os(macOS)

        class stubLocationDelegate: NSObject, CLLocationManagerDelegate {
            func locationManagerDidChangeAuthorization(_: CLLocationManager) {}

            func locationManager(_: CLLocationManager, didUpdateLocations _: [CLLocation]) {}

            func locationManager(_: CLLocationManager, didFailWithError _: Error) {}
        }

    #endif

    func stopService() {
        do {
            try commandServer?.closeService()
        } catch {
            writeMessage("(packet-tunnel) stop service: \(error.localizedDescription)")
        }
        platformInterface.reset()
    }

    func reloadService() async throws {
        writeMessage("(packet-tunnel) reloading service")
        reasserting = true
        defer {
            reasserting = false
        }
        try await startService()
    }

    override open func stopTunnel(with reason: NEProviderStopReason) async {
        writeMessage("(packet-tunnel) stopping, reason: \(reason)")
        #if os(iOS)
            screenStateObserver?.cancel()
            screenStateObserver = nil
        #endif
        stopService()
        if let server = commandServer {
            try? await Task.sleep(nanoseconds: 100 * NSEC_PER_MSEC)
            server.close()
            commandServer = nil
        }
        #if os(macOS)
            if Variant.useSystemExtension {
                xpcService.markServiceNotReady(NSError(domain: "CommandXPC", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: "Command server stopped",
                ]))
                xpcListener.invalidate()
                xpcListener = nil
                xpcService.commandServer = nil
                xpcService = nil
            }
            locationManager = nil
            locationDelegate = nil
        #endif
        #if os(iOS)
            if #available(iOS 18.0, *) {
                ControlCenter.shared.reloadControls(ofKind: ExtensionProfile.controlKind)
            }
        #endif
    }

    private static func widgetControlReply(
        ok: Bool, error: String? = nil, previousNode: String? = nil, selectedNode: String? = nil
    ) -> Data {
        var payload: [String: Any] = [
            "ok": ok,
            "error": error ?? "",
        ]
        if let previousNode { payload["previousNode"] = previousNode }
        if let selectedNode { payload["selectedNode"] = selectedNode }
        return (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
    }

    /// Process the active Strategy group's *current* selected child. Both the
    /// Dashboard and the Control Center use the same LX command for URLTest,
    /// so Smart base/white preference and 30-second healthy-node hold are
    /// enforced by the core, not duplicated in a widget process.
    private static func snapshotGroups(_ client: LibboxCommandClient) throws -> [OutboundGroup] {
        let iterator = try client.getGroups()
        var groups: [OutboundGroup] = []
        while iterator.hasNext() {
            if let group = iterator.next() {
                groups.append(OutboundGroup(group))
            }
        }
        return groups
    }

    private static func changeActiveNode() throws -> (previousNode: String, selectedNode: String) {
        let client = try CommandTarget.standaloneClient()
        let groups = try snapshotGroups(client)
        guard let previousNode = LXNextNodeSelection.activeLeafTag(in: groups) else {
            throw ExtensionStartupError("LX: текущий узел не определён")
        }
        guard let strategy = groups.first(where: { $0.tag == LXNextNodeSelection.strategyGroupTag }),
              strategy.type == "selector",
              let active = groups.first(where: { $0.tag == strategy.selected }) else {
            throw ExtensionStartupError("LX: активная стратегия не найдена")
        }

        switch active.type {
        case "urltest":
            // The Go URLTest group rotates the leaf of the active tier.
            // Strategy, Gemini and established connections stay unchanged.
            try client.selectOutbound(active.tag, outboundTag: LXNextNodeSelection.commandTag)
        case "selector":
            guard let next = LXNextNodeSelection.nextHealthyTag(
                current: active.selected,
                candidates: active.items.map { (tag: $0.tag, delayMs: $0.urlTestDelay) }
            ) else {
                throw ExtensionStartupError("В выбранном режиме нет другого доступного узла")
            }
            try client.selectOutbound(active.tag, outboundTag: next)
        default:
            throw ExtensionStartupError("Этот режим не поддерживает ручную смену узла")
        }

        // A successful RPC alone is not sufficient: verify the *live* route,
        // including nested Smart base -> white -> leaf groups. This prevents
        // the widget from reporting success when Dashboard still shows the
        // previous node.
        let updatedGroups = try snapshotGroups(client)
        guard let selectedNode = LXNextNodeSelection.activeLeafTag(in: updatedGroups),
              selectedNode != previousNode else {
            throw ExtensionStartupError("Команда отправлена, но активный узел не изменился")
        }
        return (previousNode, selectedNode)
    }

    override open func handleAppMessage(_ messageData: Data) async -> Data? {
        // The control command must be recognized BEFORE the legacy settings
        // decoder. Otherwise a widget tap would trigger reloadService().
        if let request = try? JSONDecoder().decode(LXWidgetControlRequest.self, from: messageData) {
            guard request.version == 1, request.lxControl == "changeNode" else {
                return Self.widgetControlReply(ok: false, error: "Неизвестная команда LX")
            }
            do {
                let change = try await Task.detached(priority: .userInitiated) {
                    try Self.changeActiveNode()
                }.value
                Self.logger.info("LX next-node widget changed the active leaf")
                return Self.widgetControlReply(
                    ok: true, previousNode: change.previousNode, selectedNode: change.selectedNode
                )
            } catch {
                Self.logger.error("LX next-node widget command failed: \(error.localizedDescription)")
                return Self.widgetControlReply(ok: false, error: error.localizedDescription)
            }
        }
        do {
            let options = try ExtensionStartOptions.decode(messageData)
            try validateStartOptions(options)
            let previousOptions = try? loadLastGoodStartOptions()
            try applyStartOptions(options)
            do {
                try await reloadService()
                try persistLastGoodStartOptions(options)
                return nil
            } catch {
                let applyError = error
                if let previousOptions,
                   (previousOptions["configContent"] as? String) != (options["configContent"] as? String) {
                    do {
                        try validateStartOptions(previousOptions)
                        try applyStartOptions(previousOptions)
                        try await reloadService()
                        try persistLastGoodStartOptions(previousOptions)
                    } catch {
                        throw ExtensionStartupError(
                            "Apply failed: \(applyError.localizedDescription); rollback failed: \(error.localizedDescription)"
                        )
                    }
                }
                throw applyError
            }
        } catch {
            return error.localizedDescription.data(using: .utf8)
        }
    }

    override open func sleep() async {
        if let commandServer {
            commandServer.pause()
        }
    }

    override open func wake() {
        if let commandServer {
            commandServer.wake()
        }
    }
}
