//
//  CuratedElevationFillTests.swift
//  OpenHikesTests
//
//  What a curated route's heights are written as: one on every point of the
//  line, so the map can colour the route by steepness from end to end.
//
//  Stadia is asked about two hundred points at most. Written on those points
//  alone, the heights drew the same chart, but every point between two of them
//  broke the steepness colours: a route a little over the ceiling was
//  coloured in scraps two or three points long, none fading into the next,
//  and a route of twice the ceiling was not coloured at all.
//  ``CuratedElevationTests`` covers what is asked and what a refusal costs;
//  this covers what the answer becomes.
//

import CoreGraphics
import CoreLocation
import MapKit
@testable import OpenHikes
import OpenHikesData
import RealModule
import Testing

@Suite("Curated elevation fill")
struct CuratedElevationFillTests {
    private enum Terrain {
        /// Where every route here starts.
        static let south = 47.88
        static let longitude = 13.85
        /// About eleven metres between points, as an OpenStreetMap path's
        /// nodes often are.
        static let spacing = 0.0001
        static let baseMeters = 600.0
        /// Steep enough to be a colour of its own beside level ground.
        static let climbGrade = 0.25
    }

    /// A straight line north, `count` points long, with no heights — the
    /// way OpenStreetMap hands a hiking relation over.
    private static func route(_ count: Int) -> [RouteCoordinate] {
        (0..<count).map { index in
            RouteCoordinate(
                latitude: Terrain.south + Double(index) * Terrain.spacing,
                longitude: Terrain.longitude
            )
        }
    }

    /// Answers the way Stadia does — one height per point asked about, in
    /// order — from a terrain a case can write down.
    nonisolated private struct TerrainSource: CuratedElevationSourcing {
        let height: @Sendable (CLLocationCoordinate2D) -> Double

        @concurrent
        func heights(at coordinates: [CLLocationCoordinate2D]) async -> [Double] {
            coordinates.map(height)
        }
    }

    /// Every point carries a height, not only the ones asked about: a point
    /// between two readings takes the height its distance along the line
    /// puts it at, which on ground that climbs evenly is the ground's own.
    @Test("a route over the ceiling gets a height on every point", arguments: [279, 560])
    func everyPointGetsAHeight(count: Int) async throws {
        let route = Self.route(count)
        let south = Terrain.south, spacing = Terrain.spacing, base = Terrain.baseMeters
        // A metre for every point north of the start.
        let source = TerrainSource { base + ($0.latitude - south) / spacing }
        #expect(
            CuratedElevationRequest.sampleIndexes(count: count).count < count,
            "precondition: the route is sampled rather than asked about whole"
        )

        let filled = await source.filled(route)

        #expect(filled.map(\.latitude) == route.map(\.latitude), "the line itself is untouched")
        for (index, point) in filled.enumerated() {
            let height = try #require(point.elevation, "point \(index) has no height")
            #expect(height.isApproximatelyEqual(to: base + Double(index), absoluteTolerance: 0.01))
        }
    }

    /// What the heights are for on the map: coloured by steepness, the line
    /// runs from end to end without a gap, so wherever one colour meets the
    /// next there is a point the two share and a fade drawn across it —
    /// ``RouteShadeBlend`` blends nowhere else.
    ///
    /// 279 points is the size of the Wanderweg W10 that showed the gaps:
    /// written on the sampled points alone, it measured as scraps that never
    /// touched, and 560 points measured as no colour at all.
    @Test("a filled route is coloured end to end, and every change of colour fades", arguments: [279, 560])
    func filledRouteIsColoredEndToEnd(count: Int) async throws {
        let route = Self.route(count)
        let start = route[0].clCoordinate
        let halfway = RouteGeometry.distanceMeters(from: start, to: route[count / 2].clCoordinate)
        let base = Terrain.baseMeters, grade = Terrain.climbGrade
        // Level ground to halfway, then a climb: two colours and one change.
        let source = TerrainSource { point in
            base + max(0, RouteGeometry.distanceMeters(from: start, to: point) - halfway) * grade
        }

        let runs = RouteSteepness.runs(route: await source.filled(route))

        #expect(Set(runs.map(\.shade)).count > 1, "precondition: level ground and a climb are two colours")
        let first = try #require(runs.first?.coordinates.first)
        let last = try #require(runs.last?.coordinates.last)
        #expect(first.latitude == route[0].latitude, "coloured from the first point")
        #expect(last.latitude == route[count - 1].latitude, "to the last")
        let gaps = zip(runs, runs.dropFirst()).count { before, after in
            before.coordinates.last?.latitude != after.coordinates.first?.latitude
        }
        #expect(gaps == 0, "where one colour meets the next, the two share a point")
        // Colours of their own, one per step; which ones is the map's
        // business, and only whether two stretches differ matters here.
        let shades = runs.map { run in
            DirectionalPolylineRenderer.Shade(
                polyline: MKPolyline(coordinates: run.coordinates, count: run.coordinates.count),
                color: CGColor(red: Double(run.shade.rawValue) / 5, green: 0, blue: 0, alpha: 1)
            )
        }
        #expect(RouteShadeBlend.pieces(between: shades).allSatisfy { $0 != nil }, "every change of colour fades")
    }
}
