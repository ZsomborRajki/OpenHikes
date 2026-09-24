//
//  TrailDraftPlaceTests.swift
//  OpenHikesTests
//
//  Adding and removing places while a trail is being drawn.
//
//  What is worth pinning here is the part that is invisible on screen: that a
//  place is not a waypoint. It does not lengthen the trail, it does not appear
//  in the route a save writes, and it has no rank in the list — where it sits
//  is worked out from the line, off the main actor. None of that is something
//  a picture of the map could tell apart from its opposite.
//

import CoreLocation
@testable import OpenHikes
import OpenHikesData
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

    @Test("a search that finds nothing new adds nothing")
    func nothingNewAddsNothing() {
        let draft = Self.drawn()
        let spring = TrailPlace(coordinate: Self.coordinate(Line.middle), name: "Spring")
        draft.addPlaces([spring])
        draft.addPlaces([spring])

        #expect(draft.places.map(\.name) == ["Spring"])
    }

    /// Ranked off the main actor, so the rows land a moment after the edit —
    /// and they follow the line: put the stops the other way round and the
    /// two places are met the other way about, with nothing having been added,
    /// moved or reordered among them.
    @Test("the ranked list follows the line rather than the order places were found in")
    func theRankedListFollowsTheLine() async {
        let draft = Self.drawn()
        draft.addPlaces([
            TrailPlace(coordinate: Self.coordinate(Line.north - 0.001), name: "Far"),
            TrailPlace(coordinate: Self.coordinate(Line.south + 0.001), name: "Near"),
        ])
        await settleDelegateHop(until: "the places to be ranked along the line") {
            draft.placeRows.map(\.place.name) == ["Near", "Far"]
        }
        #expect(draft.placeRows.map(\.place.name) == ["Near", "Far"])

        draft.moveWaypoints(fromOffsets: IndexSet(integer: 1), toOffset: 0)
        await settleDelegateHop(until: "the places to be ranked the other way round") {
            draft.placeRows.map(\.place.name) == ["Far", "Near"]
        }
        #expect(draft.placeRows.map(\.place.name) == ["Far", "Near"])
    }

    /// Ranking runs on its own, off the main actor, and an edit can land while
    /// it does. What was being ranked then is no longer the drawing, and its
    /// answer must not be what the rows end up saying.
    @Test("a ranking overtaken by an edit does not land over it")
    func anOvertakenRankingIsDropped() async {
        let draft = Self.drawn()
        let spring = TrailPlace(coordinate: Self.coordinate(Line.middle), name: "Spring")
        draft.addPlaces([spring])
        draft.removePlace(id: spring.id)
        #expect(draft.placeRows.isEmpty, "the removal is said at once")

        draft.addPlaces([TrailPlace(coordinate: Self.coordinate(Line.north - 0.001), name: "Hut")])
        await settleDelegateHop(until: "the newest ranking to land") {
            draft.placeRows.map(\.place.name) == ["Hut"]
        }
        #expect(draft.placeRows.map(\.place.name) == ["Hut"])
    }

    /// With no line there is nothing to measure against, and the rows are the
    /// places in the order they were found — at once, with no ranking asked.
    @Test("with no line the rows are the places as found, straight away")
    func withNoLineTheRowsAreImmediate() {
        let draft = TrailDraft()
        draft.addPlaces([
            TrailPlace(coordinate: Self.coordinate(Line.north), name: "Far"),
            TrailPlace(coordinate: Self.coordinate(Line.south), name: "Near"),
        ])

        #expect(draft.placeRows.map(\.place.name) == ["Far", "Near"])
        #expect(draft.placeRows.allSatisfy { $0.anchor == nil })
    }

    // MARK: Removing

    @Test("removing a place takes it off the trail")
    func removingTakesItOff() {
        let draft = Self.drawn()
        let place = TrailPlace(coordinate: Self.coordinate(Line.middle), name: "Spring")
        draft.addPlaces([place])
        draft.removePlace(id: place.id)

        #expect(draft.places.isEmpty)
        #expect(draft.place(id: place.id) == nil)
    }

    /// The drawing ending takes its places with it — see ``TrailDraft/clear()``.
    @Test("a drawing that ended leaves no places behind")
    func endingADrawingForgetsThePlaces() {
        let draft = Self.drawn()
        draft.addPlaces([TrailPlace(coordinate: Self.coordinate(Line.middle))])

        draft.clear()

        #expect(draft.isEmpty)
        #expect(draft.places.isEmpty)
        #expect(draft.placeRows.isEmpty)
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
