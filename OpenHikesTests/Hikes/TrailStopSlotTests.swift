//
//  TrailStopSlotTests.swift
//  OpenHikesTests
//
//  The route list as Apple Maps draws it: two empty fields to start with,
//  *Add Stop* going where a stop belongs, and a time on every route.
//
//  None of this is visible in the points themselves. A lone point is a start
//  or a destination depending on which field it was put in, a stop added from
//  the map lands in a leg rather than on the end, and the time is read off the
//  mode's pace unless Apple Maps said otherwise — all decided here, where a
//  suite can see it without a map.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Testing

@MainActor
@Suite("Trail stop slots")
struct TrailStopSlotTests {
    private enum Line {
        static let longitude: Double = -122.03
        static let south: Double = 37.3300
        static let middle: Double = 37.3320
        static let north: Double = 37.3340
        /// Beside the line rather than on it, where a tap on the map lands.
        static let aside: Double = -122.0295
    }

    private static func coordinate(_ latitude: Double, _ longitude: Double = Line.longitude) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    // MARK: Two empty fields

    @Test("an empty draft is two open fields")
    func anEmptyDraftIsTwoOpenFields() {
        #expect(TrailDraft().slots == [.open(.start), .open(.end)])
    }

    @Test("the first point fills the start, and the destination stays open")
    func theFirstPointIsTheStart() {
        let draft = TrailDraft()
        draft.addStop(Self.coordinate(Line.south))

        #expect(draft.slots.count == 2)
        #expect(draft.slots.last == .open(.end))
        #expect(draft.role(ofWaypointAt: 0) == .start)
    }

    /// A hiker who knows where they are going and not yet where from fills the
    /// destination first, and it has to stay the destination.
    @Test("filling the destination first leaves the start open")
    func theDestinationCanComeFirst() {
        let draft = TrailDraft()
        draft.fill(.end, with: Self.coordinate(Line.north), named: "Hut")

        #expect(draft.startIsOpen)
        #expect(draft.slots.first == .open(.start))
        #expect(draft.role(ofWaypointAt: 0) == .end)

        draft.addStop(Self.coordinate(Line.south))

        #expect(draft.waypoints.map(\.name) == ["", "Hut"], "the new point went into the start field")
        #expect(!draft.startIsOpen)
        #expect(draft.slots.allSatisfy { $0.waypointIndex != nil })
    }

    @Test("a field that is not open is not filled")
    func aFilledFieldIsNotFilledAgain() {
        let draft = TrailDraft()
        draft.addStop(Self.coordinate(Line.south))

        draft.fill(.start, with: Self.coordinate(Line.north))

        #expect(draft.waypoints.count == 1)
        #expect(draft.waypoints.first?.latitude == Line.south)
    }

    /// Deleting the start of a two-point route opens the start field again, as
    /// in Apple Maps; what is left is still the destination.
    @Test("deleting the start leaves the destination in its field")
    func deletingTheStartOpensItsField() {
        let draft = TrailDraft()
        draft.addStop(Self.coordinate(Line.south))
        draft.addStop(Self.coordinate(Line.north))

        draft.remove(atOffsets: IndexSet(integer: 0))

        #expect(draft.startIsOpen)
        #expect(draft.slots == [.open(.start), .point(index: 0, id: draft.waypoints[0].id)])

        draft.undo()
        #expect(draft.waypoints.count == 2)
        #expect(!draft.startIsOpen)
    }

    @Test("deleting the destination leaves the start in its field")
    func deletingTheDestinationOpensItsField() {
        let draft = TrailDraft()
        draft.addStop(Self.coordinate(Line.south))
        draft.addStop(Self.coordinate(Line.north))

        draft.remove(atOffsets: IndexSet(integer: 1))

        #expect(!draft.startIsOpen)
        #expect(draft.slots.last == .open(.end))
    }

    // MARK: Add Stop

    /// The user's rule: from the map, a stop never becomes a new destination —
    /// it goes into the leg it is nearest to.
    @Test("a stop added beside a drawn route goes into the nearest leg")
    func aStopGoesIntoTheNearestLeg() {
        let draft = TrailDraft()
        draft.addStop(Self.coordinate(Line.south))
        draft.addStop(Self.coordinate(Line.north))

        draft.addStop(Self.coordinate(Line.middle, Line.aside), named: "Spring")

        #expect(draft.waypoints.count == 3)
        #expect(draft.waypoints[1].name == "Spring", "between the two ends, not after them")
    }

