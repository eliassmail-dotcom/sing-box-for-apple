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
