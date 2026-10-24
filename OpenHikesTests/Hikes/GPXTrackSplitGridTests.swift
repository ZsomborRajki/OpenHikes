//
//  GPXTrackSplitGridTests.swift
//  OpenHikesTests
//
//  The split measures a waypoint against the pieces of a route filed near it
//  rather than against every piece of every route it might lie on, which
//  took seconds for ten thousand waypoints along a day's track (#1037). These
//  hold the grid to the answers measuring every piece gives — the nearer
//  route wins, and a waypoint goes to one route or to none — on the routes it
//  files and on the ones it still measures whole.
//
//  Nothing here is timed. A clock in a hosted suite measures the machine;
//  the answers are what the grid must not move.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import Testing

@Suite("GPX track split grid")
struct GPXTrackSplitGridTests {
    /// A seeded generator, so a failure is the same inputs on every run.
    private struct SplitMix: RandomNumberGenerator {
        var state: UInt64

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var mixed = state
            mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
            mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
            return mixed ^ (mixed >> 31)
        }
    }

    /// The items each route takes, by index, measuring every piece of every
    /// route: the answer the split gave before it had a grid.
    private static func measuredWhole(_ items: [CLLocationCoordinate2D], to routes: [[RouteCoordinate]]) -> [[Int]] {
        var assigned = Array(repeating: [Int](), count: routes.count)
        for (index, item) in items.enumerated() {
            let nearest = routes.indices
                .compactMap { route in
                    GPXTrackSplit.offRouteMeters(of: item, along: routes[route]).map { (route, $0) }
                }
                .min { $0.1 < $1.1 }
            if let nearest, nearest.1 <= TrailPlaceAnchor.touchedOffRouteMeters {
                assigned[nearest.0].append(index)
            }
        }
        return assigned
    }

    private static func split(_ items: [CLLocationCoordinate2D], to routes: [[RouteCoordinate]]) -> [[Int]] {
        GPXTrackSplit.assign(Array(items.indices), at: { items[$0] }, to: routes)
    }

    /// `east` and `north` metres from `origin`, across ±180° if it comes to it.
    private static func moved(
        _ origin: CLLocationCoordinate2D,
        east: Double,
        north: Double
    ) -> CLLocationCoordinate2D {
        let metersPerDegree = 111_195.0
        return CLLocationCoordinate2D(
            latitude: origin.latitude + north / metersPerDegree,
            longitude: RouteGeometry.normalizedLongitude(
                origin.longitude + east / (metersPerDegree * cos(origin.latitude * .pi / 180))
            )
        )
    }

    /// A route that wanders off from `start`: mostly short legs, one in ten
    /// of up to most of a kilometre — too long to file — a pause now and then,
    /// and one fix with a pause on both sides of it.
    private static func wander(
        from start: CLLocationCoordinate2D,
        using generator: inout SplitMix
    ) -> [RouteCoordinate] {
        var route: [RouteCoordinate] = []
        var here = start
        var bearing = Double.random(in: 0..<(2 * .pi), using: &generator)
        for index in 0..<250 {
            let paused = index > 0 && (Int.random(in: 0..<25, using: &generator) == 0 || index == 125 || index == 126)
            route.append(
                RouteCoordinate(latitude: here.latitude, longitude: here.longitude, boundary: paused ? .paused : nil)
            )
            bearing += Double.random(in: -0.6...0.6, using: &generator)
            let length = Int.random(in: 0..<10, using: &generator) == 0
                ? Double.random(in: 300...900, using: &generator)
                : Double.random(in: 2...60, using: &generator)
            here = moved(here, east: sin(bearing) * length, north: cos(bearing) * length)
        }
        return route
    }

    /// The review's benchmark, at a suite's size: a track of a thousand fixes
    /// about a metre apart, a distant one of two, and waypoints along the
    /// first — half on it, half scattered to twice the touching distance
    /// either side.
    @Test("a day's track and the waypoints along it are shared out as measuring every leg shares them")
    func waypointsAlongADaysTrack() {
        let track = (0..<1000).map { RouteCoordinate(latitude: 47 + 0.00001 * Double($0), longitude: 12) }
        let distant = [RouteCoordinate(latitude: 50, longitude: 20), RouteCoordinate(latitude: 50.01, longitude: 20)]
        var generator = SplitMix(state: 1037)
        let onIt = (0..<500).map { CLLocationCoordinate2D(latitude: 47 + 0.00002 * Double($0), longitude: 12) }
        let either = (0..<500).map { _ in
            Self.moved(
                CLLocationCoordinate2D(latitude: Double.random(in: 47...47.01, using: &generator), longitude: 12),
                east: Double.random(in: -100...100, using: &generator),
                north: 0
            )
        }
        let items = onIt + either

        let split = Self.split(items, to: [track, distant])

        #expect(split == Self.measuredWhole(items, to: [track, distant]))
        #expect(Array(split[0].prefix(onIt.count)) == Array(onIt.indices))
        #expect(split[1].isEmpty)
    }

    /// Three routes wandering from one start, so many waypoints lie near two
    /// or three of them: far north, where a degree of longitude is a few
    /// kilometres; across the antimeridian; and on the cell boundaries at 0°.
    @Test(
        "wandering routes with pauses and long legs are shared out as measuring every piece shares them",
        arguments: [(46.5, 11.5), (84.0, 30.0), (-84.0, -60.0), (10.0, 179.995), (0.0, 0.0)]
    )
    func wanderingRoutes(latitude: Double, longitude: Double) {
        var generator = SplitMix(state: 1050)
        let start = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        let routes = (0..<3).map { _ in Self.wander(from: start, using: &generator) }
        let items = (0..<600).map { _ in
            let route = routes[Int.random(in: routes.indices, using: &generator)]
            return Self.moved(
                route[Int.random(in: route.indices, using: &generator)].clCoordinate,
                east: Double.random(in: -150...150, using: &generator),
                north: Double.random(in: -150...150, using: &generator)
            )
        }

        let split = Self.split(items, to: routes)

        #expect(split == Self.measuredWhole(items, to: routes))
        #expect(split.joined().count > items.count / 4, "enough of them lie on a route for the comparison to mean much")
    }

    /// At the touching distance itself, east and west of a line running north,
    /// where the grid's margin is narrowest against what it must hold.
    @Test("at the touching distance the grid agrees with measuring every piece", arguments: [0.0, 45.0, 70.0, 84.0])
    func atTheTouchingDistance(latitude: Double) {
        let line = (0..<20).map { RouteCoordinate(latitude: latitude + 0.0005 * Double($0), longitude: 7) }
        let beside = CLLocationCoordinate2D(latitude: latitude + 0.0042, longitude: 7)
        let items = stride(from: 49.0, through: 51.0, by: 0.05).flatMap { meters in
            [Self.moved(beside, east: meters, north: 0), Self.moved(beside, east: -meters, north: 0)]
        }

        let split = Self.split(items, to: [line])

        #expect(split == Self.measuredWhole(items, to: [line]))
        #expect(!split[0].isEmpty && split[0].count < items.count, "the touching distance falls among them")
    }

    /// Two kinds the grid leaves to measuring whole: a route reaching half
    /// way round the world, and one whose every leg is a degree long.
    @Test("routes the grid does not file are measured whole, with the same answers")
    func unfiledRoutesAreMeasuredWhole() {
        let alongTheEquator = { (longitudes: StrideThrough<Double>) in
            longitudes.map { RouteCoordinate(latitude: 0, longitude: $0) }
        }
        let halfwayRound = alongTheEquator(stride(from: -100, through: 100, by: 1))
        let longLegs = alongTheEquator(stride(from: -80, through: 80, by: 1))
        // On the line, 33 m north of it, and 67 m north of it.
        let items = stride(from: -70.0, through: 70.0, by: 0.5).flatMap { longitude in
            [0.0, 0.0003, 0.0006].map { CLLocationCoordinate2D(latitude: $0, longitude: longitude) }
        }

        for route in [halfwayRound, longLegs] {
            let split = Self.split(items, to: [route])
            #expect(split == Self.measuredWhole(items, to: [route]))
            #expect(split[0].count == 2 * items.count / 3)
        }
    }

    /// A file with the same track twice: a waypoint on it is as near to both,
    /// and goes to the first.
    @Test("a waypoint as near to two tracks goes to the first")
    func aTieGoesToTheFirst() {
        let track = (0..<200).map { RouteCoordinate(latitude: 47 + 0.0001 * Double($0), longitude: 12) }
        let items = (0..<50).map { CLLocationCoordinate2D(latitude: 47 + 0.0004 * Double($0), longitude: 12.0002) }

        let split = Self.split(items, to: [track, track])

        #expect(split == [Array(items.indices), []])
        #expect(split == Self.measuredWhole(items, to: [track, track]))
    }
}
