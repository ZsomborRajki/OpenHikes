//
//  TrailPlaceCorridorSearchTests.swift
//  OpenHikesTests
//
//  *Places Around Trail*: how a finished line is cut into questions, and
//  what is kept of the answers.
//
//  The two halves are separate on purpose. The cutting is geometry, and its
//  promise is that no piece of the line goes unasked about while no one
//  question is wider than the query's measured box. The keeping is the
//  maker's own save rule — the places the line passes — applied to a trail
//  that never went through the maker.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import RealModule
import Testing

@MainActor
@Suite("Places along a trail")
struct TrailPlaceCorridorSearchTests {
    private enum Line {
        static let longitude = 12.98
        static let south = 47.60
        /// About 2.2 km of latitude.
        static let north = 47.62
        static let short = [
            RouteCoordinate(latitude: south, longitude: longitude),
            RouteCoordinate(latitude: north, longitude: longitude),
        ]
    }

    /// A straight line north, `kilometres` long, one point every 100 m.
    private static func line(kilometres: Double) -> [RouteCoordinate] {
        let step = 100 / RouteGeometry.metersPerDegreeLatitude
        let count = Int(kilometres * 10)
        return (0...count).map { index in
            RouteCoordinate(latitude: Line.south + Double(index) * step, longitude: Line.longitude)
        }
    }

    private static func place(
        _ id: Int64,
        latitude: Double,
        offEast metres: Double = 0,
        symbol: TrailPlaceSymbol = .water
    ) -> TrailPlace {
        let degrees = metres / (RouteGeometry.metersPerDegreeLatitude * cos(latitude * .pi / 180))
        return TrailPlace(
            latitude: latitude,
            longitude: Line.longitude + degrees,
            symbol: symbol,
            osm: TrailPlaceOSM(elementType: "node", elementID: id)
        )
    }

    // MARK: Cutting the line

    @Test("a short line is one question")
    func shortLineIsOneArea() {
        let areas = TrailPlaceCorridorSearch.areas(along: Line.short)
        #expect(areas.count == 1)
        #expect(areas[0].radiusMeters <= TrailPlaceCorridorSearch.stretchRadiusMeters)
    }

    @Test("a long line is cut into circles no wider than a stretch, covering every point")
    func longLineIsCovered() {
        let route = Self.line(kilometres: 40)
        let areas = TrailPlaceCorridorSearch.areas(along: route)

        #expect(areas.count > 1)
        #expect(areas.allSatisfy { $0.radiusMeters <= TrailPlaceCorridorSearch.stretchRadiusMeters })
        for point in route {
            let covered = areas.contains { area in
                RouteGeometry.distanceMeters(from: area.coordinate, to: point.clCoordinate) <= area.radiusMeters
            }
            #expect(covered)
        }
    }

    @Test("a very long line widens its stretches rather than asking without end")
    func veryLongLineIsCapped() {
        let areas = TrailPlaceCorridorSearch.areas(along: Self.line(kilometres: 300))
        #expect(areas.count <= TrailPlaceCorridorSearch.maximumAreas)
        #expect(areas.allSatisfy { $0.radiusMeters <= TrailPointQuery.maximumRadiusMeters })
    }

    @Test("a line with a segment longer than a stretch is still asked about all along it")
    func sparseLineIsCovered() {
        // Two points 30 km apart: a gap no stretch can hold whole, which used
        // to become one circle wider than the query answers.
        let far = RouteCoordinate(
            latitude: Line.south + 30_000 / RouteGeometry.metersPerDegreeLatitude,
            longitude: Line.longitude
        )
        let route = [Line.short[0], far]
        let areas = TrailPlaceCorridorSearch.areas(along: route)

        #expect(areas.count > 1)
        #expect(areas.allSatisfy { $0.radiusMeters <= TrailPlaceCorridorSearch.stretchRadiusMeters })
        for kilometre in 0...30 {
            let point = CLLocationCoordinate2D(
                latitude: Line.south + Double(kilometre) * 1000 / RouteGeometry.metersPerDegreeLatitude,
                longitude: Line.longitude
            )
            let covered = areas.contains { area in
                RouteGeometry.distanceMeters(from: area.coordinate, to: point) <= area.radiusMeters
            }
            #expect(covered, "kilometre \(kilometre) is in no circle")
        }
    }

