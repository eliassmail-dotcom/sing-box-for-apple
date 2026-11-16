import Foundation
import Libbox
#if os(iOS)
    import Security
#endif

#if os(iOS)
/// Authenticated command transport when the app and packet tunnel do not have
/// access to the same App Group container.
///
/// A private Unix socket cannot connect two distinct iOS sandboxes. Instead,
/// the extension listens on 127.0.0.1, and the app uses exactly the same
/// per-install port and 256-bit bearer secret. No listener is opened on any
/// LAN-facing interface. The secret is generated with SecRandomCopyBytes and
/// is never compiled into the IPA or written to logs.
///
/// A valid App Group and a short Unix socket remain the preferred transport.
public enum IsolatedCommandTransport {
    public struct Credentials {
        public let port: Int32
        public let secret: String
    }

    private static let defaultsKey = "lx_isolated_command_transport_v1"
    private static let lock = NSLock()
    private static let minimumPort: UInt32 = 46_000
    private static let portRange: UInt32 = 16_000

    public static var isRequired: Bool {
        if !FilePath.hasSharedContainer { return true }
        // sockaddr_un.sun_path on Darwin holds at most 103 path bytes + NUL.
        let socketPath = FilePath.sharedDirectory.appendingPathComponent("command.sock").path
        return socketPath.utf8.count > 103
    }

    public static func credentials() throws -> Credentials {
        lock.lock()
        defer { lock.unlock() }

        if let stored = UserDefaults.standard.dictionary(forKey: defaultsKey),
           let port = stored["port"] as? Int,
           let secret = stored["secret"] as? String,
           (46_000...61_999).contains(port),
           let decoded = Data(base64Encoded: secret),
           decoded.count == 32 {
            return Credentials(port: Int32(port), secret: secret)
        }

        var randomness = [UInt8](repeating: 0, count: 34)
        guard SecRandomCopyBytes(kSecRandomDefault, randomness.count, &randomness) == errSecSuccess else {
            throw NSError(domain: "IsolatedCommandTransport", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Unable to generate secure local command credentials",
            ])
        }
        let randomPort = (UInt32(randomness[0]) << 8) | UInt32(randomness[1])
        let port = Int(minimumPort + randomPort % portRange)
        let secret = Data(randomness[2...]).base64EncodedString()
        UserDefaults.standard.set(["port": port, "secret": secret], forKey: defaultsKey)
        return Credentials(port: Int32(port), secret: secret)
    }

    /// Pure validation of tunnel-provided transport options. A port without a
    /// strong secret must NEVER open an unauthenticated localhost gRPC server.
    public static func validCredentials(port: NSNumber?, secret: String?) -> Bool {
        guard let port, let secret,
              (46_000...61_999).contains(port.intValue),
              let decoded = Data(base64Encoded: secret),
              decoded.count == 32 else { return false }
        return true
    }
}
#endif

public enum ServiceSetup {
    public static func apply(crashReportSource: String) throws {
        let options = LibboxSetupOptions()
        options.basePath = FilePath.sharedDirectory.relativePath
        options.workingPath = FilePath.workingDirectory.relativePath
        options.tempPath = FilePath.cacheDirectory.relativePath
        options.crashReportSource = crashReportSource
        options.appVersion = Bundle.application.versionNumber
        options.appMarketingVersion = Bundle.application.version
        options.platformMetadata = PlatformMetadata.json()

        #if os(iOS)
            // When there is no common App Group, opening command.sock in the
            // host's private directory cannot reach the tunnel's socket.
            // Both sides use this matching, authenticated loopback endpoint.
            if IsolatedCommandTransport.isRequired {
                let channel = try IsolatedCommandTransport.credentials()
                options.commandServerListenPort = channel.port
                options.commandServerSecret = channel.secret
            }
        #endif

        var error: NSError?
        LibboxSetup(options, &error)
        if let error {
            throw error
        }
    }
}
