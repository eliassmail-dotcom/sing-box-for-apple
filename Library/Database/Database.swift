import Foundation
import GRDB

enum Database {
    static let sharedWriter = makeShared()

    private static func makeShared() -> any DatabaseWriter {
        do {
            let source: URL?
            #if os(iOS) && !JAILBREAK
            source = Bundle.main.bundleURL.pathExtension == "app" && FilePath.hasSharedContainer
                ? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first : nil
            #else
            source = nil
            #endif
            return try open(directory: FilePath.sharedDirectory, importing: source)
        } catch {
            fatalError(error.localizedDescription)
        }
    }

    static func open(directory: URL, importing source: URL?) throws -> any DatabaseWriter {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try DatabasePool(path: directory.appendingPathComponent("settings.db").path)
        var migrator = DatabaseMigrator().disablingDeferredForeignKeyChecks()
        migrator.registerMigration("initialize") { db in
            try db.create(table: "profiles") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("order", .integer).notNull()
                t.column("type", .integer).notNull().defaults(to: ProfileType.local.rawValue)
                t.column("path", .text).notNull()
                t.column("remoteURL", .text)
                t.column("autoUpdate", .boolean).notNull().defaults(to: false)
                t.column("lastUpdated", .datetime)
            }
            try db.create(table: "preferences") { t in
                t.primaryKey("name", .text, onConflict: .replace).notNull()
                t.column("data", .blob)
            }
        }
        migrator.registerMigration("add_auto_update_interval") { db in
            try db.alter(table: "profiles") { t in
                t.add(column: "autoUpdateInterval", .integer).notNull().defaults(to: 0)
            }
        }
        migrator.registerMigration("fix_cellular_typo") { db in
            try db.execute(sql: "UPDATE preferences SET name = 'exclude_cellular_services' WHERE name = 'exclude_celluar_services'")
        }
        migrator.registerMigration("use_relative_profile_paths") { db in
            let rows = try Row.fetchAll(db, sql: "SELECT id, path, type FROM profiles")
            let prefix = directory.path.hasSuffix("/") ? directory.path : directory.path + "/"
            for row in rows {
                let id: Int64 = row["id"]
                let path: String = row["path"]
                let type: Int = row["type"]
                if type == ProfileType.icloud.rawValue {
                    continue
                }
                guard path.hasPrefix("/") else { continue }
                var newPath = path
                if path.hasPrefix(prefix) {
                    newPath = String(path.dropFirst(prefix.count))
                } else if let range = path.range(of: "configs/config_") {
                    newPath = String(path[range.lowerBound...])
                }
                if newPath != path {
                    try db.execute(sql: "UPDATE profiles SET path = ? WHERE id = ?", arguments: [newPath, id])
                }
            }
        }
        migrator.registerMigration("add_remote_servers") { db in
            try db.create(table: "remote_servers") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("order", .integer).notNull()
                t.column("url", .text).notNull()
                t.column("secret", .text).notNull().defaults(to: "")
            }
        }
        try migrator.migrate(database)
        #if os(iOS) && !JAILBREAK
        if let legacy = source {
            do {
                let state = try IsolatedStoreImport.run(source: legacy, destination: directory, writer: database)
                DiagnosticsLog.record("storage.privateImport", result: .pass, details: state)
            } catch {
                let failure = error as NSError
                // The target transaction rolled back; the original remains intact for a retry.
                DiagnosticsLog.record("storage.privateImport", result: .fail, errorDomain: failure.domain, errorCode: failure.code)
            }
        }
        #endif
        return database
    }
}
