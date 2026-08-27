//
//  TrailSurfaceTests.swift
//  OpenHikesTests
//
//  Covers classifying OSM surface tagging, aggregating it into shares, and
//  attributing a route's metres to the ways beneath it.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Testing

// MARK: - Fixtures

/// Metres per degree at the latitudes these fixtures use, so an offset can be
/// written as the distance it is meant to represent.
nonisolated private let metersPerDegreeLongitude = 74_933.0
nonisolated private let metersPerDegreeLatitude = 111_195.0

nonisolated private func longitude(_ base: Double, eastMeters: Double) -> Double {
    base + eastMeters / metersPerDegreeLongitude
}

nonisolated private struct WayFixture {
    let id: Int64
    let nodeIDs: [Int64]
    var surface: String?
    var tracktype: String?
}

nonisolated private func makeGraph(
    nodes: [(id: Int64, latitude: Double, longitude: Double)],
    ways: [WayFixture]
) -> TrailGraph {
    let graphNodes = nodes.map { node in
        TrailGraphNode(
            id: node.id,
            coordinate: CLLocationCoordinate2D(
                latitude: node.latitude,
                longitude: node.longitude
            )
        )
    }
    let byID = Dictionary(uniqueKeysWithValues: graphNodes.map { ($0.id, $0) })
    var edges: [TrailGraphEdge] = []
    for way in ways {
        for index in 0..<(way.nodeIDs.count - 1) {
            guard let from = byID[way.nodeIDs[index]],
                  let to = byID[way.nodeIDs[index + 1]] else { continue }
            edges.append(
                TrailGraphEdge(
                    id: TrailGraphEdgeID(wayID: way.id, segmentIndex: index),
                    fromNodeID: from.id,
                    toNodeID: to.id,
                    lengthMeters: RouteGeometry.distanceMeters(
                        from: from.coordinate,
                        to: to.coordinate
                    ),
                    surface: way.surface,
                    tracktype: way.tracktype
                )
            )
        }
    }
    return TrailGraph(nodes: graphNodes, edges: edges)
}

nonisolated private func route(
    _ points: [(latitude: Double, longitude: Double)]
) -> [RouteCoordinate] {
    points.map { point in
        RouteCoordinate(latitude: point.latitude, longitude: point.longitude)
    }
}

// MARK: - Classification

@Suite("Trail surface classification")
struct TrailSurfaceClassificationTests {
    @Test(
        "OSM surface values collapse onto the categories a walker plans around",
        arguments: [
            ("asphalt", TrailSurface.paved),
            ("concrete:plates", .paved),
            ("paving_stones", .paved),
            ("sett", .paved),
            ("wood", .paved),
            ("gravel", .gravel),
            ("fine_gravel", .gravel),
            ("compacted", .gravel),
            ("pebblestone", .gravel),
            ("ground", .ground),
            ("dirt", .ground),
            ("grass", .ground),
            ("sand", .ground),
            ("unpaved", .ground),
            ("rock", .rock),
            ("scree", .rock),
        ]
    )
    func classifiesSurfaceValues(value: String, expected: TrailSurface) {
        #expect(TrailSurface(osmSurface: value) == expected)
    }

    @Test("a way that changes surface partway is read from its leading value")
    func takesTheLeadingValueOfAMultiValueSurface() {
        #expect(TrailSurface(osmSurface: "gravel;dirt") == .gravel)
        #expect(TrailSurface(osmSurface: "asphalt;gravel;wood") == .paved)
    }

    @Test("casing and stray whitespace don't change the category")
    func normalizesBeforeMatching() {
        #expect(TrailSurface(osmSurface: "  Asphalt ") == .paved)
        #expect(TrailSurface(osmSurface: "FINE_GRAVEL") == .gravel)
    }

    @Test("tagging nobody has taught this build about is unknown, not wrong")
    func unrecognizedTaggingIsUnknown() {
        #expect(TrailSurface(osmSurface: "moon_dust") == .unknown)
        #expect(TrailSurface(osmSurface: nil) == .unknown)
        #expect(TrailSurface(osmSurface: "") == .unknown)
    }

