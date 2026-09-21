//
//  TrailDraftPlaceTests.swift
//  OpenHikesTests
//
//  Marking, editing, moving and removing a place while a trail is being drawn.
//
//  What is worth pinning here is the part that is invisible on screen: that a
//  place is not a waypoint. It does not lengthen the trail, it does not appear
//  in the route a save writes, it has no rank in the list, and it takes a step
//  of undo like every other edit. Four claims, none of which a picture of the
//  map could tell apart from their opposites.
//

import CoreLocation
@testable import OpenHikes
import Testing

@Suite("Trail draft places")
struct TrailDraftPlaceTests {
    private enum Line {
        static let longitude = 12.98
        static let south = 47.60
        static let middle = 47.61
        static let north = 47.62
    }

    private static func coordinate(_ latitude: Double, _ longitude: Double = Line.longitude) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// A draft with a line already drawn, so places have something to be
    /// measured against.
    private static func drawn() -> TrailDraft {
        let draft = TrailDraft()
        draft.append(coordinate(Line.south))
        draft.append(coordinate(Line.north))
        return draft
    }

    // MARK: A place is not a waypoint

    @Test("marking a place changes neither the line nor its length")
    func markingAPlaceLeavesTheLineAlone() {
        let draft = Self.drawn()
        let length = draft.distanceMeters
        let route = draft.routeCoordinates

        draft.addPlace(TrailPlace(coordinate: Self.coordinate(Line.middle)))

        #expect(draft.waypoints.count == 2)
        #expect(draft.distanceMeters == length)
        #expect(draft.routeCoordinates == route, "a place is not a point of the route")
        #expect(draft.places.count == 1)
    }

    /// The floor is about the *line*. A place cannot rescue a draft that is not
    /// a trail, which is the same distinction everywhere else in the feature.
    @Test("a place does not make an undrawn trail saveable")
    func placesDoNotMakeADraftSaveable() {
        let draft = TrailDraft()
        draft.addPlace(TrailPlace(coordinate: Self.coordinate(Line.middle)))

        #expect(!draft.canBeSaved)
        // But it is not *empty* either: there is work here to lose, which is
        // what Cancel has to ask about and what the durable draft has to keep.
        #expect(!draft.isEmpty)
    }

    // MARK: The operations

    @Test("a place is edited by identity")
    func placesAreEditedByIdentity() throws {
        let draft = Self.drawn()
        let place = TrailPlace(coordinate: Self.coordinate(Line.middle))
        draft.addPlace(place)

        var edited = place
        edited.name = "Spring"
        edited.symbol = .water
        edited.note = "Runs all summer"
        draft.updatePlace(edited)

        let stored = try #require(draft.place(id: place.id))
        #expect(stored.name == "Spring")
        #expect(stored.symbol == .water)
        #expect(stored.note == "Runs all summer")
        #expect(draft.places.count == 1, "editing must not mark a second place")
    }

    /// A write of the same values costs a step of history that puts nothing
    /// back — and the editor commits on every dismissal, including the ones
    /// where nothing was typed.
    @Test("writing a place back unchanged is not an edit")
    func unchangedPlacesAreNotAnEdit() {
        let draft = Self.drawn()
        let place = TrailPlace(coordinate: Self.coordinate(Line.middle), name: "Hut")
        draft.addPlace(place)
        let steps = draft.canUndo

        draft.updatePlace(place)

        #expect(draft.canUndo == steps)
        draft.undo()
        #expect(draft.places.isEmpty, "one undo should reach back past the marking")
    }

    @Test("a place is moved without the rest of it being read back")
    func placesAreMovedByCoordinate() throws {
        let draft = Self.drawn()
        var place = TrailPlace(coordinate: Self.coordinate(Line.middle))
        place.name = "Saddle"
        place.symbol = .summit
        draft.addPlace(place)

        draft.movePlace(id: place.id, to: Self.coordinate(Line.middle + 0.001))

        let moved = try #require(draft.place(id: place.id))
        #expect(moved.latitude == Line.middle + 0.001)
        #expect(moved.name == "Saddle", "a move must not rewrite what it is called")
        #expect(moved.symbol == .summit)
    }

    @Test("a place that did not travel is not an edit")
    func unmovedPlacesAreNotAnEdit() {
        let draft = Self.drawn()
        let place = TrailPlace(coordinate: Self.coordinate(Line.middle))
        draft.addPlace(place)

        draft.movePlace(id: place.id, to: Self.coordinate(Line.middle))

        draft.undo()
        #expect(draft.places.isEmpty, "a press that went nowhere should not cost a step")
    }

    /// A swipe's offsets are into the *ranked* list, which is not the order the
    /// places are stored in. Resolving them to identities is what keeps a swipe
    /// on the first row from deleting whichever place happened to be marked
    /// first.
    @Test("a swipe deletes the row that was swiped, not the place that was marked first")
    func rowOffsetsAreResolvedToIdentities() {
        let draft = Self.drawn()
        let far = TrailPlace(coordinate: Self.coordinate(Line.north - 0.001), name: "Far")
        let near = TrailPlace(coordinate: Self.coordinate(Line.south + 0.001), name: "Near")
        draft.addPlace(far)
        draft.addPlace(near)
        #expect(draft.placeRows.map(\.place.name) == ["Near", "Far"])

        draft.removePlaces(atRowOffsets: IndexSet(integer: 0))

        #expect(draft.places.map(\.name) == ["Far"])
    }

