//
//  TrailLegRouterOutageTests.swift
//  OpenHikesTests
//
//  A drawn leg across two regions while one of them could not be fetched.
//
//  The provider hands back whatever regions it could read, so a leg whose
//  second region was refused still gets a graph: half of one. The claims held
//  still here are the ones that keep that half from passing for an answer:
//
//  - **What the half cannot route is the region's failure**, which *Retry*
//    asks about again, and never *no mapped path here*, which a drawing keeps
//    — including when Apple Maps cannot route the leg either.
//  - **The leg follows the path once the region arrives.**
//  - **What the half does route is drawn**, as a leg in one region would be.
//
//  Through a stub provider and a scripted Apple router, never the network —
//  see *Deliberate test seams*.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import RealModule
import Testing

@Suite("Trail leg router with a region missing")
struct TrailLegRouterOutageTests {
    /// A path running east across ``RegionalTrailGraphProvider/boundaryLongitude``,
    /// bowed north in the eastern region so a leg along it cannot be mistaken
    /// for the straight line.
    private enum Path {
        static let start = CLLocationCoordinate2D(latitude: 47.7000, longitude: 12.7900)
        static let bend = CLLocationCoordinate2D(latitude: 47.7000, longitude: 12.7960)
        /// Just east of the boundary: a way crossing it is in both regions'
        /// answers, as Overpass gives every way that crosses a region.
        static let crossing = CLLocationCoordinate2D(latitude: 47.7000, longitude: 12.8020)
        /// About 220 m north of the straight line between the leg's ends.
        static let summit = CLLocationCoordinate2D(latitude: 47.7020, longitude: 12.8080)
        static let end = CLLocationCoordinate2D(latitude: 47.7000, longitude: 12.8140)
    }

    /// One way's segments between consecutive `points`, numbered from
    /// `firstNode` and `firstSegment` so the two regions' halves join.
    private static func way(
        _ points: [CLLocationCoordinate2D],
        firstNode: Int64,
        firstSegment: Int
    ) -> TrailGraph {
        let nodes = points.enumerated().map { offset, point in
            TrailGraphNode(id: firstNode + Int64(offset), coordinate: point)
        }
        let edges = zip(nodes, nodes.dropFirst()).enumerated().map { offset, pair in
            TrailGraphEdge(
                id: TrailGraphEdgeID(wayID: 1, segmentIndex: firstSegment + offset),
                fromNodeID: pair.0.id,
                toNodeID: pair.1.id,
                lengthMeters: RouteGeometry.distanceMeters(from: pair.0.coordinate, to: pair.1.coordinate),
                highway: "path"
            )
        }
        return TrailGraph(nodes: nodes, edges: edges)
    }

    private static let westHalf = way([Path.start, Path.bend, Path.crossing], firstNode: 1, firstSegment: 0)
    private static let eastHalf = way([Path.crossing, Path.summit, Path.end], firstNode: 3, firstSegment: 2)

    /// The western region on disk and the eastern one refused.
    private static func provider() -> RegionalTrailGraphProvider {
        RegionalTrailGraphProvider(
            graphs: [RegionalTrailGraphProvider.west: westHalf, RegionalTrailGraphProvider.east: eastHalf],
            withholding: [RegionalTrailGraphProvider.east]
        )
    }

    private static func ends(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D
    ) -> TrailLegEnds {
        TrailLegEnds(from: TrailWaypoint(coordinate: start), to: TrailWaypoint(coordinate: end))
    }

    /// How Apple Maps fails the same leg: with no signal of its own, or with
    /// no route to offer.
    enum AppleFailure: Sendable {
        case offline
        case noRoute
    }

    private static func directions(
        failing failure: AppleFailure,
        counting calls: CallCount
    ) -> DirectionsTrailLegRouter {
        DirectionsTrailLegRouter(mode: .walking) { _, _ in
            await calls.bump()
            switch failure {
            case .offline: throw URLError(.notConnectedToInternet)
            case .noRoute: return []
            }
        }
    }

    // MARK: A hole in the graph

    /// The field case: the region is refused, Apple has nothing either, and
    /// the drawing must still be able to ask again once the signal is back —
    /// and then draw the path the region holds.
    @Test("a leg a missing region could route stays retryable, and follows it once it arrives", arguments: [
        AppleFailure.offline, .noRoute,
    ])
    func missingRegionIsRetried(apple failure: AppleFailure) async throws {
        let provider = Self.provider()
        let calls = CallCount()
        let router = OverpassTrailLegRouter(
            provider: provider,
            fallback: Self.directions(failing: failure, counting: calls)
        )
        let ends = Self.ends(from: Path.start, to: Path.end)

        let refused = try #require(await router.route(ends))

        #expect(refused.snap == .refused(.unavailable), "the region's failure, not no path here")
        #expect(refused.snap.isRetryable, "Retry has something to ask")
        #expect(refused.coordinates == ends.straightCoordinates)

        await provider.restore(RegionalTrailGraphProvider.east)
        let recovered = try #require(await router.route(ends))

        #expect(recovered.snap == .snapped)
        #expect(
            recovered.coordinates.contains { point in
                point.latitude.isApproximatelyEqual(to: Path.summit.latitude, absoluteTolerance: 1e-9)
                    && point.longitude.isApproximatelyEqual(to: Path.summit.longitude, absoluteTolerance: 1e-9)
            },
            "the leg goes over the summit the restored region holds"
        )
        #expect(await calls.value == 1, "Apple is not asked about a leg the graph routes")
    }

    /// A leg whose ends the region on disk already joins does not wait on the
    /// one that is missing.
    @Test("a leg the half that arrived routes is drawn")
    func partialGraphRoutesWhatItHolds() async throws {
        let calls = CallCount()
        let router = OverpassTrailLegRouter(
            provider: Self.provider(),
            fallback: Self.directions(failing: .offline, counting: calls)
        )

        let route = try #require(await router.route(Self.ends(from: Path.start, to: Path.crossing)))

        #expect(route.snap == .snapped)
        #expect(route.coordinates.count > 2)
        #expect(await calls.value == 0)
    }
}

/// How many times a scripted closure ran.
private actor CallCount {
    private(set) var value = 0

    func bump() { value += 1 }
}
