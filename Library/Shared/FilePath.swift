import Foundation

public enum FilePath {
    public static let packageName = AppConfiguration.packageName
    public static let groupName = AppConfiguration.appGroupID

    private static let sharedContainerURL: URL? = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupName)

    /// True when this process is signed with an app group it can actually access.
    /// The VPN tunnel requires the shared container; without it the app stays
    /// usable (settings, diagnostics) but the tunnel cannot run.
    public static let hasSharedContainer: Bool = sharedContainerURL != nil

    private static let defaultSharedDirectory: URL = {
        if let url = sharedContainerURL {
            return url
        }
        // No usable app group (e.g. the re-signing profile has none): fall back to
        // process-local storage so the app does not crash at launch. Note that the
        // main app and the extension have separate local containers, so they cannot
        // exchange data through this fallback - VPN is unavailable in this state.
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    #if os(iOS)
        public static let sharedDirectory = defaultSharedDirectory
    #elseif os(tvOS)
        public static let sharedDirectory = defaultSharedDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Caches", isDirectory: true)
    #elseif os(macOS)
        public static var sharedDirectory: URL = defaultSharedDirectory
    #endif

    #if os(iOS)
        public static let cacheDirectory = sharedDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Caches", isDirectory: true)
    #elseif os(tvOS)
        public static let cacheDirectory = sharedDirectory
    #elseif os(macOS)
        public static var cacheDirectory: URL {
            sharedDirectory
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Caches", isDirectory: true)
        }
    #endif

    #if os(macOS)
        public static var workingDirectory: URL {
            cacheDirectory.appendingPathComponent("Working", isDirectory: true)
        }
    #else
        public static let workingDirectory = cacheDirectory.appendingPathComponent("Working", isDirectory: true)

    #endif

    public static var iCloudDirectory = FileManager.default.url(forUbiquityContainerIdentifier: nil)?.appendingPathComponent("Documents", isDirectory: true) ?? URL(string: "stub")!
}

public extension URL {
    var fileName: String {
        var path = relativePath
        if let index = path.lastIndex(of: "/") {
            path = String(path[path.index(index, offsetBy: 1)...])
        }
        return path
    }
}
