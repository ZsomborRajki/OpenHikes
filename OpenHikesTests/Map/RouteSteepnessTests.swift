//
//  RouteSteepnessTests.swift
//  OpenHikesTests
//
//  How steep each stretch of a route is: the thresholds the scale steps at,
//  the window grades are measured over, the heights averaged before them,
//  and what a gap in the heights, a short last window or a short stretch
//  does to the stretches.
//
//  Routes are built along a meridian with heights set from the distance
//  actually walked, so a stretch built at 12% measures at 12%.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import RealModule
import Testing

@Suite("Route steepness")
struct RouteSteepnessTests {
    /// Metres between points: twenty points to a window.
    private static let spacing = 10.0
    /// A hair over ``spacing`` in degrees, so twenty steps always fill a window
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
            (0.0, RouteShade.easiest), (9.9, .easiest), (10, .easy), (14.9, .easy),
            (15, .moderate), (20, .hard), (29.9, .hard), (30, .harder),
            (39.9, .harder), (40, .hardest), (80, .hardest), (-17, .moderate), (-45, .hardest),
        ]
    )
    func gradeThresholds(grade: Double, shade: RouteShade) {
        #expect(RouteSteepness.shade(forGradePercent: grade) == shade)
    }

    @Test("every step but the first starts at its threshold")
    func lowerBounds() {
        #expect(RouteShade.scale.map(RouteSteepness.lowerBoundPercent(of:)) == [0, 10, 15, 20, 30, 40])
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
        let route = Self.route([(400, 0), (400, 35)])

        let runs = RouteSteepness.runs(route: route)

        #expect(runs.map(\.shade) == [.easiest, .harder])
        let first = try #require(runs.first?.coordinates.last)
        let second = try #require(runs.last?.coordinates.first)
        #expect(first.latitude == second.latitude)
        #expect(runs.map(\.coordinates.count).reduce(0, +) == route.count + 1)
    }

    @Test("a descent is as steep as the same climb")
    func descentCountsAsSteep() {
        let runs = RouteSteepness.runs(route: Self.route([(400, -45)]))

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
        let route = Self.route([(400, 0), (60, 40)])

        let runs = RouteSteepness.runs(route: route)

        #expect(runs.map(\.shade) == [.easiest])
        #expect(runs.first?.coordinates.count == route.count)
    }

    /// What is left after a gap is often shorter than a window, and is the
    /// only measure there is of that ground.
    @Test("a stretch shorter than a window is measured on its own")
    func shortStretchIsMeasured() {
        let runs = RouteSteepness.runs(route: Self.route([(150, 45)]))

        #expect(runs.map(\.shade) == [.hardest])
    }

    /// One fix a few metres out, at the end of a window, was a whole step of
    /// the scale before the heights were averaged.
    @Test("one height that is metres out does not colour the ground around it")
    func aSpikeIsAveragedAway() {
        var route = Self.route([(600, 0)])
        route[20].elevation = route[20].elevation.map { $0 + 25 }

        #expect(RouteSteepness.runs(route: route).map(\.shade) == [.easiest])
    }

    @Test("a stretch shorter than the minimum takes the colour around it")
    func shortStretchJoinsItsSurroundings() {
        let route = Self.route([(400, 0), (200, 50), (600, 0)])

        let runs = RouteSteepness.runs(route: route)

        #expect(runs.map(\.shade) == [.easiest])
        #expect(runs.first?.coordinates.count == route.count)
    }

    /// A short stretch a step from each neighbour is no nearer one than the
    /// other, so the longer one decides.
    @Test("a short stretch as far from both neighbours takes the colour of the longer one")
    func shortStretchJoinsTheLongerNeighbour() {
        let route = Self.route([(400, 0), (200, 17), (600, 35)])

        let runs = RouteSteepness.runs(route: route)

        #expect(runs.map(\.shade) == [.easiest, .harder])
        #expect(runs.map(\.coordinates.count).reduce(0, +) == route.count + 1)
    }

    /// A steady climb whose two windows fall either side of a threshold is
    /// two short stretches; handed to the level ground around them, the
    /// climb would not be drawn at all.
    @Test("a climb split across a threshold keeps its steepness")
    func aSplitClimbStaysAClimb() {
        let route = Self.route([(1000, 0), (200, 25), (200, 35), (1000, 0)])

        let runs = RouteSteepness.runs(route: route)

        #expect(runs.map(\.shade) == [.easiest, .harder, .easiest])
    }

    /// A snapped line's nodes bunch up on a hairpin; counted rather than
    /// measured, they pull the heights beside them towards the bend's.
    @Test("points bunched along a steady climb leave its heights where they are")
    func bunchedPointsDoNotPullTheAverage() throws {
        let sparse = Self.route([(400, 12)])
        var route: [RouteCoordinate] = []
        for (index, (from, to)) in zip(sparse, sparse.dropFirst()).enumerated() {
            let low = try #require(from.elevation)
            let high = try #require(to.elevation)
            let parts = (20..<25).contains(index) ? 10 : 1
            for part in 0..<parts {
                let fraction = Double(part) / Double(parts)
                route.append(RouteCoordinate(
                    latitude: from.latitude + (to.latitude - from.latitude) * fraction,
                    longitude: from.longitude,
                    elevation: low + (high - low) * fraction
                ))
            }
        }
        route.append(try #require(sparse.last))

        let smoothed = RouteSteepness.smoothedHeights(of: route)

        for (point, height) in zip(route, smoothed) {
            let expected = try #require(point.elevation)
            #expect(try #require(height).isApproximatelyEqual(to: expected, absoluteTolerance: 0.01))
        }
    }
}
