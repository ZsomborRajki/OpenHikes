//
//  SavedRouteDistanceTests.swift
//  OpenHikesTests
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Testing

/// What a finished hike says it was, against what the walker watched it become.
///
/// The two used to be measured by different rules — the live readout ran
/// ``RecordingDistanceAccumulator`` over every fix while a matched save summed
/// the prepared legs — so a walk with a stop in it was saved longer than it had
/// ever been shown, and nothing named either figure as the authoritative one.
@Suite("Saved route distance")
struct SavedRouteDistanceTests {
    private let start = Date(timeIntervalSince1970: 1_750_000_000)

    // MARK: Fixtures

    private func point(
        _ latitude: Double,
        _ longitude: Double,
        at offset: TimeInterval
    ) -> RecordingPoint {
        RecordingPoint(
            latitude: latitude,
            longitude: longitude,
            timestamp: start.addingTimeInterval(offset),
            horizontalAccuracy: 8,
            elevation: 600 + offset / 60
        )
    }

    private func graph(
        nodes: [(Int64, Double, Double)],
        ways: [(Int64, [Int64], String?)]
    ) -> TrailGraph {
        let graphNodes = nodes.map { node in
            TrailGraphNode(
                id: node.0,
                coordinate: CLLocationCoordinate2D(
                    latitude: node.1,
                    longitude: node.2
                )
            )
        }
        let byID = Dictionary(
            uniqueKeysWithValues: graphNodes.map { ($0.id, $0) }
        )
        var edges: [TrailGraphEdge] = []
        for way in ways {
            for index in 0..<(way.1.count - 1) {
                guard let from = byID[way.1[index]],
                      let to = byID[way.1[index + 1]] else { continue }
                edges.append(
                    TrailGraphEdge(
                        id: TrailGraphEdgeID(
                            wayID: way.0,
                            segmentIndex: index
                        ),
                        fromNodeID: from.id,
                        toNodeID: to.id,
                        lengthMeters: RouteGeometry.distanceMeters(
                            from: from.coordinate,
                            to: to.coordinate
                        ),
                        name: way.2,
                        hikingRouteName: nil,
                        sacScale: nil,
                        trailVisibility: nil,
                        access: nil,
                        surface: nil
                    )
                )
            }
        }
        return TrailGraph(nodes: graphNodes, edges: edges)
    }

    /// A walk up one straight trail with a stationary window in the middle:
    /// the walker stands for a minute and a half and lets GPS wander, then
    /// carries on. Every leg snaps, so what gets saved is matched geometry
    /// rather than the recorded trace.
    private func stationaryWindowFixture() -> (
        graph: TrailGraph,
        points: [RecordingPoint]
    ) {
        let trail = graph(
            nodes: [
                (1, 47.6300, 12.8600),
                (2, 47.6340, 12.8600),
            ],
            ways: [(10, [1, 2], "Ridge Path")]
        )
        let metre = 1 / 111_320.0
        var points: [RecordingPoint] = []
        var latitude = 47.6300
        var offset: TimeInterval = 0
        for _ in 0..<6 {
            points.append(point(latitude, 12.86010, at: offset))
            latitude += 15 * metre
            offset += 15
        }
        // Ninety seconds of standing still: five metres of wander along the
        // trail and a couple across it, which is ninety metres of legs and no
        // net displacement at all.
        let standing = latitude
        for step in 0..<9 {
            points.append(point(
                standing + Double((step % 2) * 2 - 1) * 5 * metre,
                step.isMultiple(of: 2) ? 12.860075 : 12.860125,
                at: offset
            ))
            offset += 10
        }
        latitude = standing
        for _ in 0..<6 {
            latitude += 15 * metre
            offset += 15
            points.append(point(latitude, 12.86010, at: offset))
        }
        return (trail, points)
    }

