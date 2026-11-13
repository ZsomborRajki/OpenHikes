//
//  TrailCellGridTests.swift
//  OpenHikesTests
//
//  Which square a route is filed under, what its record is called, and which
//  squares a search reads.
//
//  Two of these are contracts with something outside the build. A record
//  name is what the upload saved a square under and what every installed copy
//  of the app asks for, so the names are spelled out here rather than
//  computed. And the reach is a promise the tool keeps on the app's behalf: a
//  route is filed once, under the middle of its box, so a search that looked
//  less far than a route can reach would miss a trail that crosses the map —
//  silently, in a list that looks complete.
//
//  The grid's arithmetic is its own, because the tool compiles the file and
//  links none of the app's packages. The last cases hold it to the app's.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import RealModule
import Testing

@Suite("Trail cell grid")
struct TrailCellGridTests {
    private static func names(reaching box: TrailCellBounds) -> [String] {
        TrailCellGrid.cells(reaching: box).map(TrailCellGrid.recordName(for:))
    }

    private static func name(at latitude: Double, _ longitude: Double) -> String {
        TrailCellFixture.name(at: latitude, longitude)
    }

    // MARK: - A point's square, and its name

    @Test("a point is filed under the quarter-degree square that holds it")
    func aPointsSquare() {
        #expect(Self.name(at: 47.715, 18.94) == "trails1_550_795")
        #expect(Self.name(at: -33.9, 151.2) == "trails1_224_1324")
        #expect(Self.name(at: 0, 0) == "trails1_360_720")
    }

    @Test("the poles and the date line belong to squares that exist")
    func theEdgesOfTheWorld() {
        #expect(Self.name(at: 90, 0) == "trails1_719_720", "the pole itself is in the last row, not one past it")
        #expect(Self.name(at: -90, 0) == "trails1_0_720")
        #expect(Self.name(at: 0, -180) == "trails1_360_0")
        #expect(Self.name(at: 0, 180) == "trails1_360_0", "180° east is 180° west")
        #expect(Self.name(at: 0, 179.99) == "trails1_360_1439")
        #expect(Self.name(at: 0, 540) == "trails1_360_0", "a longitude that has wrapped is still a place")
    }

    @Test("a record name reads back as its square, and nothing else does")
    func namesReadBack() {
        let corner = TrailCell(row: 719, column: 1439)

        #expect(TrailCellGrid.cell(named: TrailCellGrid.recordName(for: corner)) == corner)
        #expect(TrailCellGrid.cell(named: "trails1_0_0") == TrailCell(row: 0, column: 0))
        for stranger in [
            "trails2_550_795", "trails1_720_0", "trails1_0_1440", "trails1_550",
            "trails1_manifest", "trails1_-1_5", "notice-550_795", "",
        ] {
            #expect(TrailCellGrid.cell(named: stranger) == nil, "\(stranger) is not a square")
        }
    }

    @Test("the manifest has one name, in the squares' own generation")
    func theManifestsName() {
        #expect(TrailCellGrid.manifestRecordName == "trails1_manifest")
    }

    // MARK: - The squares a search reads

