#if os(iOS)
import BinaryCodable
import Foundation
import GRDB

/// b50 stored the host's database and local profiles in its private Application
/// Support when signing was ambiguous. Only the host can import that sandbox.
enum IsolatedStoreImport {
    private static let fm = FileManager.default
    private static let marker = "sfi_imported_private_b50"

    static func run(source: URL, destination: URL, writer: any DatabaseWriter) throws -> String {
        let original = source.appendingPathComponent("settings.db")
        guard source.standardizedFileURL != destination.standardizedFileURL,
              fm.fileExists(atPath: original.path) else { return "noPrivateStore" }
        if try writer.read({ try $0.tableExists(marker) }) { return "alreadyImported" }
        var config = Configuration()
        config.readonly = true
        let reader = try DatabaseQueue(path: original.path, configuration: config)
        // A single SQLite read transaction sees committed WAL frames as well as
        // the main file. Row copies are detached from their SQLite statement.
        let rows = try reader.read { db in
            (profiles: try Row.fetchAll(db, sql: "SELECT * FROM profiles ORDER BY id").map { $0.copy() },
             servers: try Row.fetchAll(db, sql: "SELECT * FROM remote_servers ORDER BY id").map { $0.copy() },
             preferences: try Row.fetchAll(db, sql: "SELECT name,data FROM preferences").map { $0.copy() })
        }
        return try writer.write { db in
            if try db.tableExists(marker) { return "alreadyImported" }
            var importedPaths = [String: String]()
            for dir in ["configs", "fonts", "Library/Caches/Working"] {
                let root = source.appendingPathComponent(dir)
                guard fm.fileExists(atPath: root.path) else { continue }
                try copyTree(dir, source: source, destination: destination, paths: &importedPaths)
            }
            var ids = [Int64: Int64]()
            for row in rows.profiles {
                let oldID: Int64 = row["id"]
                let path: String = row["path"]
                let type: Int = row["type"]
                var replacements = [String: DatabaseValue]()
                if type != ProfileType.icloud.rawValue, let copied = importedPaths[path] {
                    replacements["path"] = copied.databaseValue
                }
                ids[oldID] = try insert(row, table: "profiles", replacing: replacements, db: db)
            }
            for row in rows.servers {
                _ = try insert(row, table: "remote_servers", replacing: [:], db: db)
            }
            for row in rows.preferences {
                let name: String = row["name"]
                var value: Data? = row["data"]
                let existing = try Row.fetchOne(db, sql: "SELECT data FROM preferences WHERE name=?", arguments: [name])
                if [SharedPreferences.lxOverridesJSON.name, SharedPreferences.groupPresentationJSON.name].contains(name),
                   let old = value, !old.isEmpty {
                    let target: Data? = existing?["data"]
                    if ids.contains(where: { $0.key != $0.value }) || (target?.isEmpty == false) {
                        value = try mergeProfiles(old: old, existing: target, ids: ids)
                    }
                } else {
                    if existing != nil { continue }
                    if name == SharedPreferences.selectedProfileID.name, let data = value,
                       let oldID = try? decodeBinary(Int64.self, from: data), let newID = ids[oldID], oldID != newID {
                        value = try BinaryEncoder().encode(newID)
                    }
                }
                try db.execute(sql: "INSERT OR REPLACE INTO preferences(name,data) VALUES(?,?)", arguments: [name, value])
            }
            try db.execute(sql: "CREATE TABLE sfi_imported_private_b50 (completed INTEGER)")
            return "imported profiles=\(ids.count) servers=\(rows.servers.count)"
        }
    }

    private static func insert(_ row: Row, table: String, replacing values: [String: DatabaseValue],
                               db: GRDB.Database) throws -> Int64 {
        let oldID: Int64 = row["id"]
        var replacements = values
        if try Int64.fetchOne(db, sql: "SELECT id FROM \(table) WHERE id=?", arguments: [oldID]) != nil {
            replacements["id"] = .null
        }
        let columns = Array(row.columnNames)
        let names = columns.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: ",")
        let arguments: [DatabaseValue] = columns.map { replacements[$0] ?? row[$0] }
        let placeholders = columns.map { _ in "?" }.joined(separator: ",")
        try db.execute(sql: "INSERT INTO \(table)(\(names)) VALUES(\(placeholders))", arguments: StatementArguments(arguments))
        return db.lastInsertedRowID
    }

    private static func mergeProfiles(old: Data, existing: Data?, ids: [Int64: Int64]) throws -> Data {
        func object(_ data: Data) throws -> [String: Any] {
            guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return value
        }
        let source = try object(old)
        var result = try existing.flatMap { $0.isEmpty ? nil : try object($0) } ?? source
        var profiles = ((existing?.isEmpty == false) ? result["profiles"] as? [String: Any] : nil) ?? [:]
        for (key, value) in source["profiles"] as? [String: Any] ?? [:] {
            if let oldID = Int64(key), let newID = ids[oldID], profiles[String(newID)] == nil {
                profiles[String(newID)] = value
            }
        }
        result["profiles"] = profiles
        return try JSONSerialization.data(withJSONObject: result)
    }

    /// Install a complete file atomically. A retry reuses identical bytes. A
    /// real collision gets its own filename and referenced profile path.
    private static func copyTree(_ path: String, source: URL, destination: URL,
                                 paths: inout [String: String]) throws {
        let input = source.appendingPathComponent(path)
        let values = try input.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true else { return }
        let output = destination.appendingPathComponent(path)
        // Refuse symlink components in the destination, including dangling links.
        let root = destination.resolvingSymlinksInPath().standardizedFileURL.path
        var current = destination
        for component in path.split(separator: "/") {
            current.appendPathComponent(String(component))
            if (try? fm.destinationOfSymbolicLink(atPath: current.path)) != nil { throw CocoaError(.fileWriteNoPermission) }
        }
        guard output.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(root + "/") else {
            throw CocoaError(.fileWriteNoPermission)
        }
        if values.isDirectory == true {
            try fm.createDirectory(at: output, withIntermediateDirectories: true)
            for name in try fm.contentsOfDirectory(atPath: input.path).sorted() {
                try copyTree(path + "/" + name, source: source, destination: destination, paths: &paths)
            }
            return
        }
        guard values.isRegularFile == true else { return }
        let parent = output.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        var candidate = output
        var index = 0
        while fm.fileExists(atPath: candidate.path) || (try? fm.destinationOfSymbolicLink(atPath: candidate.path)) != nil {
            let ordinary = (try? candidate.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false
            if ordinary && fm.contentsEqual(atPath: input.path, andPath: candidate.path) { break }
            index += 1
            let stem = output.deletingPathExtension().lastPathComponent
            let ext = output.pathExtension.isEmpty ? "" : "." + output.pathExtension
            candidate = parent.appendingPathComponent("\(stem) (b50 \(index))\(ext)")
        }
        if !fm.fileExists(atPath: candidate.path) {
            let stage = parent.appendingPathComponent(".sfi-import-" + UUID().uuidString)
            defer { try? fm.removeItem(at: stage) }
            try fm.copyItem(at: input, to: stage)
            try fm.moveItem(at: stage, to: candidate)
        }
        if path.hasPrefix("configs/") {
            paths[path] = String(candidate.path.dropFirst(destination.path.count + 1))
        }
    }
}
#endif
