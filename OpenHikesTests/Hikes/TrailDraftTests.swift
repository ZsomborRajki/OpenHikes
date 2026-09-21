//
//  TrailDraftTests.swift
//  OpenHikesTests
//
//  The line while it is still being drawn.
//
//  What is worth asserting here is the arithmetic and the two figures that
//  come out of it, because everything above this type reads them rather than
//  recomputing them: the header draws ``TrailDraft/distanceMeters``, each row
//  draws ``TrailDraft/distanceAlongLine(toWaypointAt:)``, and
//  ``TrailDraftSave`` writes the first of the two onto the hike. Two walks of
//  the same points that disagreed would put a different length on the screen
//  and in the library.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Testing

@MainActor
@Suite("Trail draft")
struct TrailDraftTests {
    /// Two points a known distance apart, on one line of longitude so the
    /// answer is a degree of latitude and nothing else.
    private enum Line {
        static let longitude: Double = -122.03
        static let south: Double = 37.3300
        static let middle: Double = 37.3320
        static let north: Double = 37.3340
    }

    private static func coordinate(_ latitude: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: Line.longitude)
    }

    private static func draft(_ latitudes: [Double]) -> TrailDraft {
        let draft = TrailDraft()
        for latitude in latitudes { draft.append(coordinate(latitude)) }
        return draft
    }

    @Test("a new draft has nothing in it and cannot be saved")
    func emptyDraft() {
        let draft = TrailDraft()
        #expect(draft.isEmpty)
        #expect(!draft.canBeSaved)
        #expect(draft.distanceMeters == 0)
    }

    /// One point is a place rather than a trail — the refusal
    /// ``TrailDraftSave`` makes, stated here as the flag the Save button reads
    /// so the two cannot disagree about which drafts are savable.
    @Test("one point is not yet a trail")
    func onePointIsNotATrail() {
        let draft = Self.draft([Line.south])
        #expect(!draft.isEmpty)
        #expect(!draft.canBeSaved)
        #expect(draft.distanceMeters == 0, "a single point spans nothing")
    }

    @Test("two points make a line with a length")
    func twoPointsHaveALength() {
        let draft = Self.draft([Line.south, Line.north])
        #expect(draft.canBeSaved)
        let expected = RouteGeometry.distanceMeters(
            from: Self.coordinate(Line.south),
            to: Self.coordinate(Line.north)
        )
        #expect(abs(draft.distanceMeters - expected) < 0.001)
    }

    /// The header's figure is the sum of the legs the rows are measured
    /// against, which is the claim the two make together on screen.
    @Test("the last point's distance along the line is the whole length")
    func rowsAgreeWithTheHeader() {
        let draft = Self.draft([Line.south, Line.middle, Line.north])
        #expect(draft.distanceAlongLine(toWaypointAt: 0) == 0)
        #expect(
            draft.distanceAlongLine(toWaypointAt: 2) == draft.distanceMeters,
            "the last row and the header have to be the same number"
        )
        #expect(draft.distanceAlongLine(toWaypointAt: 1) < draft.distanceMeters)
    }

    /// Read by a row that is being rebuilt as the list shrinks, so it answers
    /// rather than traps.
    @Test("a distance asked for a point that isn't there is zero")
    func distanceOutOfRange() {
        let draft = Self.draft([Line.south, Line.north])
        #expect(draft.distanceAlongLine(toWaypointAt: 7) == 0)
        #expect(draft.distanceAlongLine(toWaypointAt: -1) == 0)
    }

    /// Two points dropped on the same spot are two points: the id is what a
    /// row is keyed on, and a list that collapsed them would lose one.
    @Test("two waypoints at the same place are still two waypoints")
    func identityIsNotPosition() {
        let draft = Self.draft([Line.south, Line.south])
        #expect(draft.waypoints.count == 2)
        #expect(draft.waypoints[0].id != draft.waypoints[1].id)
        #expect(draft.distanceMeters == 0)
    }

    @Test("clearing empties the points and the length")
    func clearingEmptiesEverything() {
        let draft = Self.draft([Line.south, Line.north])
        draft.clear()
        #expect(draft.isEmpty)
        #expect(draft.distanceMeters == 0)
    }

    /// The length is measured again from what arrived rather than carried
    /// across, which is what keeps a restored draft's header honest.
    @Test("replacing a draft remeasures its length")
    func replacingRemeasures() {
        let draft = TrailDraft()
        draft.replace(with: [
            TrailWaypoint(coordinate: Self.coordinate(Line.south)),
            TrailWaypoint(coordinate: Self.coordinate(Line.north)),
        ])
        #expect(draft.waypoints.count == 2)
        #expect(draft.distanceMeters > 0)
    }
}
