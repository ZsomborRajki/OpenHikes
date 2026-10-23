//
//  HikeWalkRouteRevisionTests.swift
//  OpenHikesDataTests
//
//  Whether a finished walk's stretches can still be read along the hike's
//  route. The summary draws them, and the share card climbs them, on the
//  current line, so a line that moved under the walk has to say so even when
//  its length did not: a reversed route used to pass, and a walk over the
//  first quarter of it was drawn over the opposite end (#880).
//

import Foundation
@testable import OpenHikesData
import RealModule
import Testing

@Suite("Hike walk route revision")
struct HikeWalkRouteRevisionTests {
    /// Asymmetric, so its reversal starts somewhere else.
    private static let route = [
        RouteCoordinate(latitude: 47.0, longitude: 12.0),
        RouteCoordinate(latitude: 47.004, longitude: 12.0),
        RouteCoordinate(latitude: 47.012, longitude: 12.003),
    ]

    /// A walk over the first quarter of ``route``, naming `revision` as the
    /// line it was along.
    private static func walk(revision: String?) -> HikeWalk {
        let length = RouteProfile(route: Self.route).totalDistanceMeters
        return HikeWalk(
            hikeID: UUID(),
            startedAt: Date(timeIntervalSince1970: 0),
            endedAt: Date(timeIntervalSince1970: 3600),
            activeSeconds: 3600,
            coveredIntervals: [0, length / 4],
            furthestDistanceMeters: length / 4,
            routeDistanceMeters: length,
            endReason: .ended,
            routeRevision: revision
        )
    }

    /// Whether `walk` can be read along `route`, as the summary asks it.
    private static func isAlong(_ walk: HikeWalk, along route: [RouteCoordinate]) -> Bool {
        walk.isAlong(revision: TrailWalkRecord.routeRevision(of: route))
    }

    @Test("the unchanged route is the line the walk was along")
    func unchangedRouteMatches() {
        #expect(Self.isAlong(Self.walk(revision: TrailWalkRecord.routeRevision(of: Self.route)), along: Self.route))
    }

    @Test("a reversed route is as long and still a different line")
    func reversedRouteDoesNotMatch() {
        let reversed = Array(Self.route.reversed())
        let length = RouteProfile(route: Self.route).totalDistanceMeters
        #expect(
            RouteProfile(route: reversed).totalDistanceMeters.isApproximatelyEqual(to: length, absoluteTolerance: 1)
        )

        #expect(!Self.isAlong(Self.walk(revision: TrailWalkRecord.routeRevision(of: Self.route)), along: reversed))
    }

    @Test("a different line of the same length does not match")
    func equalLengthRouteDoesNotMatch() {
        // The same three legs, mirrored across the start's meridian: every
        // segment keeps its length, and the line goes somewhere else.
        let mirrored = Self.route.map { point in
            RouteCoordinate(latitude: point.latitude, longitude: 24 - point.longitude)
        }
        let length = RouteProfile(route: Self.route).totalDistanceMeters
        #expect(
            RouteProfile(route: mirrored).totalDistanceMeters.isApproximatelyEqual(to: length, absoluteTolerance: 1)
        )

        #expect(!Self.isAlong(Self.walk(revision: TrailWalkRecord.routeRevision(of: Self.route)), along: mirrored))
    }

    @Test("an edit that changes the length does not match")
    func lengthChangingEditDoesNotMatch() {
        let extended = Self.route + [RouteCoordinate(latitude: 47.02, longitude: 12.003)]

        #expect(!Self.isAlong(Self.walk(revision: TrailWalkRecord.routeRevision(of: Self.route)), along: extended))
    }

    @Test("a walk that names no line is along none, even one of its length")
    func unnamedLineMatchesNothing() {
        #expect(!Self.isAlong(Self.walk(revision: nil), along: Self.route))
    }

    @Test("a closed walk keeps the line its record was along")
    func closingCarriesTheRevision() {
        let record = TrailWalkRecord(
            hikeID: UUID(),
            routeDistanceMeters: RouteProfile(route: Self.route).totalDistanceMeters,
            startedAt: Date(timeIntervalSince1970: 0),
            routeRevision: TrailWalkRecord.routeRevision(of: Self.route)
        )
        let walk = HikeWalk(closing: record, at: Date(timeIntervalSince1970: 60), reason: .ended)

        #expect(walk.routeRevision == record.routeRevision)
        #expect(!Self.isAlong(walk, along: Self.route.reversed()))
    }
}
