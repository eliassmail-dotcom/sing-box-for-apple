import Library
import SwiftUI

public struct GroupListView: View {
    @EnvironmentObject private var environments: ExtensionEnvironments
    @StateObject private var viewModel = GroupListViewModel()
    @State private var presentation = GroupPresentationSettings()

    private var displayedGroups: [OutboundGroup] {
        presentation.displayedGroups(viewModel.groups)
    }

    private func reloadPresentation() async {
        let id = await SharedPreferences.selectedProfileID.get()
        let json = await SharedPreferences.groupPresentationJSON.get()
        let store = (try? GroupPresentationStore.decode(json)) ?? GroupPresentationStore()
        presentation = store.profiles[String(id)] ?? GroupPresentationSettings()
    }

    public init() {}
    public var body: some View {
        VStack {
            if viewModel.isLoading {
                Text("Loading...")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(displayedGroups, id: \.tag) { group in
                            if group.isExpand {
                                Section {
                                    GroupContentView(group: group)
                                        .padding(.bottom, 14)
                                } header: {
                                    GroupHeaderView(group: group)
                                }
                            } else {
                                GroupHeaderView(group: group)
                                GroupContentView(group: group)
                                    .padding(.bottom, 14)
                            }
                        }
                    }.padding(16)
                }
            }
        }
        #if os(iOS)
        .background(Color(uiColor: .systemGroupedBackground))
        #endif
        .environmentObject(viewModel)
        .alert($viewModel.alert)
        .onAppear {
            viewModel.connect()
            Task { await reloadPresentation() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .groupPresentationChanged)) { _ in
            Task { await reloadPresentation() }
        }
        .onReceive(environments.selectedProfileUpdate) { _ in
            Task { await reloadPresentation() }
        }
        .onReceive(environments.commandClient.$groups) { groups in
            Task { @MainActor in
                viewModel.setGroups(groups)
            }
        }
    }
}
