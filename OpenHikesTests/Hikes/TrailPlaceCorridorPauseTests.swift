//
//  TrailPlaceCorridorPauseTests.swift
//  OpenHikesTests
//
//  *Places Around Trail* asks about the walking, not the drive between two
//  recorded pieces (#1075). A paused leg is not trail (see *The app* in
//  AGENTS.md), so no circle is grown along one, and a long transfer can no
//  longer spend the request budget before the resumed walk is reached. The
//  Commons strip cuts its circles with the same planner, and keeps the same
//  rule.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import OpenHikesShared
import Testing

@MainActor
@Suite("Places along a paused trail")
struct TrailPlaceCorridorPauseTests {
    /// Two walks of about 1.1 km each, the second resumed six degrees of
    /// longitude east — some 450 km of transfer, past what twelve circles at
    /// the query's ceiling can cover.
    private enum Walk {
        static let latitude = 47.60
        static let north = 47.61
        static let west = 12.98
        static let east = 18.98

        static let before = [
            RouteCoordinate(latitude: latitude, longitude: west),
            RouteCoordinate(latitude: north, longitude: west),
        ]
        static let after = [
            RouteCoordinate(latitude: latitude, longitude: east, boundary: .paused),
            RouteCoordinate(latitude: north, longitude: east),
        ]
        static let route = before + after

        /// A hut on the resumed walk, and only there.
        static let hut = TrailPlace(
            latitude: (latitude + north) / 2,
            longitude: east,
            symbol: .shelter,
            osm: TrailPlaceOSM(elementType: "node", elementID: 42)
        )
    }

    /// Every hundred metres of each walked leg of `route` sits in one of
    /// `areas`, widened by `beside` metres east of the line.
    private static func expectWalkCovered(
        _ route: [RouteCoordinate],
        by areas: [CommunitySearchArea],
        beside: Double = 0
    ) {
        for leg in route.trailRuns.walkedLegs {
            let start = route[leg].clCoordinate
            let end = route[leg + 1].clCoordinate
            let steps = Int(RouteGeometry.distanceMeters(from: start, to: end) / 100) + 1
            for step in 0...steps {
                let onLine = RouteGeometry.interpolate(from: start, to: end, fraction: Double(step) / Double(steps))
                let metersPerDegree = RouteGeometry.metersPerDegreeLatitude * cos(onLine.latitude * .pi / 180)
                let point = CLLocationCoordinate2D(
                    latitude: onLine.latitude,
                    longitude: onLine.longitude + beside / metersPerDegree
                )
                let covered = areas.contains { area in
                    RouteGeometry.distanceMeters(from: area.coordinate, to: point) <= area.radiusMeters
                }
                #expect(covered, "\(point.latitude), \(point.longitude) is in no circle")
            }
        }
    }

    /// Whether any of `areas` holds the middle of the transfer.
    private static func asksAboutTheTransfer(_ areas: [CommunitySearchArea]) -> Bool {
        let middle = CLLocationCoordinate2D(latitude: Walk.latitude, longitude: (Walk.west + Walk.east) / 2)
        return areas.contains { area in
            RouteGeometry.distanceMeters(from: area.coordinate, to: middle) <= area.radiusMeters
        }
    }

    @Test("two short walks a long transfer apart are one question each")
    func pausedTransferIsNotAsked() {
        let areas = TrailPlaceCorridorSearch.areas(along: Walk.route)

        #expect(areas.count == 2)
        #expect(areas.allSatisfy { $0.radiusMeters <= TrailPlaceCorridorSearch.stretchRadiusMeters })
        #expect(!Self.asksAboutTheTransfer(areas))
        Self.expectWalkCovered(Walk.route, by: areas)
    }

    @Test("a reach of a kilometre asks beside both walks, and not along the transfer")
    func widerReachSkipsTheTransfer() {
        let areas = TrailPlaceCorridorSearch.areas(along: Walk.route, reaching: 1000)

        #expect(areas.count == 2)
        #expect(areas.allSatisfy { $0.radiusMeters <= TrailPointQuery.maximumRadiusMeters })
        #expect(!Self.asksAboutTheTransfer(areas))
        Self.expectWalkCovered(Walk.route, by: areas, beside: 1000)
    }

    @Test("the place on the resumed walk is asked for and kept")
    func resumedWalkIsSearched() async throws {
        let outcome = try await TrailPlaceCorridorSearch.search(
            along: Walk.route,
            excluding: [],
            from: AreaAnsweringSource(standing: [Walk.hut]),
            showing: Set(TrailPlaceSymbol.allCases)
        )

        #expect(outcome.places.map(\.osm?.elementID) == [42])
        #expect(outcome.outage == nil)
    }

    @Test("a sparse segment within a walk is still filled in")
    func sparseWalkAfterAPauseIsCovered() {
        // The resumed walk is one segment of 30 km: longer than a stretch can
        // hold whole, so it is cut along its length as an unpaused one is.
        let far = RouteCoordinate(
            latitude: Walk.latitude + 30_000 / RouteGeometry.metersPerDegreeLatitude,
            longitude: Walk.east
        )
        let route = Walk.before + [Walk.after[0], far]
        let areas = TrailPlaceCorridorSearch.areas(along: route)

        #expect(areas.count > 2)
        #expect(areas.allSatisfy { $0.radiusMeters <= TrailPlaceCorridorSearch.stretchRadiusMeters })
        #expect(!Self.asksAboutTheTransfer(areas))
        Self.expectWalkCovered(route, by: areas)
    }

    @Test("a pause resumed close by costs no second question")
    func nearbyResumeSharesACircle() {
        let resumed = [
            RouteCoordinate(latitude: Walk.north, longitude: Walk.west + 0.005, boundary: .paused),
            RouteCoordinate(latitude: Walk.latitude, longitude: Walk.west + 0.005),
        ]
        let route = Walk.before + resumed
        let areas = TrailPlaceCorridorSearch.areas(along: route)

        #expect(areas.count == 1)
        Self.expectWalkCovered(route, by: areas)
    }

    @Test("a line whose only leg is a pause is nothing to ask about")
    func onlyAPauseIsNothing() {
        let route = [Walk.before[0], Walk.after[0]]
        #expect(TrailPlaceCorridorSearch.areas(along: route).isEmpty)
        #expect(CommonsTrailPhotos.areas(along: route).isEmpty)
    }

    @Test("the Commons strip asks about the same walks, and not the transfer")
    func commonsSkipsTheTransfer() {
        let areas = CommonsTrailPhotos.areas(along: Walk.route)

        #expect(areas.count == 2)
        #expect(areas.allSatisfy { $0.radiusMeters <= CommonsTrailPhotos.maximumRadiusMeters })
        #expect(!Self.asksAboutTheTransfer(areas))
        Self.expectWalkCovered(Walk.route, by: areas, beside: CommonsTrailPhotos.corridorMeters)
    }
}

/// Answers each place only to a circle that holds it: the shape of a real
/// source, so a stretch nobody asked about finds nothing.
private struct AreaAnsweringSource: TrailPointSourcing {
    let standing: [TrailPlace]

    func places(near area: CommunitySearchArea, showing _: Set<TrailPlaceSymbol>) -> [TrailPlace] {
        standing.filter { place in
            RouteGeometry.distanceMeters(from: area.coordinate, to: place.clCoordinate) <= area.radiusMeters
        }
    }
}
