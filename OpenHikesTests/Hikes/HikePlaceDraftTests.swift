//
//  HikePlaceDraftTests.swift
//  OpenHikesTests
//
//  What *Add Place* from the pill starts out saying, how its name follows its
//  kind, and what it finally writes onto the hike.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import Testing

@Suite("Hike place draft")
struct HikePlaceDraftTests {
    private static let spot = HikePlaceSpot(CLLocationCoordinate2D(latitude: 47.61, longitude: 12.98))

    @Test("it starts as a viewpoint called Viewpoint, with no note")
    func startsAsAViewpoint() {
        let draft = HikePlaceDraft()

        #expect(draft.symbol == .viewpoint)
        #expect(draft.name == TrailPlaceSymbol.viewpoint.label)
        #expect(draft.note.isEmpty)
        #expect(draft.displayName == TrailPlaceSymbol.viewpoint.label)
    }

    @Test("the prefilled name follows the kind, and a typed one stays")
    func nameFollowsTheKindUntilTyped() {
        var draft = HikePlaceDraft()
        draft.setKind(.summit)
        #expect(draft.name == TrailPlaceSymbol.summit.label)

        draft.setKind(nil)
        #expect(draft.name.isEmpty)
        #expect(draft.displayName == String(localized: "Place"))

        draft.setKind(.water)
        #expect(draft.name == TrailPlaceSymbol.water.label)

        draft.name = "Königsbach spring"
        draft.setKind(.viewpoint)
        #expect(draft.name == "Königsbach spring")
        #expect(draft.symbol == .viewpoint)
    }

    @Test("the place is the hiker's own, at the spot, under the spot's id")
    func placeIsAtTheSpot() {
        var draft = HikePlaceDraft()
        draft.name = "  Watzmann view  "
        draft.note = "Best in the morning"

        let place = draft.place(at: Self.spot)

        #expect(place.id == Self.spot.id)
        #expect(place.latitude == Self.spot.latitude)
        #expect(place.longitude == Self.spot.longitude)
        #expect(place.name == "Watzmann view")
        #expect(place.note == "Best in the morning")
        #expect(place.symbol == .viewpoint)
        #expect(place.isHikersOwn)
    }

    @Test("a name that only repeats the kind is stored blank, and reads the same")
    func kindOnlyNameIsStoredBlank() {
        let place = HikePlaceDraft().place(at: Self.spot)

        #expect(place.name.isEmpty)
        #expect(place.displayName == TrailPlaceSymbol.viewpoint.label)
    }

    @Test("the placeholder pin is the place's kind at its spot, and carries no name")
    func placeholderCarriesNoName() {
        var draft = HikePlaceDraft()
        draft.name = "Watzmann view"
        let before = draft.placeholder(at: Self.spot)

        draft.name = "Watzmann view, north"
        #expect(draft.placeholder(at: Self.spot) == before)
        #expect(before.id == Self.spot.id)
        #expect(before.place.symbol == .viewpoint)

        draft.setKind(.summit)
        #expect(draft.placeholder(at: Self.spot).place.symbol == .summit)
    }
}
