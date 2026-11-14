import Combine
import Foundation
import Library

// gru: Dashboard TZ (14.11.2026) — resolution of the actually selected outbound
// beneath a root group, down to the final node, including detour chains.
// The pure model has no Libbox or SwiftUI dependencies; the runtime facade
// below feeds it with the running-config graph (GetRunningConfig, SPEC 037)
// and the live group states (CommandGroup subscription).

public struct OutboundConfigNode: Hashable {
    public let tag: String
    public let type: String
    public let members: [String]
    public let defaultMember: String?
    public let detour: String?

    public init(tag: String, type: String, members: [String] = [], defaultMember: String? = nil, detour: String? = nil) {
        self.tag = tag
        self.type = type
        self.members = members
        self.defaultMember = defaultMember
        self.detour = detour
    }

    public var isGroup: Bool {
        type == "selector" || type == "urltest"
    }
}

public struct OutboundLiveGroup: Hashable {
    public let tag: String
    public let ownType: String
    public let selected: String
    public let itemDelays: [String: UInt16]
    public let itemTimes: [String: Date]
    public let itemTypes: [String: String]

    public init(tag: String, ownType: String, selected: String, itemDelays: [String: UInt16] = [:], itemTimes: [String: Date] = [:], itemTypes: [String: String] = [:]) {
        self.tag = tag
        self.ownType = ownType
        self.selected = selected
        self.itemDelays = itemDelays
        self.itemTimes = itemTimes
        self.itemTypes = itemTypes
    }

    public init(_ group: OutboundGroup) {
        var delays: [String: UInt16] = [:]
        var times: [String: Date] = [:]
        var types: [String: String] = [:]
        for item in group.items {
            delays[item.tag] = item.urlTestDelay
            times[item.tag] = item.urlTestTime
            types[item.tag] = item.type
        }
        self.init(tag: group.tag, ownType: group.type, selected: group.selected, itemDelays: delays, itemTimes: times, itemTypes: types)
    }
}

public struct ResolvedOutbound: Hashable {
    public enum IncompleteReason: Hashable {
        case rootMissing
        case unknownReference(String)
        case cycle(String)
        case noSelection(String)
        case unresolvedChainHop(String)
    }

    public enum Status: Hashable {
        case resolved
        case incomplete(IncompleteReason)
    }

    public let rootTag: String
    /// Groups traversed from the root to the group that holds the final node.
    public let groupPath: [String]
    /// The final non-group outbound actually selected right now.
    public let selectedTag: String?
    public let selectedType: String?
    /// Packet-order hops of a detour chain: transport entries first, exit last.
    /// Empty when the selected outbound has no detour.
    public let chainHops: [String]
    /// The final node's own URL-test delay. Never a parent group's value.
    public let latencyMs: UInt16?
    public let latencyMeasuredAt: Date?
    public let status: Status
}

public struct SelectedOutboundResolver: Hashable {
    public let nodes: [String: OutboundConfigNode]

    public init(nodes: [OutboundConfigNode]) {
        var map: [String: OutboundConfigNode] = [:]
        for node in nodes {
            map[node.tag] = node
        }
        self.nodes = map
    }

    public func resolve(rootTag: String, live: [OutboundLiveGroup]) -> ResolvedOutbound {
        let empty = ResolvedOutbound(rootTag: rootTag, groupPath: [], selectedTag: nil, selectedType: nil, chainHops: [], latencyMs: nil, latencyMeasuredAt: nil, status: .incomplete(.rootMissing))
        guard let root = nodes[rootTag] else { return empty }
        guard root.isGroup else {
            return ResolvedOutbound(rootTag: rootTag, groupPath: [], selectedTag: root.tag, selectedType: root.type, chainHops: [], latencyMs: nil, latencyMeasuredAt: nil, status: .resolved)
        }

        var path: [String] = [rootTag]
        var visited: Set<String> = [rootTag]
        var current = root
        var reason: ResolvedOutbound.IncompleteReason?
        var selectedTag: String?
        var selectedType: String?

        while true {
            let selection = live.first { $0.tag == current.tag }?.selected ?? current.defaultMember
            guard let selection, !selection.isEmpty else {
                reason = .noSelection(current.tag)
                break
            }
            guard let nextNode = nodes[selection] else {
                reason = .unknownReference(selection)
                selectedTag = selection
                selectedType = live.first { $0.tag == current.tag }?.itemTypes[selection]
                break
            }
            if nextNode.isGroup {
                if !visited.insert(selection).inserted {
                    reason = .cycle(selection)
                    break
                }
                path.append(selection)
                current = nextNode
            } else {
                selectedTag = selection
                selectedType = nextNode.type
                break
            }
        }

        // Detour chain: the selected outbound rides through its detour target.
        // Resolve the transport side to concrete nodes (packet order: entries
        // first, the selected exit last). Transport hops with their own detour
        // are surfaced as an unresolved hop instead of recursing.
        var chainHops: [String] = []
        if let selectedTag, let detour = nodes[selectedTag]?.detour {
            if !detour.isEmpty, let hops = resolveTransport(detour, live: live), !hops.isEmpty {
                chainHops = hops + [selectedTag]
            } else {
                reason = reason ?? .unresolvedChainHop(detour)
                chainHops = [selectedTag]
            }
        }

        let latency = latency(for: selectedTag, in: live)
        let status: ResolvedOutbound.Status = reason.map { .incomplete($0) } ?? .resolved
        return ResolvedOutbound(
            rootTag: rootTag,
            groupPath: path,
            selectedTag: selectedTag,
            selectedType: selectedType,
            chainHops: chainHops,
            latencyMs: latency?.delay,
            latencyMeasuredAt: latency?.measuredAt,
            status: status
        )
    }

