import Foundation
import Libbox
import Library
import SwiftUI

@MainActor
public final class OverviewViewModel: BaseViewModel {
    @Published public var reasserting = false

    public func switchProfile(_ profileID: Int64, profile: ExtensionProfile, environments: ExtensionEnvironments) async {
        let previousProfileID = await SharedPreferences.selectedProfileID.get()
        guard previousProfileID != profileID else { return }
        await SharedPreferences.selectedProfileID.set(profileID)
        do {
            if profile.status.isConnectedStrict {
                // The running extension validates the candidate before reload and
                // keeps its last-good snapshot until the new service is active.
                try await profile.reloadService()
            } else if profile.status == .disconnected {
                // Widgets start from this shared desired snapshot, not the last
                // profile that happened to be active.
                try await profile.refreshDesiredStartOptions()
            } else {
                throw NSError(domain: "OverviewViewModel", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Дождитесь завершения переключения VPN и повторите."
                ])
            }
            environments.selectedProfileUpdate.send()
        } catch {
            // Restore the previous selection and refresh/reload its known-good
            // configuration. Do not leave the UI pointing at a rejected profile.
            await SharedPreferences.selectedProfileID.set(previousProfileID)
            do {
                if profile.status.isConnectedStrict {
                    try await profile.reloadService()
                } else if profile.status == .disconnected {
                    try await profile.refreshDesiredStartOptions()
                }
            } catch {
                alert = AlertState(
                    errorMessage: "Не удалось применить профиль: \(error.localizedDescription)\nНе удалось восстановить предыдущую конфигурацию: \(error.localizedDescription)"
                )
                environments.selectedProfileUpdate.send()
                reasserting = false
                return
            }
            environments.selectedProfileUpdate.send()
            alert = AlertState(action: "switch profile", error: error)
        }
        reasserting = false
    }

    public nonisolated func setSystemProxyEnabled(_ enabled: Bool, profile: ExtensionProfile) async {
        do {
            await SharedPreferences.systemProxyEnabled.set(enabled)
            if enabled {
                try LibboxNewStandaloneCommandClient()!.setSystemProxyEnabled(enabled)
            } else {
                await MainActor.run { reasserting = true }
                try await profile.restart()
                await MainActor.run { reasserting = false }
            }
        } catch {
            await MainActor.run { alert = AlertState(action: "update system proxy settings", error: error) }
        }
    }
}