    @Test("the ranked list follows the line rather than the marking order")
    func theRankedListFollowsTheLine() {
        let draft = Self.drawn()
        draft.addPlace(TrailPlace(coordinate: Self.coordinate(Line.north - 0.001), name: "Far"))
        draft.addPlace(TrailPlace(coordinate: Self.coordinate(Line.south + 0.001), name: "Near"))
        #expect(draft.placeRows.map(\.place.name) == ["Near", "Far"])

        // Turn the trail round and the two are met the other way about, with
        // nothing having been marked, moved or reordered.
        draft.reverse()

        #expect(draft.placeRows.map(\.place.name) == ["Far", "Near"])
    }

    // MARK: Undo

    @Test("undo reaches marking, editing, moving and removing alike")
    func undoCoversEveryPlaceOperation() {
        let draft = Self.drawn()
        let place = TrailPlace(coordinate: Self.coordinate(Line.middle))
        draft.addPlace(place)
        var named = place
        named.name = "Spring"
        draft.updatePlace(named)
        draft.removePlace(id: place.id)
        #expect(draft.places.isEmpty)

        draft.undo()
        #expect(draft.place(id: place.id)?.name == "Spring")
        draft.undo()
        #expect(draft.place(id: place.id)?.name.isEmpty == true)
        draft.undo()
        #expect(draft.places.isEmpty)
    }

    /// One history for both lists, because they are edited against each other —
    /// see ``TrailDraftContents``. A hiker who marks a spring, deletes a
    /// waypoint and undoes twice expects to walk back through what they did.
    @Test("undo walks back through points and places in the order they happened")
    func undoInterleavesPointsAndPlaces() {
        let draft = Self.drawn()
        draft.addPlace(TrailPlace(coordinate: Self.coordinate(Line.middle)))
        draft.remove(atOffsets: IndexSet(integer: 1))
        #expect(draft.waypoints.count == 1)
        #expect(draft.places.count == 1)

        draft.undo()
        #expect(draft.waypoints.count == 2, "the deletion goes first")
        #expect(draft.places.count == 1)

        draft.undo()
        #expect(draft.places.isEmpty, "and the marking second")
        #expect(draft.waypoints.count == 2)
    }

    /// *Clear* is the hiker starting this trail again, and a hut marked against
    /// a route that no longer exists is not the start of anything.
    @Test("clearing takes the places with the line, and one undo brings both back")
    func clearingTakesThePlaces() {
        let draft = Self.drawn()
        draft.addPlace(TrailPlace(coordinate: Self.coordinate(Line.middle)))

        draft.clearDrawing()
        #expect(draft.waypoints.isEmpty)
        #expect(draft.places.isEmpty)

        draft.undo()
        #expect(draft.waypoints.count == 2)
        #expect(draft.places.count == 1)
    }

    /// The drawing *ending* is the other verb, and it forgets rather than
    /// recording — see ``TrailDraft/clear()``.
    @Test("a drawing that ended leaves no places behind")
    func endingADrawingForgetsThePlaces() {
        let draft = Self.drawn()
        draft.addPlace(TrailPlace(coordinate: Self.coordinate(Line.middle)))

        draft.clear()

        #expect(draft.isEmpty)
        #expect(draft.places.isEmpty)
        #expect(!draft.canUndo, "a drawing that ended has no steps behind it")
    }

    // MARK: Which leg a stop lands in

    /// What *Add Stop* asks when the tap that raised the callout did not land
    /// on a leg. Measured on the ground, so the answer does not depend on how
    /// the camera happened to be turned.
    @Test("a stop lands in the leg that runs nearest to it")
    func stopsLandInTheNearestLeg() {
        let draft = TrailDraft()
        draft.append(Self.coordinate(Line.south))
        draft.append(Self.coordinate(Line.middle))
        draft.append(Self.coordinate(Line.north))

        // Beside the first leg, a little east of it.
        #expect(draft.nearestLegIndex(to: Self.coordinate(Line.south + 0.002, Line.longitude + 0.0005)) == 0)
        // And beside the second.
        #expect(draft.nearestLegIndex(to: Self.coordinate(Line.middle + 0.002, Line.longitude + 0.0005)) == 1)
    }

    @Test("a trail with no legs has no nearest leg")
    func anUndrawnTrailHasNoNearestLeg() {
        let draft = TrailDraft()
        #expect(draft.nearestLegIndex(to: Self.coordinate(Line.middle)) == nil)
        draft.append(Self.coordinate(Line.south))
        #expect(draft.nearestLegIndex(to: Self.coordinate(Line.middle)) == nil)
    }
}