    /// The same stop seen only by Core Motion, and the shape where that
    /// matters: fixes that drift steadily enough that no thirty-second window
    /// is ever short of net displacement, every one of them flagged
    /// stationary, and the recording ending there — a walker who stops at the
    /// top and presses stop. Nothing after the stop re-credits the drift as
    /// the displacement that ends a stationary window, so the flag is the only
    /// thing between the walk and seventy metres it never covered.
    private func driftingStationaryFixture() -> (
        graph: TrailGraph,
        points: [RecordingPoint]
    ) {
        let metre = 1 / 111_320.0
        // Noded every five metres, the way a mapped path is: a matched leg
        // across it is interpolated through the nodes rather than left as the
        // pair of fixes it spans, which is what puts unflagged points in
        // between two the recorder flagged.
        let nodes = (0..<50).map { index in
            (Int64(index + 1), 47.6300 + Double(index) * 5 * metre, 12.8600)
        }
        let trail = graph(
            nodes: nodes,
            ways: [(10, nodes.map(\.0), "Ridge Path")]
        )
        var points: [RecordingPoint] = []
        var latitude = 47.6300
        var offset: TimeInterval = 0
        for _ in 0..<6 {
            points.append(point(latitude, 12.86010, at: offset))
            latitude += 15 * metre
            offset += 15
        }
        for _ in 0..<12 {
            points.append(RecordingPoint(
                latitude: latitude,
                longitude: 12.86010,
                timestamp: start.addingTimeInterval(offset),
                horizontalAccuracy: 8,
                elevation: 600 + offset / 60,
                flags: [.motionStationary]
            ))
            latitude += 6 * metre
            offset += 10
        }
        return (trail, points)
    }

    // MARK: Tests

    /// The walker watches one number climb for the whole walk and is then
    /// shown another one on the saved hike. Summing the matched legs instead
    /// of replaying the recording's own rule handed back the stationary window
    /// the live readout had retracted, and nothing said which figure to trust.
    @Test("a saved matched route measures distance the way the recording did")
    func matchedDistanceFollowsTheLiveAccumulator() throws {
        let fixture = stationaryWindowFixture()
        var live = RecordingDistanceAccumulator()
        for fix in fixture.points { live.append(fix) }

        let prepared = try RecordingPreparation.prepare(
            points: fixture.points,
            startedAt: fixture.points[0].timestamp,
            graph: fixture.graph
        )

        // The case only exists while matching moves the line: a raw trace kept
        // for the hike is what says the saved route is matched geometry.
        #expect(!prepared.rawRoute.isEmpty)
        let plainSum = RouteProfile(route: prepared.route).distances.last ?? 0
        #expect(
            plainSum > prepared.distanceMeters + 50,
            """
            the fixture's stationary window is worth \(plainSum) m summed \
            against \(prepared.distanceMeters) m saved — too little for the \
            two rules to disagree about
            """
        )

        #expect(
            abs(prepared.distanceMeters - live.distanceMeters) < 5,
            """
            the saved hike reports \(prepared.distanceMeters) m where the \
            walker watched \(live.distanceMeters) m accumulate
            """
        )
    }

    /// Core Motion's verdict lives on the fix, and a matched leg replaces two
    /// fixes with a dozen interpolated points. Losing the flag across them
    /// left the saved route with a stop the live readout had already thrown
    /// away — the same disagreement, arriving through the other rule.
    @Test("a matched route keeps Core Motion's verdict on a drifting stop")
    func matchedDistanceKeepsMotionStationaryEvidence() throws {
        let fixture = driftingStationaryFixture()
        var live = RecordingDistanceAccumulator()
        for fix in fixture.points { live.append(fix) }

        let prepared = try RecordingPreparation.prepare(
            points: fixture.points,
            startedAt: fixture.points[0].timestamp,
            graph: fixture.graph
        )

        #expect(!prepared.rawRoute.isEmpty)
        let plainSum = RouteProfile(route: prepared.route).distances.last ?? 0
        #expect(
            plainSum > prepared.distanceMeters + 20,
            """
            the fixture's drift is worth \(plainSum) m summed against \
            \(prepared.distanceMeters) m saved — too little for the flag to \
            make a difference
            """
        )

        #expect(
            abs(prepared.distanceMeters - live.distanceMeters) < 5,
            """
            the saved hike reports \(prepared.distanceMeters) m where the \
            walker watched \(live.distanceMeters) m accumulate
            """
        )
    }
}