    @Test("a single point is nothing to ask about")
    func singlePointIsNothing() {
        #expect(TrailPlaceCorridorSearch.areas(along: [Line.short[0]]).isEmpty)
    }

    // MARK: Across the antimeridian

    /// Where a line across ±180° is drawn: the Taveuni coast in Fiji, a
    /// latitude away from the equator so the longitude span is not its
    /// distance.
    private enum Dateline {
        static let latitude = -16.8
        /// About 2.1 km apart, the short way round.
        static let short = (westOfIt: 179.99, eastOfIt: -179.99)
        /// About 32 km apart: longer than a stretch, so the gap is filled in.
        static let long = (westOfIt: 179.85, eastOfIt: -179.85)
    }

    /// Every kilometre of the line from `start` to `end`, walked the short way
    /// round, sits in one of `areas` — and none of them is wider than a
    /// stretch.
    private static func expectCovered(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D,
        by areas: [CommunitySearchArea]
    ) {
        #expect(!areas.isEmpty)
        #expect(areas.allSatisfy { $0.radiusMeters <= TrailPlaceCorridorSearch.stretchRadiusMeters })
        let length = RouteGeometry.distanceMeters(from: start, to: end)
        let kilometres = Int(length / 1000)
        for kilometre in 0...(kilometres + 1) {
            let fraction = min(Double(kilometre) * 1000 / length, 1)
            let point = RouteGeometry.interpolate(from: start, to: end, fraction: fraction)
            let covered = areas.contains { area in
                RouteGeometry.distanceMeters(from: area.coordinate, to: point) <= area.radiusMeters
            }
            #expect(covered, "\(point.latitude), \(point.longitude) is in no circle")
        }
    }

    @Test(
        "a short line across ±180° is asked about where it is, in either direction",
        arguments: [true, false]
    )
    func shortCrossingIsCovered(eastward: Bool) {
        let west = CLLocationCoordinate2D(latitude: Dateline.latitude, longitude: Dateline.short.westOfIt)
        let east = CLLocationCoordinate2D(latitude: Dateline.latitude, longitude: Dateline.short.eastOfIt)
        let (start, end) = eastward ? (west, east) : (east, west)
        let route = [start, end].map { RouteCoordinate(latitude: $0.latitude, longitude: $0.longitude) }

        let areas = TrailPlaceCorridorSearch.areas(along: route)

        #expect(areas.count == 1)
        Self.expectCovered(from: start, to: end, by: areas)
    }

    @Test(
        "a long segment across ±180° is filled in the short way round, in either direction",
        arguments: [true, false]
    )
    func longCrossingIsCovered(eastward: Bool) {
        let west = CLLocationCoordinate2D(latitude: Dateline.latitude, longitude: Dateline.long.westOfIt)
        let east = CLLocationCoordinate2D(latitude: Dateline.latitude, longitude: Dateline.long.eastOfIt)
        let (start, end) = eastward ? (west, east) : (east, west)
        let route = [start, end].map { RouteCoordinate(latitude: $0.latitude, longitude: $0.longitude) }

        let areas = TrailPlaceCorridorSearch.areas(along: route)

        #expect(areas.count > 1)
        Self.expectCovered(from: start, to: end, by: areas)
    }

    // MARK: Keeping the answers

    @Test("only what the line passes is kept, once each, in walking order")
    func keepsWhatTheLinePasses() {
        let near = Self.place(1, latitude: 47.615)
        let first = Self.place(2, latitude: 47.605, offEast: 20)
        let far = Self.place(3, latitude: 47.61, offEast: 400)

        let kept = TrailPlaceCorridorSearch.kept([near, far, first, near], along: Line.short, excluding: [])

        #expect(kept.map(\.place.osm?.elementID) == [2, 1])
    }

    @Test("what the hike already holds is left out, by element and by place")
    func leavesOutWhatIsHeld() {
        let held = Self.place(1, latitude: 47.615)
        let sameElement = Self.place(1, latitude: 47.605)
        let samePlace = Self.place(9, latitude: 47.61501)
        let fresh = Self.place(4, latitude: 47.608)

        let kept = TrailPlaceCorridorSearch.kept(
            [sameElement, samePlace, fresh],
            along: Line.short,
            excluding: [held]
        )

        #expect(kept.map(\.place.osm?.elementID) == [4])
    }

    // MARK: Asking

