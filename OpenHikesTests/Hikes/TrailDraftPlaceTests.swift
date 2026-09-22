//
//  TrailDraftPlaceTests.swift
//  OpenHikesTests
//
//  Adding and removing places while a trail is being drawn.
//
//  What is worth pinning here is the part that is invisible on screen: that a
//  place is not a waypoint. It does not lengthen the trail, it does not appear
//  in the route a save writes, it has no rank in the list, and a search's worth
//  of them is one step of undo. None of that is something a picture of the map
//  could tell apart from its opposite.
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

    @Test("adding places changes neither the line nor its length")
    func addingPlacesLeavesTheLineAlone() {
        let draft = Self.drawn()
        let length = draft.distanceMeters
        let route = draft.routeCoordinates

        draft.addPlaces([TrailPlace(coordinate: Self.coordinate(Line.middle))])

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
        draft.addPlaces([TrailPlace(coordinate: Self.coordinate(Line.middle))])

        #expect(!draft.canBeSaved)
        // But it is not *empty* either: there is work here to lose, which is
        // what Cancel has to ask about and what the durable draft has to keep.
        #expect(!draft.isEmpty)
    }

    // MARK: The operations

    /// A search is one decision, so taking it back is one *Undo* rather than
    /// forty deletes.
    @Test("a search's places are one step of undo")
    func aSearchIsOneStep() {
        let draft = Self.drawn()
        draft.addPlaces([
            TrailPlace(coordinate: Self.coordinate(Line.middle), name: "Spring"),
            TrailPlace(coordinate: Self.coordinate(Line.north - 0.001), name: "Hut"),
        ])
        #expect(draft.places.count == 2)

        draft.undo()

        #expect(draft.places.isEmpty)
        #expect(draft.waypoints.count == 2, "the line is the step before")
    }

    /// A second search over the same valley answers with the same spring, and
    /// a trail carrying it twice would draw two pins on one spot.
    @Test("a place already on the trail is not added twice")
    func placesAreNotAddedTwice() {
        let draft = Self.drawn()
        draft.addPlaces([TrailPlace(coordinate: Self.coordinate(Line.middle), name: "Spring")])
        draft.addPlaces([
            TrailPlace(coordinate: Self.coordinate(Line.middle), name: "Spring"),
            TrailPlace(coordinate: Self.coordinate(Line.north - 0.001), name: "Hut"),
        ])

        #expect(draft.places.map(\.name) == ["Spring", "Hut"])
    }

    @Test("a search that finds nothing new is not an edit")
    func nothingNewIsNotAnEdit() {
        let draft = Self.drawn()
        let spring = TrailPlace(coordinate: Self.coordinate(Line.middle), name: "Spring")
        draft.addPlaces([spring])
        draft.addPlaces([spring])

        draft.undo()
        #expect(draft.places.isEmpty, "one undo should reach back past the only search that added anything")
    }

    @Test("the ranked list follows the line rather than the order places were found in")
    func theRankedListFollowsTheLine() {
        let draft = Self.drawn()
        draft.addPlaces([
            TrailPlace(coordinate: Self.coordinate(Line.north - 0.001), name: "Far"),
            TrailPlace(coordinate: Self.coordinate(Line.south + 0.001), name: "Near"),
        ])
        #expect(draft.placeRows.map(\.place.name) == ["Near", "Far"])

        // Turn the trail round and the two are met the other way about, with
        // nothing having been added, moved or reordered.
        draft.reverse()

        #expect(draft.placeRows.map(\.place.name) == ["Far", "Near"])
    }

    // MARK: Undo

    @Test("removing a place is a step of undo")
    func removingIsUndoable() {
        let draft = Self.drawn()
        let place = TrailPlace(coordinate: Self.coordinate(Line.middle), name: "Spring")
        draft.addPlaces([place])
        draft.removePlace(id: place.id)
        #expect(draft.places.isEmpty)

        draft.undo()
        #expect(draft.place(id: place.id)?.name == "Spring")
    }

    /// One history for both lists, because they are edited against each other —
    /// see ``TrailDraftContents``. A hiker who adds a spring, deletes a
    /// waypoint and undoes twice expects to walk back through what they did.
    @Test("undo walks back through points and places in the order they happened")
    func undoInterleavesPointsAndPlaces() {
        let draft = Self.drawn()
        draft.addPlaces([TrailPlace(coordinate: Self.coordinate(Line.middle))])
        draft.remove(atOffsets: IndexSet(integer: 1))
        #expect(draft.waypoints.count == 1)
        #expect(draft.places.count == 1)

        draft.undo()
        #expect(draft.waypoints.count == 2, "the deletion goes first")
        #expect(draft.places.count == 1)

        draft.undo()
        #expect(draft.places.isEmpty, "and the search second")
        #expect(draft.waypoints.count == 2)
    }

    /// *Clear* is the hiker starting this trail again, and a hut found along a
    /// route that no longer exists is not the start of anything.
    @Test("clearing takes the places with the line, and one undo brings both back")
    func clearingTakesThePlaces() {
        let draft = Self.drawn()
        draft.addPlaces([TrailPlace(coordinate: Self.coordinate(Line.middle))])

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
        draft.addPlaces([TrailPlace(coordinate: Self.coordinate(Line.middle))])

        draft.clear()

        #expect(draft.isEmpty)
        #expect(draft.places.isEmpty)
        #expect(!draft.canUndo, "a drawing that ended has no steps behind it")
    }

    // MARK: Which leg a stop lands in

    /// What *Add Stop* asks when the tap that dropped the pin did not land on
    /// a leg. Measured on the ground, so the answer does not depend on how
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