    @Test("tracktype answers only for a way that has no surface of its own")
    func fallsBackToTracktype() {
        #expect(TrailSurface(osmSurface: nil, tracktype: "grade1") == .paved)
        #expect(TrailSurface(osmSurface: nil, tracktype: "grade2") == .gravel)
        #expect(TrailSurface(osmSurface: nil, tracktype: "grade5") == .ground)
        // A surface tag is a material and beats a firmness grade.
        #expect(
            TrailSurface(osmSurface: "ground", tracktype: "grade1") == .ground
        )
        // An unrecognised surface shouldn't block a usable tracktype.
        #expect(
            TrailSurface(osmSurface: "moon_dust", tracktype: "grade1") == .paved
        )
        #expect(TrailSurface(osmSurface: nil, tracktype: "grade9") == .unknown)
    }

    @Test("only the four surveyed categories claim to describe a surface")
    func surveyedCategories() {
        #expect(TrailSurface.allCases.filter(\.isSurveyed).count == 4)
        #expect(!TrailSurface.unknown.isSurveyed)
        #expect(!TrailSurface.unmapped.isSurveyed)
    }
}

// MARK: - Aggregation

@Suite("Trail surface breakdown")
struct TrailSurfaceBreakdownTests {
    @Test("shares are surveyed-first, then longest-first")
    func ordersShares() throws {
        let breakdown = TrailSurfaceBreakdown(
            metersByCategory: [
                .unmapped: 500,
                .paved: 100,
                .ground: 300,
                .gravel: 100,
            ]
        )

        #expect(
            breakdown.shares.map(\.category) == [.ground, .paved, .gravel, .unmapped]
        )
        // `paved` precedes `gravel` in `TrailSurface.displayOrdering`, which
        // is the tie-break, so a rebuild of the same data can't reshuffle the
        // legend.
        let dominant = try #require(breakdown.dominant)
        #expect(dominant.category == .ground)
    }

    @Test("fractions are of the measured total and sum to one")
    func fractionsSumToOne() {
        let breakdown = TrailSurfaceBreakdown(
            metersByCategory: [.paved: 250, .ground: 750]
        )

        #expect(breakdown.totalMeters == 1000)
        #expect(breakdown.meters(for: .paved) == 250)
        #expect(breakdown.meters(for: .rock) == 0)
        let total = breakdown.shares.reduce(0) { $0 + $1.fraction }
        #expect(abs(total - 1) < 1e-9)
    }

    @Test("the surveyed fraction excludes both ways of not knowing")
    func surveyedFractionCountsOnlyTaggedSurfaces() {
        let breakdown = TrailSurfaceBreakdown(
            metersByCategory: [
                .gravel: 600,
                .unknown: 200,
                .unmapped: 200,
            ]
        )

        #expect(abs(breakdown.surveyedFraction - 0.6) < 1e-9)
    }

    @Test("zero-length categories are dropped, and nothing at all is empty")
    func dropsEmptyShares() {
        let breakdown = TrailSurfaceBreakdown(
            metersByCategory: [.paved: 100, .rock: 0]
        )

        #expect(breakdown.shares.count == 1)
        #expect(TrailSurfaceBreakdown(metersByCategory: [:]).isEmpty)
        #expect(TrailSurfaceBreakdown(metersByCategory: [.paved: 0]).isEmpty)
    }
}

// MARK: - Analysis

@Suite("Trail surface analysis")
struct TrailSurfaceAnalyzerTests {
    private static let baseLongitude = 12.8600

    /// Two ways meeting end to end, the southern half gravel and the northern
    /// half asphalt.
    private func splitGraph() -> TrailGraph {
        makeGraph(
            nodes: [
                (1, 47.6300, Self.baseLongitude),
                (2, 47.6310, Self.baseLongitude),
                (3, 47.6320, Self.baseLongitude),
            ],
            ways: [
                WayFixture(id: 10, nodeIDs: [1, 2], surface: "gravel"),
                WayFixture(id: 11, nodeIDs: [2, 3], surface: "asphalt"),
            ]
        )
    }

