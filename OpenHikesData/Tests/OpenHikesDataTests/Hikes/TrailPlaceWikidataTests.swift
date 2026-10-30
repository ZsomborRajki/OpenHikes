//
//  TrailPlaceWikidataTests.swift
//  OpenHikesDataTests
//
//  The Wikidata item an OpenStreetMap place links to: read off the element's
//  `wikidata` tag, kept on the place, and written to the mirrored row a saved
//  hike holds it in.
//
//  The tag arrives from strangers, and so does the column — whichever device
//  saved the row wrote it — so both are read by the same rule. What is pinned
//  here is that rule, and that nothing between the wire and the card loses
//  the item or invents one.
//

import Foundation
@testable import OpenHikesData
import Testing

@Suite("Trail place Wikidata item")
struct TrailPlaceWikidataTests {
    private static func osmPlace(wikidata: String?) -> TrailPlace {
        TrailPlace(
            latitude: 47.5546,
            longitude: 12.9223,
            name: "Watzmann",
            symbol: .summit,
            osm: TrailPlaceOSM(elementType: "node", elementID: 26_862_633, wikidata: wikidata)
        )
    }

    @Test(
        "a tag naming one item is read as that item",
        arguments: [
            ("Q163919", "Q163919"),
            // Written loosely, and still one item.
            ("q163919", "Q163919"),
            (" Q42\n", "Q42"),
        ]
    )
    func aTagNamingOneItemIsRead(tag: String, item: String) {
        #expect(TrailPlaceOSM.wikidataItem(fromTag: tag) == item)
    }

    /// A list is the shape OpenStreetMap's validators find most often, and it
    /// is two places rather than one: a card that picked either would be
    /// guessing which place it describes.
    @Test(
        "a tag that does not name exactly one item names none",
        arguments: [
            "Q1;Q2",
            "https://www.wikidata.org/wiki/Q42",
            "42",
            "Q",
            "Q0",
            "Q042",
            "Q-1",
            "Watzmann",
            "Q１２",
            "Q1234567890123",
            "",
        ]
    )
    func aTagThatIsNotOneItemNamesNone(tag: String) {
        #expect(TrailPlaceOSM.wikidataItem(fromTag: tag) == nil)
    }

    @Test("no tag names no item")
    func noTagNamesNoItem() {
        #expect(TrailPlaceOSM.wikidataItem(fromTag: nil) == nil)
    }

    @Test("a saved place keeps its item, on the row and read back")
    func aSavedPlaceKeepsItsItem() {
        let place = Self.osmPlace(wikidata: "Q163919")
        let row = TrailPoint(hikeID: UUID(), place: place)

        #expect(row.osmWikidata == "Q163919")
        #expect(row.place == place, "read back, it is the place that was saved")
    }

    /// The column is written by whichever device saved the row, so what it
    /// holds is read by the rule the tag is — and a value that is not an item
    /// costs the link, not the place.
    @Test("a column holding something that is not an item reads as none")
    func aColumnThatIsNotAnItemReadsAsNone() {
        let row = TrailPoint(hikeID: UUID(), place: Self.osmPlace(wikidata: "Q163919"))
        row.osmWikidata = "Q1;Q2"

        #expect(row.place.osm?.wikidata == nil)
        #expect(row.place.osm?.elementID == 26_862_633, "the element is still the place's")
    }

    @Test("a place the hiker made has no item to keep")
    func aHikersPlaceHasNoItem() {
        let row = TrailPoint(hikeID: UUID(), place: TrailPlace(latitude: 47.55, longitude: 12.92, name: "Lunch"))

        #expect(row.osmWikidata == nil)
        #expect(row.place.osm == nil)
    }

    /// What ``TrailPlace`` was written with before the item existed — the
    /// maker's draft and the place search's files on disk both hold it — reads
    /// back as a place with no item rather than as no place.
    @Test("an element written before the item existed reads as one with none")
    func anOlderElementReadsWithNoItem() throws {
        let older = Data(#"{"elementType":"node","elementID":26862633,"facts":[]}"#.utf8)

        let element = try JSONDecoder().decode(TrailPlaceOSM.self, from: older)

        #expect(element.wikidata == nil)
        #expect(element.elementID == 26_862_633)
    }

    @Test("an element's item survives being written down")
    func anElementsItemRoundTrips() throws {
        let element = TrailPlaceOSM(elementType: "node", elementID: 26_862_633, wikidata: "Q163919")

        let read = try JSONDecoder().decode(TrailPlaceOSM.self, from: JSONEncoder().encode(element))

        #expect(read == element)
    }
}