    /// The search this was measured on: the Pilis hills above a half-height
    /// sheet, six squares and 382 KB of them.
    @Test("a search of a valley reads the squares within reach of it, and no more")
    func aValleysSquares() {
        let pilis = TrailCellBounds(south: 47.66, west: 18.86, north: 47.77, east: 19.02)

        #expect(Self.names(reaching: pilis) == [
            "trails1_550_794", "trails1_550_795", "trails1_550_796",
            "trails1_551_794", "trails1_551_795", "trails1_551_796",
        ])
    }

    @Test("a search beside the date line reads squares on both sides of it, each once")
    func acrossTheDateLine() {
        let fiji = TrailCellBounds(south: -17.0, west: 179.9, north: -16.9, east: 180)

        let names = Self.names(reaching: fiji)

        #expect(names.contains("trails1_292_1439"))
        #expect(names.contains("trails1_292_0"), "the reach carries past 180° and comes back in at −180°")
        #expect(Set(names).count == names.count)
    }

    @Test("a box all the way round the world reads every column once")
    func allTheWayRound() {
        let band = TrailCellBounds(south: 0.01, west: -180, north: 0.02, east: 180)

        let cells = TrailCellGrid.cells(reaching: band)

        #expect(Set(cells).count == cells.count)
        #expect(Set(cells.map(\.column)).count == TrailCellGrid.columnCount)
    }

    @Test("something that is not a box reads nothing")
    func notABox() {
        #expect(TrailCellGrid.cells(reaching: TrailCellBounds(south: 2, west: 0, north: 1, east: 1)).isEmpty)
        #expect(TrailCellGrid.cells(reaching: TrailCellBounds(south: 0, west: 2, north: 1, east: 1)).isEmpty)
        #expect(TrailCellGrid.cells(reaching: TrailCellBounds(south: .nan, west: 0, north: 1, east: 1)).isEmpty)
    }

    // MARK: - The reach

    /// The promise the whole arrangement rests on. A route as wide as one may
    /// be, in the three shapes that stretch it furthest — square, a line
    /// north and a line east — filed under the middle of its box: a search
    /// about any corner of that box has to read the square it is in.
    @Test(
        "a search that touches any corner of a route reads the square the route is filed under",
        arguments: [-65.0, -47.0, 0.0, 47.0, 65.0]
    )
    func theReachCoversAFiledRoute(latitude: Double) {
        let span = TrailCellGrid.maximumRouteSpanMeters
        let metersPerDegree = RouteGeometry.metersPerDegreeLatitude
        let eastScale = cos(latitude * .pi / 180)
        let shapes: [(height: Double, width: Double)] = [
            (height: span / 2.0.squareRoot(), width: span / 2.0.squareRoot()),
            (height: span, width: 0),
            (height: 0, width: span),
        ]
        for shape in shapes {
            // Just inside the limit, so it is a route the tool would file.
            let height = shape.height * 0.99 / metersPerDegree
            let width = shape.width * 0.99 / (metersPerDegree * eastScale)
            // Straddling a square's corner, where a route reaches into the
            // most squares it is not filed in.
            let route = TrailCellBounds(
                south: latitude - height / 2,
                west: 13 - width / 2,
                north: latitude + height / 2,
                east: 13 + width / 2
            )
            #expect(route.spanMeters <= span)
            let center = route.center
            let filed = TrailCellGrid.cell(containingLatitude: center.latitude, longitude: center.longitude)
            let corners = [
                (route.south, route.west),
                (route.south, route.east),
                (route.north, route.west),
                (route.north, route.east),
            ]
            for corner in corners {
                let search = TrailCellBounds(south: corner.0, west: corner.1, north: corner.0, east: corner.1)
                #expect(
                    TrailCellGrid.cells(reaching: search).contains(filed),
                    "a route \(shape) at \(latitude)° is out of reach from its own corner"
                )
            }
        }
    }

    @Test("the reach is at least half of the widest route the app offers")
    func theReachIsTheAppsRule() {
        #expect(TrailCellGrid.reachMeters >= CuratedTrailQuery.maximumSpanMeters / 2)
        #expect(TrailCellGrid.maximumMemberCount == CuratedTrailQuery.maximumMemberCount)
    }

    // MARK: - The same measure as the app's

    nonisolated private static let boxes: [CuratedTrailQuery.BoundingBox] = [
        CuratedTrailQuery.BoundingBox(south: 47.62, west: 12.97, north: 47.628, east: 12.98),
        CuratedTrailQuery.BoundingBox(south: 45, west: 10, north: 49, east: 15),
        CuratedTrailQuery.BoundingBox(south: -17.01, west: -179.99, north: -16.99, east: 179.99),
        CuratedTrailQuery.BoundingBox(south: 69.9, west: 25.1, north: 70.05, east: 25.6),
        CuratedTrailQuery.BoundingBox(south: 0, west: 0, north: 0, east: 0),
    ]

    private static func bounds(_ box: CuratedTrailQuery.BoundingBox) -> TrailCellBounds {
        TrailCellBounds(south: box.south, west: box.west, north: box.north, east: box.east)
    }

    /// What the tool files by has to be what the app would have kept: one
    /// that measured a hair differently would leave out a route the app
    /// offers from Overpass, or file one the app then throws away.
    @Test("a box measures the same across as the app measures it", arguments: boxes)
    func theSpanIsTheApps(box: CuratedTrailQuery.BoundingBox) {
        let span = Self.bounds(box).spanMeters

        #expect(span.isApproximatelyEqual(to: CuratedTrailQuery.spanMeters(of: box), absoluteTolerance: 1e-6))
    }

    @Test("a box's middle is where the app pins it, the short way round the date line", arguments: boxes)
    func theCenterIsTheApps(box: CuratedTrailQuery.BoundingBox) {
        let center = Self.bounds(box).center
        let pin = CuratedTrailQuery.center(of: box)

        #expect(center.latitude.isApproximatelyEqual(to: pin.latitude, absoluteTolerance: 1e-12))
        #expect(
            TrailCellGrid.cell(containingLatitude: center.latitude, longitude: center.longitude)
                == TrailCellGrid.cell(containingLatitude: pin.latitude, longitude: pin.longitude)
        )
    }
}
