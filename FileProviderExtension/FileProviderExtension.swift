import FileProvider
import UniformTypeIdentifiers

class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension {
    let domain: NSFileProviderDomain

    // File Provider's document group is a signed, static Info.plist value.
    // Never choose an arbitrary group independently from the host application.
    private static let workingDirectoryURL: URL? = {
        guard let extensionInfo = Bundle.main.object(forInfoDictionaryKey: "NSExtension") as? [String: Any],
              let group = extensionInfo["NSExtensionFileProviderDocumentGroup"] as? String,
              !group.isEmpty else {
            NSLog("File Provider: missing NSExtensionFileProviderDocumentGroup")
            return nil
        }
        let signedGroups = SignedEntitlements.stringArray("com.apple.security.application-groups")
        // Some re-signers produce DER-only entitlements. In that case the OS
        // container access check is authoritative; XML parsing is not required.
        if !signedGroups.isEmpty && !signedGroups.contains(group) {
            NSLog("File Provider: document group is not in signed XML entitlements")
            return nil
        }
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
            NSLog("File Provider: signed document group container unavailable")
            return nil
        }
        return container
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Caches", isDirectory: true)
            .appendingPathComponent("Working", isDirectory: true)
    }()

    private func requireWorkingDirectory() throws -> URL {
        guard let directory = Self.workingDirectoryURL else {
            throw NSError(
                domain: "SFI.FileProvider.SigningCompatibility", code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "File Provider document group is unavailable. Check the signed App Group and NSExtensionFileProviderDocumentGroup."]
            )
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        } catch {
            throw NSError(
                domain: "SFI.FileProvider.Storage", code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey: "Unable to access File Provider working directory.",
                    NSUnderlyingErrorKey: error
                ]
            )
        }
    }

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        super.init()
        do {
            _ = try requireWorkingDirectory()
        } catch {
            NSLog("File Provider storage unavailable: \(error)")
        }
    }

    func invalidate() {}

    // MARK: - NSFileProviderReplicatedExtension

    func item(for identifier: NSFileProviderItemIdentifier,
              request _: NSFileProviderRequest,
              completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress
    {
        let progress = Progress(totalUnitCount: 1)
        let workingDirectory: URL
        do {
            workingDirectory = try requireWorkingDirectory()
        } catch {
            completionHandler(nil, error)
            return progress
        }

        if identifier == .rootContainer {
            completionHandler(FileProviderItem(rootAt: workingDirectory), nil)
        } else {
            let url = fileURL(for: identifier, workingDirectory: workingDirectory)
            if FileManager.default.fileExists(atPath: url.path) {
                completionHandler(FileProviderItem(url: url, identifier: identifier, workingDirectory: workingDirectory), nil)
            } else {
                completionHandler(nil, NSFileProviderError(.noSuchItem))
            }
        }

        progress.completedUnitCount = 1
        return progress
    }

    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier,
                       version _: NSFileProviderItemVersion?,
                       request _: NSFileProviderRequest,
                       completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress
    {
        let progress = Progress(totalUnitCount: 100)
        let workingDirectory: URL
        do {
            workingDirectory = try requireWorkingDirectory()
        } catch {
            completionHandler(nil, nil, error)
            return progress
        }

        let url = fileURL(for: itemIdentifier, workingDirectory: workingDirectory)
        guard FileManager.default.fileExists(atPath: url.path) else {
            completionHandler(nil, nil, NSFileProviderError(.noSuchItem))
            return progress
        }

        let item = FileProviderItem(url: url, identifier: itemIdentifier, workingDirectory: workingDirectory)
        completionHandler(url, item, nil)
        progress.completedUnitCount = 100

        return progress
    }

    func createItem(basedOn itemTemplate: NSFileProviderItem,
                    fields _: NSFileProviderItemFields,
                    contents url: URL?,
                    options _: NSFileProviderCreateItemOptions,
                    request _: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress
    {
        let progress = Progress(totalUnitCount: 100)
        let workingDirectory: URL
        do {
            workingDirectory = try requireWorkingDirectory()
        } catch {
            completionHandler(nil, [], false, error)
            return progress
        }

        let parentURL = fileURL(for: itemTemplate.parentItemIdentifier, workingDirectory: workingDirectory)
        let targetURL = parentURL.appendingPathComponent(itemTemplate.filename)

        do {
            if let contentType = itemTemplate.contentType, contentType.conforms(to: .folder) {
                try FileManager.default.createDirectory(at: targetURL, withIntermediateDirectories: true)
            } else if let sourceURL = url {
                try FileManager.default.copyItem(at: sourceURL, to: targetURL)
            } else {
                FileManager.default.createFile(atPath: targetURL.path, contents: nil)
            }

            let identifier = itemIdentifier(for: targetURL, workingDirectory: workingDirectory)
            let item = FileProviderItem(url: targetURL, identifier: identifier, workingDirectory: workingDirectory)
            completionHandler(item, [], false, nil)

        } catch {
            completionHandler(nil, [], false, error)
        }

        progress.completedUnitCount = 100
        return progress
    }

    func modifyItem(_ item: NSFileProviderItem,
                    baseVersion _: NSFileProviderItemVersion,
                    changedFields: NSFileProviderItemFields,
                    contents newContents: URL?,
                    options _: NSFileProviderModifyItemOptions,
                    request _: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress
    {
        let progress = Progress(totalUnitCount: 100)
        let workingDirectory: URL
        do {
            workingDirectory = try requireWorkingDirectory()
        } catch {
            completionHandler(nil, [], false, error)
            return progress
        }

        var currentURL = fileURL(for: item.itemIdentifier, workingDirectory: workingDirectory)
        var newIdentifier = item.itemIdentifier

        do {
            if changedFields.contains(.filename) {
                let newURL = currentURL.deletingLastPathComponent().appendingPathComponent(item.filename)
                if currentURL != newURL {
                    try FileManager.default.moveItem(at: currentURL, to: newURL)
                    currentURL = newURL
                    newIdentifier = itemIdentifier(for: newURL, workingDirectory: workingDirectory)
                }
            }

            if changedFields.contains(.parentItemIdentifier) {
                let newParentURL = fileURL(for: item.parentItemIdentifier, workingDirectory: workingDirectory)
                let newURL = newParentURL.appendingPathComponent(currentURL.lastPathComponent)
                if currentURL != newURL {
                    try FileManager.default.moveItem(at: currentURL, to: newURL)
                    currentURL = newURL
                    newIdentifier = itemIdentifier(for: newURL, workingDirectory: workingDirectory)
                }
            }

            if changedFields.contains(.contents), let contentsURL = newContents {
                try FileManager.default.removeItem(at: currentURL)
                try FileManager.default.copyItem(at: contentsURL, to: currentURL)
            }

            let resultItem = FileProviderItem(url: currentURL, identifier: newIdentifier, workingDirectory: workingDirectory)
            completionHandler(resultItem, [], false, nil)

        } catch {
            completionHandler(nil, [], false, error)
        }

        progress.completedUnitCount = 100
        return progress
    }

    func deleteItem(identifier: NSFileProviderItemIdentifier,
                    baseVersion _: NSFileProviderItemVersion,
                    options _: NSFileProviderDeleteItemOptions,
                    request _: NSFileProviderRequest,
                    completionHandler: @escaping (Error?) -> Void) -> Progress
    {
        let progress = Progress(totalUnitCount: 1)
        let workingDirectory: URL
        do {
            workingDirectory = try requireWorkingDirectory()
        } catch {
            completionHandler(error)
            return progress
        }

        let url = fileURL(for: identifier, workingDirectory: workingDirectory)

        do {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }

        progress.completedUnitCount = 1
        return progress
    }

    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier,
                    request _: NSFileProviderRequest) throws -> NSFileProviderEnumerator
    {
        let workingDirectory = try requireWorkingDirectory()
        if containerItemIdentifier == .workingSet {
            return FileProviderEnumerator(workingSet: true, workingDirectory: workingDirectory)
        }

        if containerItemIdentifier == .trashContainer {
            throw NSFileProviderError(.noSuchItem)
        }

        let url: URL
        if containerItemIdentifier == .rootContainer {
            url = workingDirectory
        } else {
            url = fileURL(for: containerItemIdentifier, workingDirectory: workingDirectory)
        }

        guard FileManager.default.fileExists(atPath: url.path) else {
            throw NSFileProviderError(.noSuchItem)
        }

        return FileProviderEnumerator(url: url, workingDirectory: workingDirectory)
    }

    // MARK: - Helper Methods

    private func fileURL(for identifier: NSFileProviderItemIdentifier, workingDirectory: URL) -> URL {
        if identifier == .rootContainer {
            return workingDirectory
        }
        let relativePath = identifier.rawValue
        return workingDirectory.appendingPathComponent(relativePath)
    }

    private func itemIdentifier(for url: URL, workingDirectory: URL) -> NSFileProviderItemIdentifier {
        let relativePath = url.path.replacingOccurrences(of: workingDirectory.path + "/", with: "")
        if relativePath == url.path || relativePath.isEmpty {
            return .rootContainer
        }
        return NSFileProviderItemIdentifier(relativePath)
    }
}
