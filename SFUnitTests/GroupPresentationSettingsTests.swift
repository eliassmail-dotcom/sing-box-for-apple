import Foundation
import XCTest
@testable import Library

final class GroupPresentationSettingsTests: XCTestCase {
    func testDefaultsShowAllInSourceOrder() {
        let settings = GroupPresentationSettings()
        XCTAssertEqual(settings.visibleTags(available: ["Стратегия", "Пул A", "Gemini+"]), ["Стратегия", "Пул A", "Gemini+"])
    }

    func testCustomOrderAndHiddenItemsDoNotChangeAvailableList() {
        var settings = GroupPresentationSettings()
        settings.setOrder(["Gemini+", "Стратегия", "Пул A"])
        settings.setVisible(false, for: "Стратегия")
        let original = ["Стратегия", "Пул A", "Gemini+", "Пул B"]
        XCTAssertEqual(settings.visibleTags(available: original), ["Gemini+", "Пул A", "Пул B"])
        XCTAssertEqual(original, ["Стратегия", "Пул A", "Gemini+", "Пул B"])
        settings.setVisible(true, for: "Стратегия")
        XCTAssertEqual(settings.visibleTags(available: original), ["Gemini+", "Стратегия", "Пул A", "Пул B"])
    }

    func testNewGroupsAppendAndRemovedTagsAreNotShown() {
        var settings = GroupPresentationSettings()
        settings.setOrder(["Пул B", "Пул A"])
        settings.setVisible(false, for: "Пул B")
        XCTAssertEqual(settings.visibleTags(available: ["Пул A", "Пул C"]), ["Пул A", "Пул C"])
        XCTAssertEqual(settings.visibleTags(available: ["Пул A", "Пул B", "Пул C"]), ["Пул A", "Пул C"])
    }

    func testStoreIsProfileScopedAndSurvivesEncoding() throws {
        var first = GroupPresentationSettings()
        first.setOrder(["Gemini+", "Пул A"])
        first.setVisible(false, for: "Пул A")
        var store = GroupPresentationStore()
        store.profiles["1"] = first
        let reloaded = try GroupPresentationStore.decode(store.encode())
        XCTAssertEqual(reloaded.profiles["1"]?.visibleTags(available: ["Пул A", "Gemini+"]), ["Gemini+"])
        XCTAssertEqual(reloaded.profiles["2"]?.hidden, nil)
        XCTAssertEqual(try GroupPresentationStore.decode(""), GroupPresentationStore())
    }

    func testProviderPairsAppearAsNodesNotGroups() {
        let now = Date()
        func item(_ tag: String, _ type: String, _ delay: UInt16 = 0) -> OutboundGroupItem {
            OutboundGroupItem(tag: tag, type: type, urlTestTime: now, urlTestDelay: delay)
        }
        func group(_ tag: String, _ type: String, _ selected: String, _ items: [OutboundGroupItem]) -> OutboundGroup {
            OutboundGroup(tag: tag, type: type, selected: selected, selectable: type == "selector", isExpand: true, items: items)
        }
        let logical = item("Country", "urltest")
        let pair = group("Country", "urltest", "Country #2", [item("Country #1", "vless", 90), item("Country #2", "vless", 40)])
        let unrelated = group("Other", "urltest", "Other #1", [item("Other #1", "vless"), item("Other #2", "vless")])
        let groups = [
            group("Стратегия", "selector", "Country", [item("Авто · Базовая", "urltest"), logical]),
            group("Авто · Базовая", "urltest", "Country", [logical]),
            pair, unrelated,
        ]
        XCTAssertEqual(GroupPresentationSettings.providerPairTags(in: groups), ["Country"])
        let shown = GroupPresentationSettings().displayedGroups(groups)
        XCTAssertEqual(shown.map(\.tag), ["Стратегия", "Авто · Базовая", "Other"])
        XCTAssertEqual(shown[0].selected, "Country")
        XCTAssertEqual(shown[0].items.last?.tag, "Country")
        XCTAssertEqual(shown[0].items.last?.type, "vless")
        XCTAssertEqual(shown[0].items.last?.urlTestDelay, 40)
        XCTAssertEqual(groups[0].items.last?.type, "urltest")
        XCTAssertEqual(groups[2].items.count, 2)
    }

    func testProviderPairsOfflineAndRussiaChain() {
        let json = """
        {"outbounds":[
          {"tag":"Ru 🔗 Авто","type":"urltest","outbounds":["Ru 🔗 Country"]},
          {"tag":"Ru 🔗 Ручной","type":"selector","outbounds":["Ru 🔗 Country"]},
          {"tag":"Ru 🔗 Country","type":"urltest","mode":"failover","outbounds":["Ru 🔗 Country #1","Ru 🔗 Country #2"]},
          {"tag":"Ru 🔗 Country #1","type":"vless"},
          {"tag":"Ru 🔗 Country #2","type":"vless"},
          {"tag":"Other","type":"urltest","outbounds":["Other #1","Other #2"]},
          {"tag":"Other #1","type":"vless"},
          {"tag":"Other #2","type":"vless"}
        ]}
        """
        XCTAssertEqual(GroupPresentationSettings.tagsFromConfig(json), ["Ru 🔗 Авто", "Ru 🔗 Ручной", "Other"])
    }

    func testOfflineGroupsReadFromConfig() {
        let json = """
        {"outbounds":[
          {"tag":"Стратегия","type":"selector","outbounds":[]},
          {"tag":"Пул A","type":"urltest","outbounds":[]},
          {"tag":"узел","type":"vless"},
          {"tag":"Стратегия","type":"selector","outbounds":[]}
        ]}
        """
        XCTAssertEqual(GroupPresentationSettings.tagsFromConfig(json), ["Стратегия", "Пул A"])
        XCTAssertTrue(GroupPresentationSettings.tagsFromConfig("invalid").isEmpty)
    }
}
