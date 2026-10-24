//
//  PausedLegEdgeReadingTests.swift
//  OpenHikesTests
//
//  The app's readers of the paused-leg rule (#962) at the edges where the
//  readings used to disagree without anything saying so (#1035): a lone fix
//  between two pauses, a pause on a route's first or last leg, a route made of
//  nothing but lone fixes, and a route of one point.
//
//  Each reads the rule through ``TrailRuns``, and keeps its own answer for a
//  lone fix. A waypoint's track and a photograph's place measure to one as a
//  point, because it is a fix the track recorded. The steepness colours and
//  the surface breakdown give it nothing, because a slope and a surface are
//  properties of a leg, and a lone fix has none.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import RealModule
import Testing

// swiftlint:disable no_magic_numbers

@Suite("The app's readers of the paused-leg rule at its edges")
struct PausedLegEdgeReadingTests {
    /// About 111 m of latitude.
    private static let stepDegrees = 0.001
    private static let south = 47.0
    private static let longitude = 12.0
    private static let step = RouteGeometry.distanceMeters(
        from: at(0),
        to: at(1)
    )

    private static func at(_ steps: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: south + steps * stepDegrees, longitude: longitude)
    }

    /// Points due north, `offsets` in steps, the ones named in `resumed`
    /// arriving after a pause and the ones in `inferred` across a bridge.
    private static func route(
        _ offsets: [Double],
        resumingAt resumed: Set<Int> = [],
        inferred: Set<Int> = [],
        elevations: [Double?] = [],
        timed: Bool = false
    ) -> [RouteCoordinate] {
        offsets.enumerated().map { index, offset in
            RouteCoordinate(
                latitude: south + offset * stepDegrees,
                longitude: longitude,
                elevation: elevations.isEmpty ? nil : elevations[index],
                timestamp: timed ? Date(timeIntervalSince1970: 1_750_000_000 + Double(index) * 60) : nil,
                provenance: inferred.contains(index) ? .inferred : nil,
                boundary: resumed.contains(index) ? .paused : nil
            )
        }
    }

    /// Walked from 0 to 1, a lone fix at 6 with a pause either side of it,
    /// then walked from 9 to 10.
    private static let loneFix = route([0, 1, 6, 9, 10], resumingAt: [2, 3])

    // MARK: - A waypoint's track

    @Test("a waypoint's track measures a lone fix, and the fix a first or last pause leaves, as points")
    func trackMeasuresLoneFixesAsPoints() throws {
        let ends = Self.route([0, 5, 6, 7, 12], resumingAt: [1, 4])

        let first = try #require(GPXTrackSplit.offRouteMeters(of: Self.at(0), along: ends))
        let last = try #require(GPXTrackSplit.offRouteMeters(of: Self.at(12), along: ends))
        let acrossFirstPause = try #require(GPXTrackSplit.offRouteMeters(of: Self.at(2), along: ends))
        let lone = try #require(GPXTrackSplit.offRouteMeters(of: Self.at(6), along: Self.loneFix))

        #expect(first.isApproximatelyEqual(to: 0, absoluteTolerance: 0.01))
        #expect(last.isApproximatelyEqual(to: 0, absoluteTolerance: 0.01))
        #expect(acrossFirstPause.isApproximatelyEqual(to: 2 * Self.step, absoluteTolerance: 0.5))
        #expect(lone.isApproximatelyEqual(to: 0, absoluteTolerance: 0.01))
    }

    @Test("a track of lone fixes still has its fixes, and a track of one point has none")
    func trackOfLoneFixesKeepsItsFixes() throws {
        let lonely = Self.route([0, 10, 20], resumingAt: [1, 2])

        let onTheMiddle = try #require(GPXTrackSplit.offRouteMeters(of: Self.at(10), along: lonely))
        let between = try #require(GPXTrackSplit.offRouteMeters(of: Self.at(5), along: lonely))

        #expect(onTheMiddle.isApproximatelyEqual(to: 0, absoluteTolerance: 0.01))
        #expect(between.isApproximatelyEqual(to: 5 * Self.step, absoluteTolerance: 0.5))
        #expect(GPXTrackSplit.offRouteMeters(of: Self.at(0), along: Self.route([0])) == nil)
    }

    // MARK: - A photograph's place

    @Test("a photograph's route measures the fix a last pause leaves as a point")
    func photoRouteMeasuresTheLastLoneFix() throws {
        let legs = RecordedRouteLegs(route: Self.route([0, 1, 2, 7], resumingAt: [3]))

        let last = try #require(legs.nearestPoint(to: Self.at(7)))
        let acrossThePause = try #require(legs.nearestPoint(to: Self.at(4)))

        #expect(last.meters.isApproximatelyEqual(to: 0, absoluteTolerance: 0.01))
        #expect(acrossThePause.meters.isApproximatelyEqual(to: 2 * Self.step, absoluteTolerance: 0.5))
    }

    @Test("a photograph's route refuses a bridge as it refuses a pause, and keeps the fix between them")
    func photoRouteRefusesBridgesAndPausesAlike() throws {
        let legs = RecordedRouteLegs(route: Self.route([0, 1, 6, 9, 10], resumingAt: [2], inferred: [3]))

        let onTheFix = try #require(legs.nearestPoint(to: Self.at(6)))
        let alongTheBridge = try #require(legs.nearestPoint(to: Self.at(7.5)))

        #expect(onTheFix.meters.isApproximatelyEqual(to: 0, absoluteTolerance: 0.01))
        #expect(alongTheBridge.meters.isApproximatelyEqual(to: 1.5 * Self.step, absoluteTolerance: 0.5))
    }

    @Test("a photograph's route of lone fixes measures to the nearest of them")
    func photoRouteOfLoneFixes() throws {
        let legs = RecordedRouteLegs(route: Self.route([0, 10, 20], resumingAt: [1, 2]))

        let near = try #require(legs.nearestPoint(to: Self.at(12)))

        #expect(near.meters.isApproximatelyEqual(to: 2 * Self.step, absoluteTolerance: 0.5))
        #expect(near.coordinate.latitude.isApproximatelyEqual(to: Self.at(10).latitude, absoluteTolerance: 1e-9))
    }

    // MARK: - Steepness

    @Test("steepness colours nothing at a lone fix, and never joins the runs either side of it")
    func steepnessSkipsALoneFix() {
        let route = Self.route(
            [0, 1, 2, 3, 3.5, 6, 9, 9.5, 10, 11, 12],
            resumingAt: [5, 6],
            elevations: [100, 100, 100, 100, 100, 900, 100, 100, 100, 100, 100]
        )

        let runs = RouteSteepness.runs(route: route)

        #expect(runs.count == 2)
        #expect(runs.allSatisfy { $0.shade == RouteShade.scale[0] }, "level either side")
        let lone = Self.at(6).latitude
        #expect(runs.allSatisfy { run in
            !run.coordinates.contains { $0.latitude.isApproximatelyEqual(to: lone, absoluteTolerance: 1e-9) }
        })
    }

    @Test("steepness colours nothing on a route of lone fixes")
    func steepnessOfLoneFixesIsNothing() {
        let route = Self.route([0, 10, 20], resumingAt: [1, 2], elevations: [100, 500, 900])

        #expect(RouteSteepness.runs(route: route).isEmpty)
    }

    // MARK: - The surface breakdown

    @Test("a surface breakdown leaves a lone fix out, and starts afresh after it")
    func breakdownSkipsALoneFix() async throws {
        let route = Self.route([0, 1, 6, 9, 10], resumingAt: [2, 3])

        let runs = try await TrailBreakdownAnalyzer.runs(of: TrailSurface.self, route: route, graph: Self.gravel)

        #expect(runs.map(\.category) == [.gravel, .gravel])
        #expect(runs.first?.coordinates.last?.latitude.isApproximatelyEqual(
            to: Self.at(1).latitude,
            absoluteTolerance: 1e-9
        ) == true)
        #expect(runs.last?.coordinates.first?.latitude.isApproximatelyEqual(
            to: Self.at(9).latitude,
            absoluteTolerance: 1e-9
        ) == true)
    }

    @Test("a surface breakdown with its first leg paused starts where the walking did")
    func breakdownAfterAPausedFirstLeg() async throws {
        let route = Self.route([4, 9, 10], resumingAt: [1])

        let runs = try await TrailBreakdownAnalyzer.runs(of: TrailSurface.self, route: route, graph: Self.gravel)

        #expect(runs.map(\.category) == [.gravel])
        #expect(runs.first?.coordinates.first?.latitude.isApproximatelyEqual(
            to: Self.at(9).latitude,
            absoluteTolerance: 1e-9
        ) == true)
    }

    /// Gravel from 0 to 1 and from 9 to 10, nothing between.
    private static let gravel: TrailGraph = {
        let nodes = [(1, 0.0), (2, 1.0), (3, 9.0), (4, 10.0)].map { id, offset in
            TrailGraphNode(id: Int64(id), coordinate: at(offset))
        }
        let edges = [(10, 0), (11, 2)].map { wayID, first in
            TrailGraphEdge(
                id: TrailGraphEdgeID(wayID: Int64(wayID), segmentIndex: 0),
                fromNodeID: nodes[first].id,
                toNodeID: nodes[first + 1].id,
                lengthMeters: RouteGeometry.distanceMeters(
                    from: nodes[first].coordinate,
                    to: nodes[first + 1].coordinate
                ),
                surface: "gravel",
                tracktype: nil
            )
        }
        return TrailGraph(nodes: nodes, edges: edges)
    }()

    // MARK: - A photograph's timeline

    @Test("a photograph's timeline numbers a lone fix a recording segment of its own")
    func timelineNumbersALoneFix() throws {
        let route = Self.route([0, 1, 6, 9, 10], resumingAt: [2, 3], timed: true)

        let timeline = try #require(HikePhotoTimeline(route: route))

        #expect(timeline.fixes.map(\.segment) == [0, 0, 1, 2, 2])
    }
}

// swiftlint:enable no_magic_numbers
