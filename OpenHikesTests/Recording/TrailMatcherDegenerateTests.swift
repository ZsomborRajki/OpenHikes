//
//  TrailMatcherDegenerateTests.swift
//  OpenHikesTests
//
//  The inputs at the edge of what ``TrailMatcher/match(points:graph:gapDistances:)``
//  can be asked: one fix, no fixes, two fixes that never moved, a walk nowhere
//  near the graph, and no graph at all.
//
//  The entry point guards these with `points.count > 1, !graph.isEmpty`, and
//  what that guard protects is not obvious from reading it. Downstream,
//  ``TrailMatcher/buildMatchingLegs(points:selection:gapDistances:index:)``
//  indexes `1..<points.count` and the interpolation divides by a route length,
//  so a single fix or a zero-length leg reaching either would be an out-of-range
//  access or a NaN coordinate written into a saved hike. These assert that the
//  degenerate answers stay degenerate rather than becoming wrong ones — in
//  particular that one fix does not produce a confident match onto whichever
//  edge happens to be nearest, which would silently move a hike's only point.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Testing

@Suite("Trail matcher degenerate input")
struct TrailMatcherDegenerateTests {
    private let start = Date(timeIntervalSince1970: 1_750_000_000)

    private func point(
        _ latitude: Double,
        _ longitude: Double,
        at offset: TimeInterval,
        accuracy: Double = 8
    ) -> RecordingPoint {
        RecordingPoint(
            latitude: latitude,
            longitude: longitude,
            timestamp: start.addingTimeInterval(offset),
            horizontalAccuracy: accuracy,
            elevation: 600
        )
    }

    /// One straight way running east, so a fix on it has exactly one candidate
    /// and any ambiguity in these tests comes from the input rather than the
    /// geometry.
    private func straightGraph() -> TrailGraph {
        let west = TrailGraphNode(
            id: 1,
            coordinate: CLLocationCoordinate2D(latitude: 47.6300, longitude: 12.8600)
        )
        let east = TrailGraphNode(
            id: 2,
            coordinate: CLLocationCoordinate2D(latitude: 47.6300, longitude: 12.8620)
        )
        let edge = TrailGraphEdge(
            id: TrailGraphEdgeID(wayID: 10, segmentIndex: 0),
            fromNodeID: west.id,
            toNodeID: east.id,
            lengthMeters: RouteGeometry.distanceMeters(
                from: west.coordinate,
                to: east.coordinate
            ),
            name: "Straight Trail",
            hikingRouteName: nil,
            sacScale: nil,
            trailVisibility: nil,
            access: nil,
            surface: nil
        )
        return TrailGraph(nodes: [west, east], edges: [edge])
    }

    private func isFinite(_ point: RecordingPoint) -> Bool {
        point.latitude.isFinite && point.longitude.isFinite
    }

    // MARK: - Too little to match

    /// A hike with one fix is handed straight back.
    ///
    /// The fix sits 5 m off a named trail with nothing else nearby, so a
    /// matcher that ignored the count guard would have every reason to snap it
    /// and would report a trail the walker was never observed to be on.
    @Test("a single fix is returned untouched and unmatched")
    func singlePointIsNotMatched() {
        let points = [point(47.63005, 12.8610, at: 0)]

        let result = TrailMatcher.match(points: points, graph: straightGraph())

        #expect(result.points == points)
        #expect(result.legs.isEmpty)
        #expect(result.matchedLegCount == 0)
        #expect(result.ambiguousLegCount == 0)
        #expect(result.ambiguities.isEmpty)
        #expect(result.matchedTrailName == nil)
        #expect(result.currentTrail == nil)
        #expect(!result.didMoveRoute)
    }

    /// The review path has to survive the same input: with no legs there is
    /// nothing to choose between, and resolving must still return the fix
    /// rather than an empty route.
    @Test("resolving a single-fix result returns the fix")
    func singlePointSurvivesResolution() {
        let points = [point(47.63005, 12.8610, at: 0)]

        let result = TrailMatcher.match(points: points, graph: straightGraph())

        #expect(result.points(resolving: [:]) == points)
        #expect(result.points(resolving: [0: .gps]) == points)
    }

