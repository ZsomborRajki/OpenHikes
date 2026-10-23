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
        let draft = HikePlaceDraft()
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
        let draft = HikePlaceDraft()
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
        let draft = HikePlaceDraft()
        draft.name = "Watzmann view"
        let before = draft.placeholder(at: Self.spot)

        draft.name = "Watzmann view, north"
        #expect(draft.placeholder(at: Self.spot) == before)
        #expect(before.id == Self.spot.id)
        #expect(before.place.symbol == .viewpoint)

        draft.setKind(.summit)
        #expect(draft.placeholder(at: Self.spot).place.symbol == .summit)
    }

    /// The name and the note are written once a keystroke, and the form's
    /// fields, title, kind picker and pin each read only their own answer —
    /// see ``HikePlaceAdder``. That keeps a keystroke to its own field's
    /// readers only while a write to one answer wakes no reader of another,
    /// which it did while the draft was a value held whole by the session
    /// (#935).
    @Test("a keystroke wakes the readers of the answer typed into, and nobody else")
    func answersAreObservedApart() async {
        let draft = HikePlaceDraft()
        let names = ObservationCounter { _ = draft.name }
        let kinds = ObservationCounter { _ = draft.symbol }
        let notes = ObservationCounter { _ = draft.note }

        draft.name = "L"
        await names.settle()

        #expect(names.count == 1, "precondition: the keystroke reached the name's readers")
        #expect(kinds.count == 0, "the kind picker and the pin are not readers of the name")
        #expect(notes.count == 0, "nor is the note")

        draft.note = "B"
        await notes.settle()

        #expect(notes.count == 1, "precondition: the keystroke reached the note's readers")
        #expect(names.count == 1, "the name field and the title are not readers of the note")
        #expect(kinds.count == 0)
    }
}
