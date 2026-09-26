//
//  TrailWalkRouteRevisionTests.swift
//  OpenHikesDataTests
//
//  Which line a walk is along. `TrailWalkSession` ends a walk whose hike's
//  route stops being that line, so the revision has to change for every edit
//  that moves a distance along the route and for nothing that does not — an
//  end over a filled-in height is a walk lost for no reason, and a missed
//  edit is the walk that completed halfway along an extended trail (#722).
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
