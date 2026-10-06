//
//  RouteSteepnessTests.swift
//  OpenHikesTests
//
//  How steep each stretch of a route is: the thresholds the scale steps at,
//  the window grades are measured over, and what a gap in the heights or a
//  short last window does to the stretches.
//
//  Routes are built along a meridian with heights set from the distance
//  actually walked, so a stretch built at 12% measures at 12%.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import Testing

@Suite("Route steepness")
struct RouteSteepnessTests {
    /// Metres between points: ten points to a window.
    private static let spacing = 10.0
    /// A hair over ``spacing`` in degrees, so ten steps always fill a window
    /// whatever radius the geometry takes the earth to have.
    private static let latitudeStep = 10.01 / 111_195

    /// A route walked north in legs of `meters` at `percent`, one point every
    /// ``spacing`` metres, starting at 500 m.
    private static func route(_ legs: [(meters: Double, percent: Double)]) -> [RouteCoordinate] {
        var points = [RouteCoordinate(latitude: 47, longitude: 12, elevation: 500)]
        for leg in legs {
            let steps = Int((leg.meters / spacing).rounded())
            for _ in 0..<steps {
                guard let last = points.last, let height = last.elevation else { continue }
                let next = CLLocationCoordinate2D(
                    latitude: last.latitude + latitudeStep,
                    longitude: last.longitude
                )
                let walked = RouteGeometry.distanceMeters(from: last.clCoordinate, to: next)
                points.append(
                    RouteCoordinate(
                        latitude: next.latitude,
                        longitude: next.longitude,
                        elevation: height + walked * leg.percent / 100
                    )
                )
            }
        }
        return points
    }

    @Test(
        "each grade falls on the step its threshold names, up or down",
        arguments: [
            (0.0, RouteShade.easiest), (4.9, .easiest), (5, .easy), (9.9, .easy),
            (10, .moderate), (15, .hard), (19.9, .hard), (20, .harder),
            (29.9, .harder), (30, .hardest), (80, .hardest), (-12, .moderate), (-35, .hardest),
        ]
    )
    func gradeThresholds(grade: Double, shade: RouteShade) {
        #expect(RouteSteepness.shade(forGradePercent: grade) == shade)
    }

    @Test("every step but the first starts at its threshold")
    func lowerBounds() {
        #expect(RouteShade.scale.map(RouteSteepness.lowerBoundPercent(of:)) == [0, 5, 10, 15, 20, 30])
    }

    @Test("a level route is one easy stretch from end to end")
    func levelRouteIsOneStretch() throws {
        let route = Self.route([(400, 0)])

        let runs = RouteSteepness.runs(route: route)

        let only = try #require(runs.count == 1 ? runs.first : nil)
        #expect(only.shade == .easiest)
        #expect(only.coordinates.count == route.count)
    }

    /// Adjacent stretches share the point between them, so the line has no
    /// gap where the colour changes.
    @Test("a climb after a level stretch is a second stretch, joined to the first")
    func climbStartsASecondStretch() throws {
        let route = Self.route([(200, 0), (200, 25)])

        let runs = RouteSteepness.runs(route: route)

        #expect(runs.map(\.shade) == [.easiest, .harder])
        let first = try #require(runs.first?.coordinates.last)
        let second = try #require(runs.last?.coordinates.first)
        #expect(first.latitude == second.latitude)
        #expect(runs.map(\.coordinates.count).reduce(0, +) == route.count + 1)
    }

    @Test("a descent is as steep as the same climb")
    func descentCountsAsSteep() {
        let runs = RouteSteepness.runs(route: Self.route([(300, -32)]))

        #expect(runs.map(\.shade) == [.hardest])
    }

    @Test("a route with no heights has nothing to colour")
    func noHeights() {
        let route = Self.route([(300, 10)]).map { point in
            RouteCoordinate(latitude: point.latitude, longitude: point.longitude)
        }

        #expect(RouteSteepness.runs(route: route).isEmpty)
    }

    /// The colour across a gap would be a grade averaged over ground nobody
    /// measured, so the line keeps its own there instead.
    @Test("a point with no height splits the stretch rather than being measured across")
    func aGapSplitsTheStretch() {
        var route = Self.route([(400, 0)])
        route[20].elevation = nil

        let runs = RouteSteepness.runs(route: route)

        #expect(runs.count == 2)
        #expect(runs.allSatisfy { $0.shade == .easiest })
        let coordinates = runs.flatMap(\.coordinates)
        #expect(!coordinates.contains { $0.latitude == route[20].latitude })
    }

    /// A slope over a few metres is the noise the window exists to average
    /// away, so a short last window takes the grade of the one before it.
    @Test("a short last window joins the stretch before it")
    func shortTailJoinsThePrevious() {
        let route = Self.route([(200, 0), (20, 40)])

        let runs = RouteSteepness.runs(route: route)

        #expect(runs.map(\.shade) == [.easiest])
        #expect(runs.first?.coordinates.count == route.count)
    }

    @Test("a last window of half a window or more is measured on its own")
    func longTailIsMeasured() {
        let route = Self.route([(200, 0), (60, 40)])

        let runs = RouteSteepness.runs(route: route)

        #expect(runs.map(\.shade) == [.easiest, .hardest])
    }
}
