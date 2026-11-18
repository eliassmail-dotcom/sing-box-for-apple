import ApplicationLibrary
import FileProvider
import Foundation
import Libbox
import Library
import Network
import UIKit
import UserNotifications

class ApplicationDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    private var profileServer: ProfileServer?
    private var reportTransferServer: ReportTransferServer?

    func application(_: UIApplication, didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        LibboxPrepareCrashSignalHandlers()
        NativeCrashReporter.installForCurrentProcess()
        LibboxReinstallCrashSignalHandlers()
        HangWatchdog.installForCurrentProcess()
        NSLog("Here I stand")
        do {
            try ServiceSetup.apply(crashReportSource: "Application")
        } catch {
            NSLog("setup service error: \(error.localizedDescription)")
        }
        do {
            try ApplicationLocale.apply()
        } catch {
            NSLog("failed to set locale: \(error)")
        }
        let notificationCenter = UNUserNotificationCenter.current()
        notificationCenter.setNotificationCategories([
            UNNotificationCategory(
                identifier: "OPEN_URL",
                actions: [
                    UNNotificationAction(identifier: "COPY_URL", title: "Copy URL", options: .foreground, icon: UNNotificationActionIcon(systemImageName: "clipboard.fill")),
                    UNNotificationAction(identifier: "OPEN_URL", title: "Open", options: .foreground, icon: UNNotificationActionIcon(systemImageName: "safari.fill")),
                ],
                intentIdentifiers: []
            ),
        ])
        notificationCenter.delegate = self
        #if JAILBREAK
            // usernotificationsd only registers the live BulletinBoard data provider that gates
            // delivery once requestAuthorization runs from the host app; it never reaches that path
            // for a section that is already authorized, so the call must not be skipped.
            Task {
                do {
                    _ = try await notificationCenter.requestAuthorization(options: [.alert, .sound])
                } catch {
                    NSLog("request notification authorization error: \(error.localizedDescription)")
                }
            }
        #endif
        setup()
        return true
    }

    func userNotificationCenter(_: UNUserNotificationCenter, willPresent _: UNNotification) async -> UNNotificationPresentationOptions {
        .banner
    }

    func userNotificationCenter(_: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        if let url = response.notification.request.content.userInfo["OPEN_URL"] as? String {
            switch response.actionIdentifier {
            case "COPY_URL":
                UIPasteboard.general.string = url
            default:
                await UIApplication.shared.open(URL(string: url)!)
            }
        }
    }

    private func setup() {
        #if os(iOS)
            prepareNativeFilesFolder()
        #endif
        do {
            try UIProfileUpdateTask.configure()
            NSLog("setup background task success")
        } catch {
            NSLog("setup background task error: \(error.localizedDescription)")
        }
        Task {
            if UIDevice.current.userInterfaceIdiom == .phone {
                await requestNetworkPermission()
            }
            await setupBackground()
        }
    }

    /// The native On My iPhone folder requires no App Group and continues to
    /// work when an on-device re-signer rewrites File Provider entitlements.
    /// Do not mirror VPN profiles here: they may contain credentials.
    #if os(iOS)
    private func prepareNativeFilesFolder() {
        guard let documents = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        ).first else { return }
        do {
            try FileManager.default.createDirectory(
                at: documents, withIntermediateDirectories: true
            )
            let readme = documents.appendingPathComponent("About Files.txt")
            if !FileManager.default.fileExists(atPath: readme.path) {
                let message = "sing-box lx++\\n\\nThis is the local Documents folder available in Files > On My iPhone.\\nFiles here are separate from the VPN working directory. VPN profiles and secrets are not exported automatically.\\n"
                try message.write(to: readme, atomically: true, encoding: .utf8)
            }
        } catch {
            NSLog("Native Files folder initialization failed: \\(error.localizedDescription)")
        }
    }
    #endif

    private nonisolated func setupBackground() async {
        if #available(iOS 16.0, *) {
            do {
                let profileServer = try ProfileServer()
                profileServer.start()
                await MainActor.run {
                    self.profileServer = profileServer
                }
                NSLog("started profile server")
            } catch {
                NSLog("setup profile server error: \(error.localizedDescription)")
            }
            do {
                let reportTransferServer = try ReportTransferServer()
                reportTransferServer.start()
                await MainActor.run {
                    self.reportTransferServer = reportTransferServer
                }
                NSLog("started report transfer server")
            } catch {
                NSLog("setup report transfer server error: \(error.localizedDescription)")
            }
            registerFileProviderDomain()
        }
    }

    @available(iOS 16.0, *)
    private nonisolated func registerFileProviderDomain() {
        guard FilePath.hasSharedContainer,
              let group = AppConfiguration.resolvedAppGroupID,
              let plugins = Bundle.main.builtInPlugInsURL,
              let paths = try? FileManager.default.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil) else {
            NSLog("File Provider registration skipped: no signed shared App Group")
            return
        }
        // Info.plist is immutable after re-signing. Register only if the File Provider
        // is signed for the same group AND its document-group plist value matches.
        let canShare = paths.contains { path in
            guard path.pathExtension == "appex",
                  let bundle = Bundle(url: path),
                  let extensionInfo = bundle.infoDictionary?["NSExtension"] as? [String: Any],
                  extensionInfo["NSExtensionPointIdentifier"] as? String == "com.apple.fileprovider-nonui",
                  extensionInfo["NSExtensionFileProviderDocumentGroup"] as? String == group else {
                return false
            }
            let signedGroups = SignedEntitlements.stringArray(
                "com.apple.security.application-groups", of: bundle
            )
            // DER-only signatures have no XML groups. The OS container check
            // is authoritative if the XML signature cannot be parsed.
            return (signedGroups.isEmpty || signedGroups.contains(group))
                && FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) != nil
        }
        guard canShare else {
            NSLog("File Provider registration skipped: document group differs from signed App Group")
            return
        }
        let domain = NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(AppConfiguration.fileProviderDomainID),
            displayName: "sing-box"
        )
        // Persistent domains survive updates. Repeated add() calls are not a
        // registration refresh and must not be used to hide a stale extension.
        NSFileProviderManager.getDomainsWithCompletionHandler { domains, error in
            if let error {
                let failure = error as NSError
                NSLog("File Provider domain lookup failed: \(failure.domain) / \(failure.code): \(failure.localizedDescription)")
                return
            }
            if domains.contains(where: { $0.identifier == domain.identifier }) {
                NSLog("File Provider domain already registered: \(domain.identifier.rawValue)")
                return
            }
            NSFileProviderManager.add(domain) { error in
                if let error {
                    let failure = error as NSError
                    NSLog("File Provider registration failed: \(failure.domain) / \(failure.code): \(failure.localizedDescription)")
                } else {
                    NSLog("File Provider domain registered: \(domain.identifier.rawValue)")
                }
            }
        }
    }

    private nonisolated func requestNetworkPermission() async {
        if await SharedPreferences.networkPermissionRequested.get() {
            return
        }
        if !DeviceCensorship.isChinaDevice() {
            await SharedPreferences.networkPermissionRequested.set(true)
            return
        }
        URLSession.shared.dataTask(with: URL(string: "http://captive.apple.com")!) { _, response, _ in
            if let response = response as? HTTPURLResponse {
                if response.statusCode == 200 {
                    Task {
                        await SharedPreferences.networkPermissionRequested.set(true)
                    }
                }
            }
        }.resume()
    }
}