    @Test("no fixes produce no route and no legs")
    func emptyInputIsEmpty() {
        let result = TrailMatcher.match(points: [], graph: straightGraph())

        #expect(result.points.isEmpty)
        #expect(result.legs.isEmpty)
        #expect(result.matchedTrailName == nil)
        #expect(!result.didMoveRoute)
    }

    /// An empty graph returns before any leg is built, which is what
    /// distinguishes it from a walk the matcher looked at and abstained on —
    /// see ``walkFarFromTheGraphKeepsItsFixes()``.
    @Test("an empty graph returns the fixes with no legs at all")
    func emptyGraphIsReturnedUnmatched() {
        let points = [
            point(47.6300, 12.8600, at: 0),
            point(47.6300, 12.8610, at: 60),
            point(47.6300, 12.8620, at: 120),
        ]

        let result = TrailMatcher.match(points: points, graph: .empty)

        #expect(result.points == points)
        #expect(result.legs.isEmpty)
        #expect(result.matchedLegCount == 0)
    }

    // MARK: - Enough fixes, nothing to match them to

    /// A walk 40 km from the only mapped trail is looked at properly: legs are
    /// built and reported, they simply carry no trail. The count is the
    /// difference that matters — an early return here would leave the review
    /// screen with nothing to show for a real recording.
    @Test("a walk far from the graph keeps its fixes and reports empty legs")
    func walkFarFromTheGraphKeepsItsFixes() {
        let points = [
            point(48.0000, 13.5000, at: 0),
            point(48.0004, 13.5000, at: 60),
            point(48.0008, 13.5000, at: 120),
        ]

        let result = TrailMatcher.match(points: points, graph: straightGraph())

        #expect(result.points == points)
        #expect(result.legs.count == points.count - 1)
        #expect(result.matchedLegCount == 0)
        #expect(result.ambiguousLegCount == 0)
        #expect(result.matchedTrailName == nil)
        #expect(result.legs.map(\.trailNames) == [[], []])
        #expect(result.legs.allSatisfy { !$0.isBridged })
    }

    // MARK: - Fixes that never moved

    /// Two fixes at the same place and the same instant.
    ///
    /// The interval feeds a divisor and the route length feeds another, and a
    /// zero in either would put a NaN coordinate into a saved hike — where it
    /// survives persistence and only surfaces later as a route that cannot be
    /// drawn. Both are floored rather than avoided, so this asserts the output
    /// is real numbers at the place the walker actually stood.
    @Test("two identical fixes at one instant produce a finite standing route")
    func zeroIntervalDuplicateIsFinite() {
        let stationary = point(47.6300, 12.8610, at: 0)
        let points = [stationary, stationary]

        let result = TrailMatcher.match(points: points, graph: straightGraph())

        #expect(result.points.count == 2)
        #expect(result.points.allSatisfy(isFinite))
        #expect(result.points.allSatisfy { $0.timestamp == stationary.timestamp })
        #expect(result.points.allSatisfy { abs($0.latitude - 47.6300) < 0.00001 })
        #expect(result.points.allSatisfy { abs($0.longitude - 12.8610) < 0.00001 })
        #expect(result.legs.count == 1)
    }

    /// The same pair separated by time rather than distance — a walker who
    /// stopped. The elevation interpolation reads the fraction the route length
    /// produces, so this is the second way a zero-length leg reaches a divisor.
    @Test("two identical fixes minutes apart stay at one place")
    func standingStillProducesNoMovement() {
        let points = [
            point(47.6300, 12.8610, at: 0),
            point(47.6300, 12.8610, at: 120),
        ]

        let result = TrailMatcher.match(points: points, graph: straightGraph())

        #expect(result.points.count == 2)
        #expect(result.points.allSatisfy(isFinite))
        #expect(result.points.allSatisfy { $0.elevation == 600 })
        #expect(result.points.first?.timestamp == points.first?.timestamp)
        #expect(result.points.last?.timestamp == points.last?.timestamp)
        #expect(!result.didMoveRoute)
    }
}
