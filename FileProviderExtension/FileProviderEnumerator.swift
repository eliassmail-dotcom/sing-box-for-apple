import FileProvider

class FileProviderEnumerator: NSObject, NSFileProviderEnumerator {
    private let directoryURL: URL?
    private let workingDirectory: URL
    private let isWorkingSet: Bool

    init(url: URL, workingDirectory: URL) {
        directoryURL = url
        self.workingDirectory = workingDirectory
        isWorkingSet = false
        super.init()
    }

    init(workingSet: Bool, workingDirectory: URL) {
        directoryURL = nil
        self.workingDirectory = workingDirectory
        isWorkingSet = workingSet
        super.init()
    }

    func invalidate() {}

    /// Records the outcome of a directory read: item count on success, the
    /// NSError domain/code on failure. Behavior is unchanged - a failed read
    /// still produces an empty result - but it is no longer silent.
    /// `kind` distinguishes the enumerator path, `depth` marks the recursive
    /// working-set walk (only the top level is recorded, not every directory).
    private func recordEnumeration(kind: String, contents: [URL]?, error: (any Error)?) {
        if let error {
            let nsError = error as NSError
            DiagnosticsLog.record("fpx.enumerate.read", result: .fail, operation: kind.isEmpty ? nil : kind,
                                   errorDomain: nsError.domain, errorCode: nsError.code)
        } else {
            DiagnosticsLog.record("fpx.enumerate.read", result: .pass, operation: kind.isEmpty ? nil : kind,
                                   details: "kind=\(kind) items=\(contents?.count ?? 0)")
        }
    }

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt _: NSFileProviderPage) {
        guard !isWorkingSet else {
            var allItems: [FileProviderItem] = []
            enumerateRecursively(at: workingDirectory, into: &allItems, depth: 0)
            DiagnosticsLog.record("fpx.enumerate", details: "kind=workingSet items=\(allItems.count)")
            observer.didEnumerate(allItems)
            observer.finishEnumerating(upTo: nil)
            return
        }

        guard let url = directoryURL else {
            observer.finishEnumerating(upTo: nil)
            return
        }

        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
            recordEnumeration(kind: "items", contents: contents, error: nil)
        } catch {
            recordEnumeration(kind: "items", contents: nil, error: error)
            contents = []
        }

        let items: [FileProviderItem] = contents.map { childURL in
            let identifier = itemIdentifier(for: childURL)
            return FileProviderItem(url: childURL, identifier: identifier, workingDirectory: workingDirectory)
        }

        observer.didEnumerate(items)
        observer.finishEnumerating(upTo: nil)
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from _: NSFileProviderSyncAnchor) {
        var allItems: [FileProviderItem] = []

        if isWorkingSet {
            enumerateRecursively(at: workingDirectory, into: &allItems, depth: 0)
        } else if let url = directoryURL {
            let contents: [URL]
            do {
                contents = try FileManager.default.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )
                recordEnumeration(kind: "changes", contents: contents, error: nil)
            } catch {
                recordEnumeration(kind: "changes", contents: nil, error: error)
                contents = []
            }

            allItems = contents.map { childURL in
                let identifier = itemIdentifier(for: childURL)
                return FileProviderItem(url: childURL, identifier: identifier, workingDirectory: workingDirectory)
            }
        }

        observer.didUpdate(allItems)
        observer.finishEnumeratingChanges(upTo: currentSyncAnchor(), moreComing: false)
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(currentSyncAnchor())
    }

    // MARK: - Helpers

    private func currentSyncAnchor() -> NSFileProviderSyncAnchor {
        let timestamp = Date().timeIntervalSince1970
        return NSFileProviderSyncAnchor(withUnsafeBytes(of: timestamp) { Data($0) })
    }

    private func itemIdentifier(for url: URL) -> NSFileProviderItemIdentifier {
        let relativePath = url.path.replacingOccurrences(of: workingDirectory.path + "/", with: "")
        if relativePath == url.path || relativePath.isEmpty {
            return .rootContainer
        }
        return NSFileProviderItemIdentifier(relativePath)
    }

    private func enumerateRecursively(at url: URL, into items: inout [FileProviderItem], depth: Int) {
        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            if depth == 0 {
                recordEnumeration(kind: "recursive", contents: contents, error: nil)
            }
        } catch {
            if depth == 0 {
                recordEnumeration(kind: "recursive", contents: nil, error: error)
            }
            return
        }

        for childURL in contents {
            let identifier = itemIdentifier(for: childURL)
            items.append(FileProviderItem(url: childURL, identifier: identifier, workingDirectory: workingDirectory))

            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: childURL.path, isDirectory: &isDir), isDir.boolValue {
                enumerateRecursively(at: childURL, into: &items, depth: depth + 1)
            }
        }
    }
}
