#if os(iOS)
import Foundation
import XCTest
@testable import ApplicationLibrary

final class StudioGroupCatalogTests: XCTestCase {
    func testRealDetourChainsAndLegacyPoolsAreVisibleWithoutGuessingGenerator() throws {
        let doc = try StudioDocument(content: """
        {"outbounds":[
          {"type":"vless","tag":"🇩🇪 Германия"},
          {"type":"vless","tag":"🇨🇭 Gemini"},
          {"type":"selector","tag":"Стратегия","outbounds":["Пулы","Ручной выбор"]},
          {"type":"selector","tag":"Ручной выбор","outbounds":["🇩🇪 Германия","🇨🇭 Gemini"]},
          {"type":"urltest","tag":"Пул A","outbounds":["🇩🇪 Германия","🇨🇭 Gemini"]},
          {"type":"selector","tag":"Пулы","outbounds":["Пул A"]},
          {"type":"vless","tag":"C • 🇨🇭 Gemini⁠","detour":"Стратегия"},
          {"type":"urltest","tag":"Gemini • Chain • A","outbounds":["C • 🇨🇭 Gemini⁠"]},
          {"type":"selector","tag":"Filtered","include":["Gemini"],"exclude":["плохой"]},
          {"type":"direct","tag":"direct"}
        ]}
        """)
        let catalog = StudioGroupCatalog(document: doc)
        XCTAssertEqual(catalog.items(.chain).map(\.tag), ["C • 🇨🇭 Gemini⁠"])
        XCTAssertEqual(catalog.items(.dynamic).map(\.tag), ["Filtered"])
        XCTAssertEqual(catalog.items(.composite).map(\.tag),
                       ["Стратегия", "Пулы"])
        XCTAssertEqual(catalog.items(.manual).map(\.tag),
                       ["Ручной выбор", "Пул A", "Gemini • Chain • A"])
        XCTAssertEqual(catalog.legacyPools.map(\.tag), ["Пул A"])
        XCTAssertTrue(catalog.items(.smart).isEmpty)
        XCTAssertEqual(catalog.allCount, 7)
    }

    func testCompiledPoolIsNotMisrepresentedAsDynamicFilter() throws {
        let doc = try StudioDocument(content: """
        {"outbounds":[
          {"type":"vless","tag":"Server One"},
          {"type":"urltest","tag":"Пул B","outbounds":["Server One"]}
        ]}
        """)
        let catalog = StudioGroupCatalog(document: doc)
        XCTAssertEqual(catalog.items(.manual).count, 1)
        XCTAssertEqual(catalog.items(.dynamic).count, 0)
        XCTAssertEqual(catalog.legacyPools.map(\.tag), ["Пул B"])
    }

    func testOriginalNodeTagIsPreservedIncludingWordJoiner() throws {
        let tag = "C • 🇨🇭 Gemini\u{2060}"
        let data = try JSONSerialization.data(withJSONObject: [
            "outbounds": [
                ["type": "selector", "tag": "Стратегия", "outbounds": []],
                ["type": "vless", "tag": tag, "detour": "Стратегия"]
            ]
        ])
        let document = try StudioDocument(content: String(decoding: data, as: UTF8.self))
        XCTAssertEqual(StudioGroupCatalog(document: document).items(.chain).first?.tag, tag)
    }
}
#endif