    /// Even past the far end: the nearest leg is the last one, and the stop is
    /// a detour on the way rather than a new far end.
    @Test("a stop beyond the destination is still a stop, not a new destination")
    func aStopPastTheEndIsStillAStop() {
        let draft = TrailDraft()
        draft.addStop(Self.coordinate(Line.south))
        draft.addStop(Self.coordinate(Line.middle))

        draft.addStop(Self.coordinate(Line.north), named: "Beyond")

        #expect(draft.waypoints.last?.latitude == Line.middle, "the destination is unchanged")
        #expect(draft.waypoints[1].name == "Beyond")
    }

    @Test("the leg a thumb landed on wins over the nearest one")
    func thePreferredLegWins() {
        let draft = TrailDraft()
        draft.addStop(Self.coordinate(Line.south))
        draft.addStop(Self.coordinate(Line.middle))
        draft.append(Self.coordinate(Line.north))

        draft.addStop(Self.coordinate(Line.south, Line.aside), named: "Aimed", preferringLeg: 1)

        #expect(draft.waypoints[2].name == "Aimed")
    }

    // MARK: Time

    @Test("a leg with no estimate is timed at the mode's pace")
    func legsAreTimedAtTheModesPace() {
        let draft = TrailDraft()
        draft.addStop(Self.coordinate(Line.south))
        draft.addStop(Self.coordinate(Line.north))
        let expected = draft.distanceMeters / TrailTravelMode.hiking.paceMetersPerSecond

        #expect(abs(draft.travelTime - expected) < 0.001)

        draft.setTravelMode(.cycling)
        #expect(draft.travelTime < expected, "a bicycle is faster than boots")
    }

    @Test("Apple Maps' own estimate is used where it gave one")
    func aRoutersEstimateWins() throws {
        let draft = TrailDraft()
        draft.addStop(Self.coordinate(Line.south))
        draft.addStop(Self.coordinate(Line.north))
        let ends = try #require(draft.legs.first?.ends)
        draft.beginRouting([ends])

        draft.apply(
            TrailLegRoute(coordinates: ends.straightCoordinates, distanceMeters: 500, snap: .snapped, travelTime: 42),
            to: ends
        )

        #expect(draft.travelTime == 42)
    }

    // MARK: Choosing a route

    @Test("choosing an alternative swaps it with the drawn route")
    func choosingAnAlternativeSwapsIt() throws {
        let draft = TrailDraft()
        draft.addStop(Self.coordinate(Line.south))
        draft.addStop(Self.coordinate(Line.north))
        let ends = try #require(draft.legs.first?.ends)
        let detour = TrailLegPath(
            coordinates: [ends.start, RouteCoordinate(latitude: Line.middle, longitude: Line.aside), ends.end],
            distanceMeters: 900,
            travelTime: 700
        )
        draft.beginRouting([ends])
        draft.apply(
            TrailLegRoute(
                coordinates: ends.straightCoordinates,
                distanceMeters: 450,
                snap: .snapped,
                travelTime: 300,
                alternatives: [detour]
            ),
            to: ends
        )

        draft.chooseAlternative(0, forLegAt: 0)

        let leg = try #require(draft.legs.first)
        #expect(leg.path == detour)
        #expect(leg.alternatives.first?.distanceMeters == 450)
        #expect(draft.distanceMeters == 900, "the length follows the route drawn")
        // A choice of route is not a step of undo: the step behind it is the
        // destination going down.
        draft.undo()
        #expect(draft.waypoints.count == 1)
    }

    @Test("an alternative that is not there changes nothing")
    func aMissingAlternativeChangesNothing() {
        let draft = TrailDraft()
        draft.addStop(Self.coordinate(Line.south))
        draft.addStop(Self.coordinate(Line.north))
        let before = draft.legs

        draft.chooseAlternative(0, forLegAt: 0)
        draft.chooseAlternative(0, forLegAt: 5)

        #expect(draft.legs == before)
    }
}