    @Test("a refused stretch is answered from the device and the refusal is reported")
    func refusalFallsBackToStore() async throws {
        let stored = Self.place(5, latitude: 47.61)
        let source = RefusingSource(stored: [stored])

        let outcome = try await TrailPlaceCorridorSearch.search(
            along: Line.short,
            excluding: [],
            from: source,
            showing: Set(TrailPlaceSymbol.allCases)
        )

        #expect(outcome.places.map(\.osm?.elementID) == [5])
        #expect(outcome.outage != nil)
    }

    @Test("kinds switched off are left out of what is kept")
    func switchedOffKindsAreLeftOut() async throws {
        let spring = Self.place(1, latitude: 47.605)
        let car = Self.place(2, latitude: 47.61, symbol: .parking)
        let source = AnsweringSource(answer: [spring, car])

        let outcome = try await TrailPlaceCorridorSearch.search(
            along: Line.short,
            excluding: [],
            from: source,
            showing: [.water]
        )

        #expect(outcome.places.map(\.osm?.elementID) == [1])
        #expect(outcome.outage == nil)
    }

    // MARK: Reaching past the line

    @Test("a wider reach keeps what stands off the line within it, and nothing past it")
    func widerReachKeepsNearbyPlaces() throws {
        let onTheLine = Self.place(1, latitude: 47.605)
        let upTheSidePath = Self.place(2, latitude: 47.61, offEast: 400)
        let acrossTheValley = Self.place(3, latitude: 47.615, offEast: 700)

        let kept = TrailPlaceCorridorSearch.kept(
            [acrossTheValley, upTheSidePath, onTheLine],
            along: Line.short,
            excluding: [],
            reaching: 500
        )

        #expect(kept.map(\.place.osm?.elementID) == [1, 2])
        let off = try #require(kept.last?.offRouteMeters)
        #expect(off.isApproximatelyEqual(to: 400, absoluteTolerance: 5))
    }

    @Test("a wider reach widens every circle so the band beside the line is asked about")
    func widerReachWidensTheCircles() {
        let route = Self.line(kilometres: 20)
        let areas = TrailPlaceCorridorSearch.areas(along: route, reaching: 1000)

        #expect(areas.allSatisfy { $0.radiusMeters <= TrailPointQuery.maximumRadiusMeters })
        for point in route {
            let metresPerDegree = RouteGeometry.metersPerDegreeLatitude * cos(point.latitude * .pi / 180)
            let beside = RouteCoordinate(latitude: point.latitude, longitude: point.longitude + 1000 / metresPerDegree)
            let covered = areas.contains { area in
                RouteGeometry.distanceMeters(from: area.coordinate, to: beside.clCoordinate) <= area.radiusMeters
            }
            #expect(covered)
        }
    }

    @Test("a search reaching past the line keeps what it reaches")
    func searchReachesPastTheLine() async throws {
        let spring = Self.place(1, latitude: 47.605)
        let hut = Self.place(2, latitude: 47.61, offEast: 400, symbol: .shelter)
        let source = AnsweringSource(answer: [spring, hut])

        let narrow = try await TrailPlaceCorridorSearch.search(
            along: Line.short,
            excluding: [],
            from: source,
            showing: Set(TrailPlaceSymbol.allCases)
        )
        let wide = try await TrailPlaceCorridorSearch.search(
            along: Line.short,
            excluding: [],
            from: source,
            showing: Set(TrailPlaceSymbol.allCases),
            reaching: 1000
        )

        #expect(narrow.places.map(\.osm?.elementID) == [1])
        #expect(wide.places.map(\.osm?.elementID) == [1, 2])
    }
}

private struct AnsweringSource: TrailPointSourcing {
    let answer: [TrailPlace]

    func places(near _: CommunitySearchArea, showing _: Set<TrailPlaceSymbol>) -> [TrailPlace] {
        answer
    }
}

private struct RefusingSource: TrailPointSourcing {
    let stored: [TrailPlace]

    /// What a gateway in front of a busy Overpass answers with.
    private static let gatewayTimeout = 504

    func places(near _: CommunitySearchArea, showing _: Set<TrailPlaceSymbol>) throws -> [TrailPlace] {
        throw TrailGraphProviderError.server(statusCode: Self.gatewayTimeout)
    }

    func cachedPlaces(near _: CommunitySearchArea, limit _: Int) -> [TrailPlace] {
        stored
    }
}