    @Test("a route over two differently surfaced ways splits between them")
    func splitsBetweenTwoWays() async throws {
        // Walked end to end with the junction on a route point, so the two
        // ways contribute exactly the same distance. `breakdown` is
        // `@concurrent` and asserts it is off the main thread, so awaiting it
        // here is also the check that it stays there.
        let walked = route(
            (0...4).map { step in
                (47.6300 + Double(step) * 0.0005, Self.baseLongitude)
            }
        )

        let breakdown = try await TrailBreakdownAnalyzer.breakdown(
            of: TrailSurface.self,
            route: walked,
            graph: splitGraph()
        )

        #expect(
            breakdown.shares
                .map(\.category)
                .sorted { $0.displayOrder < $1.displayOrder } == [.paved, .gravel]
        )
        #expect(
            abs(breakdown.meters(for: .gravel) - breakdown.meters(for: .paved)) < 1
        )
        for share in breakdown.shares {
            #expect(abs(share.fraction - 0.5) < 0.02)
        }
        #expect(abs(breakdown.surveyedFraction - 1) < 1e-9)
    }

    @Test("distance with no way beneath it is unmapped, not snapped")
    func reportsUnmappedDistance() async throws {
        // Half a kilometre east of the graph — far outside the tolerance, and
        // far enough that no projection could be mistaken for a match.
        let east = longitude(Self.baseLongitude, eastMeters: 500)
        let walked = route([
            (47.6300, east),
            (47.6310, east),
            (47.6320, east),
        ])

        let breakdown = try await TrailBreakdownAnalyzer.breakdown(
            of: TrailSurface.self,
            route: walked,
            graph: splitGraph()
        )

        #expect(breakdown.shares.map(\.category) == [.unmapped])
        #expect(breakdown.surveyedFraction == 0)
    }

    @Test("an untagged way still reports what its tracktype implies")
    func usesTracktypeForAnUntaggedWay() async throws {
        let graph = makeGraph(
            nodes: [
                (1, 47.6300, Self.baseLongitude),
                (2, 47.6320, Self.baseLongitude),
            ],
            ways: [
                WayFixture(id: 10, nodeIDs: [1, 2], surface: nil, tracktype: "grade2"),
            ]
        )
        let walked = route([
            (47.6302, Self.baseLongitude),
            (47.6318, Self.baseLongitude),
        ])

        let breakdown = try await TrailBreakdownAnalyzer.breakdown(
            of: TrailSurface.self,
            route: walked,
            graph: graph
        )

        #expect(breakdown.shares.map(\.category) == [.gravel])
    }

    @Test("a mapped way with no surface tagging reports as unknown")
    func reportsUntaggedWayAsUnknown() async throws {
        let graph = makeGraph(
            nodes: [
                (1, 47.6300, Self.baseLongitude),
                (2, 47.6320, Self.baseLongitude),
            ],
            ways: [WayFixture(id: 10, nodeIDs: [1, 2])]
        )
        let walked = route([
            (47.6302, Self.baseLongitude),
            (47.6318, Self.baseLongitude),
        ])

        let breakdown = try await TrailBreakdownAnalyzer.breakdown(
            of: TrailSurface.self,
            route: walked,
            graph: graph
        )

        #expect(breakdown.shares.map(\.category) == [.unknown])
        #expect(breakdown.surveyedFraction == 0)
    }

    @Test("a walk stays on its own way when a parallel one is barely closer")
    func prefersTheWayAlreadyBeingWalked() async throws {
        // A gravel path with an asphalt service road twelve metres to the
        // east. The walk starts unambiguously on the path, then runs seven
        // metres east of it — five metres from the road. Judged fix by fix the
        // road wins that stretch outright; judged as a walk, nobody stepped
        // across a five-metre gap and back.
        let roadLongitude = longitude(Self.baseLongitude, eastMeters: 12)
        let driftLongitude = longitude(Self.baseLongitude, eastMeters: 7)
        let graph = makeGraph(
            nodes: [
                (1, 47.6300, Self.baseLongitude),
                (2, 47.6325, Self.baseLongitude),
                (3, 47.6300, roadLongitude),
                (4, 47.6325, roadLongitude),
            ],
            ways: [
                WayFixture(id: 10, nodeIDs: [1, 2], surface: "gravel"),
                WayFixture(id: 11, nodeIDs: [3, 4], surface: "asphalt"),
            ]
        )
        let walked = route([
            (47.6300, Self.baseLongitude),
            (47.6305, Self.baseLongitude),
            (47.6310, driftLongitude),
            (47.6320, driftLongitude),
        ])

        let breakdown = try await TrailBreakdownAnalyzer.breakdown(
            of: TrailSurface.self,
            route: walked,
            graph: graph
        )

        #expect(breakdown.shares.map(\.category) == [.gravel])
    }

    @Test("nothing to measure against produces nothing")
    func emptyInputs() async throws {
        let walked = route([
            (47.6300, Self.baseLongitude),
            (47.6320, Self.baseLongitude),
        ])

        let withoutGraph = try await TrailBreakdownAnalyzer.breakdown(
            of: TrailSurface.self,
            route: walked,
            graph: .empty
        )
        let withoutRoute = try await TrailBreakdownAnalyzer.breakdown(
            of: TrailSurface.self,
            route: [walked[0]],
            graph: splitGraph()
        )

        #expect(withoutGraph.isEmpty)
        #expect(withoutRoute.isEmpty)
    }

    @Test("a sparse import is sampled along its legs, not just at its fixes")
    func samplesLongSegments() async throws {
        // Two fixes a kilometre apart, with only the first 20% of the leg on a
        // mapped way. Attributing whole legs to the way nearest an endpoint
        // would report all or none of it; sampling reports the fifth that is.
        let endLatitude = 47.6300 + 1000 / metersPerDegreeLatitude
        let mappedEnd = 47.6300 + 200 / metersPerDegreeLatitude
        let graph = makeGraph(
            nodes: [
                (1, 47.6300, Self.baseLongitude),
                (2, mappedEnd, Self.baseLongitude),
            ],
            ways: [WayFixture(id: 10, nodeIDs: [1, 2], surface: "asphalt")]
        )
        let walked = route([
            (47.6300, Self.baseLongitude),
            (endLatitude, Self.baseLongitude),
        ])

        let breakdown = try await TrailBreakdownAnalyzer.breakdown(
            of: TrailSurface.self,
            route: walked,
            graph: graph
        )

        let paved = try #require(
            breakdown.shares.first { $0.category == .paved }
        )
        #expect(abs(paved.fraction - 0.2) < 0.05)
        #expect(abs(breakdown.totalMeters - 1000) < 5)
    }
}