    private func resolveTransport(_ detour: String, live: [OutboundLiveGroup]) -> [String]? {
        guard let node = nodes[detour] else { return nil }
        if !node.isGroup {
            return node.detour == nil ? [detour] : nil
        }
        var current = node
        var visited: Set<String> = [detour]
        while true {
            let selection = live.first { $0.tag == current.tag }?.selected ?? current.defaultMember
            guard let selection, !selection.isEmpty else { return nil }
            guard let nextNode = nodes[selection] else { return nil }
            if nextNode.isGroup {
                if !visited.insert(selection).inserted { return nil }
                current = nextNode
            } else {
                return nextNode.detour == nil ? [selection] : nil
            }
        }
    }

    private func latency(for tag: String?, in live: [OutboundLiveGroup]) -> (delay: UInt16, measuredAt: Date?)? {
        guard let tag else { return nil }
        for group in live.reversed() {
            guard let delay = group.itemDelays[tag], delay > 0 else { continue }
            return (delay, group.itemTimes[tag])
        }
        return nil
    }
}

public enum OutboundConfigGraph {
    public enum GraphError: Error {
        case invalidDocument
    }

    /// Parses the canonical running-config JSON (SPEC 037) into the outbound
    /// graph: group membership, selector defaults and detour links.
    public static func parse(content: String) throws -> [String: OutboundConfigNode] {
        struct RawOutbound: Decodable {
            let tag: String
            let type: String
            let outbounds: [String]?
            let detour: String?
            let defaultMember: String?

            enum CodingKeys: String, CodingKey {
                case tag
                case type
                case outbounds
                case detour
                case defaultMember = "default"
            }
        }
        struct RawDocument: Decodable {
            let outbounds: [RawOutbound]
        }
        let document = try JSONDecoder().decode(RawDocument.self, from: Data(content.utf8))
        guard !document.outbounds.isEmpty else { throw GraphError.invalidDocument }
        var map: [String: OutboundConfigNode] = [:]
        for item in document.outbounds {
            map[item.tag] = OutboundConfigNode(
                tag: item.tag,
                type: item.type,
                members: item.outbounds ?? [],
                defaultMember: item.defaultMember,
                detour: item.detour
            )
        }
        return map
    }
}

/// Runtime facade: keeps the graph + live state in sync with a CommandClient
/// and publishes the resolved outbound for one root group.
/// Primary graph source is GetRunningConfig (SPEC 037); while it loads — or
/// when it is unavailable — the live group membership acts as a fallback
/// graph (without detour chains, which only the running config knows).
@MainActor
public final class OutboundResolverModel: ObservableObject {
    @Published public private(set) var result: ResolvedOutbound?

    private let rootTag: String
    private var graph: [String: OutboundConfigNode]?
    private var live: [OutboundLiveGroup] = []
    private var cancellables: Set<AnyCancellable> = []
    private var graphTask: Task<Void, Never>?
    private var didAttemptGraphLoad = false

    public init(rootTag: String) {
        self.rootTag = rootTag
    }

    public func bind(to client: CommandClient) {
        client.$groups
            .receive(on: DispatchQueue.main)
            .sink { [weak self] groups in
                guard let self else { return }
                live = groups?.map(OutboundLiveGroup.init) ?? []
                recompute()
            }
            .store(in: &cancellables)
        client.$isConnected
            .receive(on: DispatchQueue.main)
            .sink { [weak self] connected in
                guard let self else { return }
                graph = nil
                didAttemptGraphLoad = false
                if connected {
                    loadGraph()
                }
                recompute()
            }
            .store(in: &cancellables)
        if client.isConnected {
            loadGraph()
        }
        if let groups = client.groups {
            live = groups.map(OutboundLiveGroup.init)
        }
        recompute()
    }

    private func recompute() {
        guard !live.isEmpty else {
            result = nil
            return
        }
        guard let configGraph = graph else {
            result = SelectedOutboundResolver(nodes: liveFallbackNodes())
                .resolve(rootTag: rootTag, live: live)
            if !didAttemptGraphLoad {
                loadGraph()
            }
            return
        }
        result = SelectedOutboundResolver(nodes: Array(configGraph.values))
            .resolve(rootTag: rootTag, live: live)
        if case .incomplete(.unknownReference) = result?.status, !didAttemptGraphLoad {
            didAttemptGraphLoad = true
            graph = nil
            loadGraph()
        }
    }

    private func liveFallbackNodes() -> [OutboundConfigNode] {
        live.map { group in
            OutboundConfigNode(
                tag: group.tag,
                type: group.ownType,
                members: group.itemTypes.map(\.key),
                defaultMember: nil,
                detour: nil
            )
        }
    }

    private func loadGraph() {
        didAttemptGraphLoad = true
        guard graphTask == nil else { return }
        graphTask = Task { [weak self] in
            let loaded = await Self.loadGraph()
            await MainActor.run { [weak self] in
                guard let self else { return }
                graphTask = nil
                if let loaded {
                    graph = loaded
                }
                recompute()
            }
        }
    }

    private static func loadGraph() async -> [String: OutboundConfigNode]? {
        guard let client = try? await CommandTarget.standaloneClient() else { return nil }
        guard let config = try? await client.getRunningConfig() else { return nil }
        let content = config.content()
        return try? OutboundConfigGraph.parse(content: content)
    }
}
