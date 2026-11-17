import Darwin
import Foundation

enum ExtensionStartOptions {
    static let snapshotFileName = "start_options.plist"
    static let lastGoodSnapshotFileName = "last_good_start_options.plist"

    static func encode(_ options: [String: NSObject]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: options, format: .binary, options: 0)
    }

    static func decode(_ data: Data) throws -> [String: NSObject] {
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let options = plist as? [String: NSObject] else {
            throw NSError(domain: "ExtensionStartOptions", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Invalid start options payload",
            ])
        }
        return options
    }

    static func readSnapshot(from url: URL) throws -> [String: NSObject]? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return try decode(Data(contentsOf: url))
    }

    /// Compare-and-write the complete start-options snapshot under a cross-process
    /// advisory lock. The lock file is stable while the snapshot itself is replaced
    /// atomically, so the app and Packet Tunnel cannot race a stale rollback.
    static func writeSnapshot(
        _ options: [String: NSObject],
        to url: URL,
        expectedCurrent: [String: NSObject]?
    ) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let lockURL = url.appendingPathExtension("lock")
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, mode_t(0o600))
        guard descriptor >= 0 else {
            throw posixError("open snapshot lock")
        }
        defer { _ = Darwin.close(descriptor) }

        guard Darwin.flock(descriptor, LOCK_EX) == 0 else {
            throw posixError("lock snapshot")
        }
        defer { _ = Darwin.flock(descriptor, LOCK_UN) }

        let current = try readSnapshot(from: url)
        let expectedMatches: Bool
        if let current {
            expectedMatches = dictionariesEqual(current, expectedCurrent) ||
                dictionariesEqual(current, options)
        } else {
            expectedMatches = expectedCurrent == nil
        }

        guard expectedMatches else {
            throw NSError(domain: "ExtensionStartOptions.Snapshot", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Desired VPN configuration changed concurrently; refusing to overwrite a newer snapshot.",
            ])
        }

        try encode(options).write(to: url, options: .atomic)
    }

    private static func dictionariesEqual(
        _ lhs: [String: NSObject],
        _ rhs: [String: NSObject]?
    ) -> Bool {
        guard let rhs else { return false }
        return NSDictionary(dictionary: lhs).isEqual(NSDictionary(dictionary: rhs))
    }

    private static func posixError(_ operation: String) -> NSError {
        let code = errno
        return NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [
            NSLocalizedDescriptionKey: "\(operation) failed (errno \(code)).",
        ])
    }
}