// MARK: - Persistence

@Suite("Trail surface persistence")
struct TrailSurfacePersistenceTests {
    @Test("a breakdown round-trips through the hike that stores it")
    func roundTripsThroughAHike() throws {
        let hike = Hike(title: "Thumsee", distanceMeters: 1000)
        #expect(hike.surfaceBreakdown == nil)

        hike.surfaceBreakdown = TrailSurfaceBreakdown(
            metersByCategory: [.gravel: 700, .paved: 200, .unmapped: 100]
        )

        #expect(hike.surfaceMetersByCategory["gravel"] == 700)
        let restored = try #require(hike.surfaceBreakdown)
        #expect(restored.shares.map(\.category) == [.gravel, .paved, .unmapped])
        #expect(restored.totalMeters == 1000)
    }

    @Test("clearing the breakdown clears the stored categories")
    func clearingRemovesStoredCategories() {
        let hike = Hike(title: "Thumsee", distanceMeters: 1000)
        hike.surfaceBreakdown = TrailSurfaceBreakdown(
            metersByCategory: [.gravel: 700]
        )

        hike.surfaceBreakdown = nil

        #expect(hike.surfaceMetersByCategory.isEmpty)
    }

    @Test("a category this build doesn't know is dropped, not refused")
    func ignoresUnrecognizedStoredCategories() throws {
        let hike = Hike(title: "Thumsee", distanceMeters: 1000)
        hike.surfaceMetersByCategory = ["gravel": 300, "lunar_regolith": 100]

        let restored = try #require(hike.surfaceBreakdown)
        #expect(restored.shares.map(\.category) == [.gravel])
        // Renormalised over what survived, so the percentages still add up.
        #expect(restored.totalMeters == 300)
    }

    @Test("a store with nothing recognisable reads as never analyzed")
    func unrecognizedOnlyReadsAsNil() {
        let hike = Hike(title: "Thumsee", distanceMeters: 1000)
        hike.surfaceMetersByCategory = ["lunar_regolith": 100]

        #expect(hike.surfaceBreakdown == nil)
    }
}
