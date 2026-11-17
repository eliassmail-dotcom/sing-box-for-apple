import Foundation
import GRDB
import Libbox

public extension Profile {
    nonisolated func updateRemoteProfile() async throws {
        guard type == .remote else { return }
        let remoteContent = try await HTTPClient.getStringAsync(remoteURL)
        try await BlockingIO.run {
            var error: NSError?
            LibboxCheckConfig(remoteContent, &error)
            if let error { throw error }
        }
        // Save the source too: a syntactically valid profile may fail to start.
        let previousContent = try await readAsync()
        if previousContent != remoteContent {
            try await writeAsync(remoteContent)
            do {
                try await onProfileUpdated()
            } catch {
                let applyError = error
                do {
                    try await writeAsync(previousContent)
                    try await onProfileUpdated()
                } catch {
                    throw NSError(domain: "Profile.RemoteUpdate", code: 2, userInfo: [
                        NSLocalizedDescriptionKey: "Обновление профиля не применено: \(applyError.localizedDescription). Не удалось полностью восстановить прежний профиль: \(error.localizedDescription).",
                        NSUnderlyingErrorKey: applyError
                    ])
                }
                throw applyError
            }
        }
        await MainActor.run { lastUpdated = Date() }
        try await ProfileManager.update(self)
    }

    nonisolated func onProfileUpdated() async throws {
        guard await SharedPreferences.selectedProfileID.get() == id else { return }
        guard let profile = try await ExtensionProfile.load() else {
            throw NSError(domain: "Profile.Update", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "VPN manager unavailable while updating the active profile."
            ])
        }
        switch await profile.status {
        case .connected:
            try await profile.reloadService()
        case .disconnected, .invalid:
            try await profile.refreshDesiredStartOptions()
        default:
            throw NSError(domain: "Profile.Update", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "VPN is transitioning; retry profile update after it connects or disconnects."
            ])
        }
    }
}
