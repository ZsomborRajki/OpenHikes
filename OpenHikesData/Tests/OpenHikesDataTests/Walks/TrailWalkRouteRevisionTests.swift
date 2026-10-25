//
//  TrailWalkRouteRevisionTests.swift
//  OpenHikesDataTests
//
//  Which line a walk is along. `TrailWalkSession` ends a walk whose hike's
//  route stops being that line, so the revision has to change for every edit
//  that moves a distance along the route and for nothing that does not — an
//  end over a filled-in height is a walk lost for no reason, and a missed
//  edit is the walk that completed halfway along an extended trail (#722).
//  A pause is such an edit with no position moved: the leg it opens is no
//  distance, so adding, dropping or moving one moves every metre after it
//  (#1080).
//

import Foundation
@testable import OpenHikesData
import Testing

@Suite("Trail walk route revision")
struct TrailWalkRouteRevisionTests {
    private static let route = (0...5).map { index in
        RouteCoordinate(latitude: 47 + Double(index) * 0.001, longitude: 12)
    }

    /// A walk along `route`, or along no line it says anything about.
    private static func record(along route: [RouteCoordinate] = [], revised: Bool = true) -> TrailWalkRecord {
        TrailWalkRecord(
            hikeID: UUID(),
            routeDistanceMeters: 500,
            startedAt: Date(timeIntervalSince1970: 0),
            routeRevision: revised ? TrailWalkRecord.routeRevision(of: route) : nil
        )
    }

    @Test("the same positions are the same line, whatever else the points carry")
    func samePositionsAreTheSameLine() {
        let filled = Self.route.map { point in
            var copy = point
            copy.elevation = 900
            copy.timestamp = Date(timeIntervalSince1970: 60)
            return copy
        }

        #expect(Self.record(along: Self.route).isAlong(filled))
    }

    @Test("a moved, added or dropped point is a different line")
    func editedPositionsAreADifferentLine() {
        let walk = Self.record(along: Self.route)
        var moved = Self.route
        moved[2].longitude += 0.0001
        let extended = Self.route + [RouteCoordinate(latitude: 47.01, longitude: 12)]

        #expect(!walk.isAlong(moved))
        #expect(!walk.isAlong(extended))
        #expect(!walk.isAlong(Array(Self.route.dropLast())))
        #expect(!walk.isAlong(Self.route.reversed()), "the same points the other way round measure differently")
    }

    @Test("a pause added, dropped or moved is a different line, though no point moved")
    func movedPauseIsADifferentLine() {
        let walk = Self.record(along: Self.route)
        let pausedAtTwo = Self.pausing(Self.route, at: [2])
        let pausedAtThree = Self.pausing(Self.route, at: [3])

        #expect(!walk.isAlong(pausedAtTwo), "a pause added")
        #expect(!Self.record(along: pausedAtTwo).isAlong(Self.route), "a pause dropped")
        #expect(!Self.record(along: pausedAtTwo).isAlong(pausedAtThree), "a pause moved")
        #expect(!Self.record(along: pausedAtTwo).isAlong(Self.pausing(Self.route, at: [2, 3])), "a second pause")
        #expect(Self.record(along: pausedAtTwo).isAlong(Self.pausing(Self.route, at: [2])))
    }

    @Test("a height or a timestamp alone leaves a paused line where it was")
    func heightOrTimeAloneKeepsAPausedLine() {
        let paused = Self.pausing(Self.route, at: [2])
        let walk = Self.record(along: paused)
        let heights = paused.map { point in
            var copy = point
            copy.elevation = 900
            return copy
        }
        let timestamps = paused.map { point in
            var copy = point
            copy.timestamp = Date(timeIntervalSince1970: 60)
            return copy
        }

        #expect(walk.isAlong(heights))
        #expect(walk.isAlong(timestamps))
    }

    /// The hash a route without a pause has always had, so that a walk
    /// stamped before pauses counted is still along its unchanged line.
    @Test("a line with no pause keeps the revision it had before pauses counted")
    func unpausedRevisionIsUnchanged() {
        #expect(TrailWalkRecord.routeRevision(of: Self.route) == "48157f2b5d187b22")
    }

    /// `route` with a pause ending at each of `indices`.
    private static func pausing(_ route: [RouteCoordinate], at indices: Set<Int>) -> [RouteCoordinate] {
        route.enumerated().map { index, point in
            var copy = point
            copy.boundary = indices.contains(index) ? .paused : nil
            return copy
        }
    }

    @Test("a record with no revision has nothing to tell an edit from")
    func missingRevisionIsAlongAnything() {
        #expect(Self.record(revised: false).isAlong(Self.route))
        #expect(Self.record(revised: false).isAlong([]))
    }

    @Test("stamping names the line only for a record that named none")
    func stampingKeepsAnExistingRevision() {
        var moved = Self.route
        moved[2].longitude += 0.0001

        #expect(Self.record(revised: false).stamped(along: Self.route).isAlong(Self.route))
        #expect(!Self.record(along: Self.route).stamped(along: moved).isAlong(moved))
    }

    /// Decoded from a sidecar written before the column existed.
    @Test("a record written before revisions decodes without one")
    func legacyRecordDecodes() throws {
        let written = try JSONEncoder().encode(Self.record(along: Self.route))
        var encoded = try #require(try JSONSerialization.jsonObject(with: written) as? [String: Any])
        encoded.removeValue(forKey: "routeRevision")
        let decoded = try JSONDecoder().decode(
            TrailWalkRecord.self,
            from: JSONSerialization.data(withJSONObject: encoded)
        )

        #expect(decoded.routeRevision == nil)
    }
}
