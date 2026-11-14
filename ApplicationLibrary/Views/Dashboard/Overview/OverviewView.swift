import Foundation
import Libbox
import Library
import SwiftUI

@MainActor
public struct OverviewView: View {
    @EnvironmentObject private var environments: ExtensionEnvironments
    @EnvironmentObject private var profile: ExtensionProfile
    @StateObject private var coordinator = OverviewViewModel()
    @ObservedObject private var configuration: DashboardCardConfiguration

    @Binding private var profileList: [ProfilePreview]
    @Binding private var selectedProfileID: Int64
    @Binding private var systemProxyAvailable: Bool
    @Binding private var systemProxyEnabled: Bool

    public init(
        _ profileList: Binding<[ProfilePreview]>,
        _ selectedProfileID: Binding<Int64>,
        _ systemProxyAvailable: Binding<Bool>,
        _ systemProxyEnabled: Binding<Bool>,
        cardConfiguration: DashboardCardConfiguration
    ) {
        _profileList = profileList
        _selectedProfileID = selectedProfileID
        _systemProxyAvailable = systemProxyAvailable
        _systemProxyEnabled = systemProxyEnabled
        _configuration = ObservedObject(wrappedValue: cardConfiguration)
    }

    public var body: some View {
        Group {
            if configuration.isLoading {
                ProgressView()
            } else {
                ScrollView {
                    cardGrid
                        .padding()
                        .padding(.bottom, missingBottomInset)
                }
                .background(DashboardBottomInsetProbe(missingInset: $missingBottomInset))
            }
        }
        .alert($coordinator.alert)
        .disabled(!Variant.screenshotMode && (!profile.status.isSwitchable || coordinator.reasserting))
    }

    // gru: layout fix (Dashboard TZ, stage 5). The floating status pill /
    // FAB is normally reserved via safeAreaInset from MainView. On some iOS
    // versions (26 floating tab bar) the bottom inset is not propagated into
    // the scroll view, and the pill covers the last card. Probe the actual
    // bottom safe area and reserve the accessory footprint on the content
    // itself when it is missing.
    @State private var missingBottomInset: CGFloat = 0

    private struct DashboardBottomInsetProbe: View {
        @Binding var missingInset: CGFloat

        private struct BottomInsetKey: PreferenceKey {
            static var defaultValue: CGFloat = 0

            static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
                value = nextValue()
            }
        }

        var body: some View {
            GeometryReader { proxy in
                Color.clear
                    .preference(key: BottomInsetKey.self, value: proxy.safeAreaInsets.bottom)
            }
            .onPreferenceChange(BottomInsetKey.self) { safeBottom in
                // The status pill (44 + 8 + 12 paddings) floats above the tab
                // bar. When the outer safeAreaInset is propagated, the scroll
                // view's bottom safe area already exceeds the pill + tab bar
                // footprint (~120pt on home-indicator iPhones). Below that,
                // reserve the pill footprint on the content itself.
                missingInset = safeBottom >= 120 ? 0 : 64
            }
        }
    }

    @ViewBuilder
    private var cardGrid: some View {
        let visibleCards = configuration.orderedEnabledCards.filter(shouldShowCard)
        let groupedCards = DashboardCard.groupIntoRows(visibleCards)

        VStack(spacing: 16) {
            ForEach(Array(groupedCards.enumerated()), id: \.offset) { _, group in
                if group.count == 2 {
                    HStack(spacing: 16) {
                        cardView(for: group[0])
                            .frame(maxWidth: .infinity)
                        cardView(for: group[1])
                            .frame(maxWidth: .infinity)
                    }
                } else {
                    cardView(for: group[0])
                }
            }
        }
    }

    private func shouldShowCard(_ card: DashboardCard) -> Bool {
        switch card {
        case .status, .connections, .uploadTraffic, .downloadTraffic, .clashMode, .strategyMode, .strategyNode, .geminiNode:
            return Variant.screenshotMode || profile.status.isConnected
        case .httpProxy:
            return (Variant.screenshotMode || profile.status.isConnectedStrict) && systemProxyAvailable
        case .profile:
            return true
        }
    }

    @ViewBuilder
    private func cardView(for card: DashboardCard) -> some View {
        switch card {
        case .status:
            StatusCard()
                .environmentObject(environments.commandClient)
        case .connections:
            ConnectionsCard()
                .environmentObject(environments.commandClient)
        case .uploadTraffic:
            UploadTrafficCard()
                .environmentObject(environments.commandClient)
        case .downloadTraffic:
            DownloadTrafficCard()
                .environmentObject(environments.commandClient)
        case .httpProxy:
            HTTPProxyCard(
                systemProxyAvailable: $systemProxyAvailable,
                systemProxyEnabled: $systemProxyEnabled
            ) { enabled in
                await coordinator.setSystemProxyEnabled(enabled, profile: profile)
            }
        case .clashMode:
            ClashModeCard()
                .environmentObject(environments.commandClient)
        case .strategyMode:
            StrategyModeCard()
                .environmentObject(environments.commandClient)
        case .strategyNode:
            CurrentOutboundCard(groupTag: "Стратегия", title: "Узел • Стратегия", icon: "antenna.radiowaves.left.and.right")
                .environmentObject(environments.commandClient)
        case .geminiNode:
            CurrentOutboundCard(groupTag: "Gemini", title: "Узел • Gemini", icon: "sparkles")
                .environmentObject(environments.commandClient)
        case .profile:
            ProfileCard(
                profileList: $profileList,
                selectedProfileID: Binding(
                    get: { selectedProfileID },
                    set: { newID in
                        coordinator.reasserting = true
                        Task {
                            await coordinator.switchProfile(newID, profile: profile, environments: environments)
                        }
                    }
                )
            )
        }
    }
}
