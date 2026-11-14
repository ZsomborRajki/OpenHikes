//
//  HikingRouteSquaresTests.swift
//  OpenHikesTests
//
//  Where the hiking-routes layer's squares come from: one request for what
//  is missing, the disk before the network, nothing drawn from squares that
//  are not the whole world, and no request repeated while a failure is fresh.
//
//  The database is a stub and every directory the case's own — see
//  *Deliberate test seams* in the repository instructions.
//

import CoreLocation
import Foundation
import MapKit
@testable import OpenHikes
import RealModule
import Testing

@Suite("Hiking route squares")
struct HikingRouteSquaresTests {
    private static let square = RouteSquareGrid.square(at: .detail, latitude: 47.55, longitude: 12.98)
    private static let neighbor = RouteSquare(level: .detail, row: square.row, column: square.column + 1)

    /// One national route across the square, as its file.
    private static let file = RouteSquareFile(
        routes: [RouteSquareFile.Route(id: 18_722, tags: ["network": "nwn"])],
        lines: [
            RouteSquareFile.Line(
                network: .national,
                routes: [0],
                points: [
                    RouteSquareFile.Point(latitude: 47_560_000, longitude: 12_960_000),
                    RouteSquareFile.Point(latitude: 47_590_000, longitude: 12_990_000),
                ]
            ),
        ],
        coordinateScale: 1_000_000
    )

    private static func name(_ square: RouteSquare) -> String {
        RouteSquareGrid.recordName(for: square)
    }

    private static func scratchDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("route-squares-\(UUID().uuidString)")
    }

    /// Asks for `squares` and waits until they have been brought in, or
    /// records an issue when the library says it will not call back.
    private static func bringIn(_ squares: [RouteSquare], from library: HikingRouteSquares) async {
        await withCheckedContinuation { continuation in
            let willCall = library.request(squares) { continuation.resume() }
            if !willCall {
                Issue.record("the library did not take the request")
                continuation.resume()
            }
        }
    }

    @Test("the squares a tile needs are fetched in one request and then drawn from memory")
    func fetchesOnceThenHolds() async {
        let database = StubTrailCellDatabase(cells: [Self.name(Self.square): .found(Self.file.encoded())])
        let library = HikingRouteSquares(database: database, directory: nil)
        #expect(!library.holdsAll([Self.square, Self.neighbor]))
        #expect(library.drawable([Self.square]).isEmpty)

        await Self.bringIn([Self.square, Self.neighbor], from: library)

        #expect(database.requests.count == 1)
        #expect(Set(database.requests.first ?? []) == [Self.name(Self.square), Self.name(Self.neighbor)])
        #expect(library.holdsAll([Self.square, Self.neighbor]))
        let drawn = library.drawable([Self.square, Self.neighbor])
        #expect(drawn.map(\.lines.count) == [1, 0], "a square with no record is a square with no routes")
        #expect(drawn.first?.lines.first?.network == .national)
        let askedAgain = library.request([Self.square]) { /* never called: held already */ }
        #expect(!askedAgain, "a square in memory is not asked for again")
        #expect(database.requests.count == 1)
    }

    @Test("a tile is drawn whole or not at all")
    func drawableNeedsEverySquare() async {
        let database = StubTrailCellDatabase(cells: [Self.name(Self.square): .found(Self.file.encoded())])
        let library = HikingRouteSquares(database: database, directory: nil)
        await Self.bringIn([Self.square], from: library)

        #expect(library.drawable([Self.square]).count == 1)
        #expect(library.drawable([Self.square, Self.neighbor]).isEmpty)
    }

    @Test("a square fetched once is read from the disk by the next launch")
    func diskBeforeNetwork() async {
        let directory = Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = StubTrailCellDatabase(cells: [Self.name(Self.square): .found(Self.file.encoded())])
        await Self.bringIn([Self.square], from: HikingRouteSquares(database: first, directory: directory))

        let second = StubTrailCellDatabase()
        let relaunched = HikingRouteSquares(database: second, directory: directory)
        await Self.bringIn([Self.square], from: relaunched)

        #expect(second.requests.isEmpty)
        #expect(relaunched.drawable([Self.square]).first?.lines.count == 1)
    }

    /// Only a set that is the whole world says what a missing record means.
    @Test("squares that are not the whole world draw nothing, and are not asked about again until later")
    func partialSetDrawsNothing() async {
        let clock = TestClock()
        let database = StubTrailCellDatabase(
            manifest: .partial,
            cells: [Self.name(Self.square): .found(Self.file.encoded())]
        )
        let library = HikingRouteSquares(database: database, directory: nil, clock: clock.read)
        await Self.bringIn([Self.square], from: library)

        #expect(library.drawable([Self.square]).isEmpty)
        #expect(!library.request([Self.square]) { /* never called: the request is refused */ })
        #expect(database.requests.count == 1)

        clock.advance(by: HikingRouteSquares.unavailableRetry + 1)
        await Self.bringIn([Self.square], from: library)
        #expect(database.requests.count == 2)
    }

    @Test("a request that fails is not repeated until the failure is a minute old")
    func failureBacksOff() async {
        let clock = TestClock()
        let database = StubTrailCellDatabase(cells: [Self.name(Self.square): .found(Self.file.encoded())])
        database.fail(with: URLError(.notConnectedToInternet))
        let library = HikingRouteSquares(database: database, directory: nil, clock: clock.read)
        await Self.bringIn([Self.square], from: library)

        #expect(library.drawable([Self.square]).isEmpty)
        #expect(!library.request([Self.square]) { /* never called: the request is refused */ })
        #expect(database.requests.count == 1)

        clock.advance(by: HikingRouteSquares.failedRetry + 1)
        await Self.bringIn([Self.square], from: library)
        #expect(database.requests.count == 2)
    }

    @Test("bytes that are not a square are not drawn")
    func corruptSquareIsNotDrawn() async {
        let database = StubTrailCellDatabase(cells: [Self.name(Self.square): .found(Data("not a square".utf8))])
        let library = HikingRouteSquares(database: database, directory: nil)
        await Self.bringIn([Self.square], from: library)

        #expect(library.drawable([Self.square]).isEmpty)
    }

    @Test("a square's lines are drawn in map points, inside a box that holds them")
    func drawnSquareGeometry() throws {
        let drawn = DrawnRouteSquare(Self.file)
        let line = try #require(drawn.lines.first)
        #expect(drawn.pointCount == 2)
        #expect(line.points.count == 2)
        for point in line.points {
            #expect(line.bounds.contains(point) || point.x == line.bounds.maxX || point.y == line.bounds.maxY)
        }
        let start = line.points[0].coordinate
        #expect(start.latitude.isApproximatelyEqual(to: 47.56, absoluteTolerance: 1e-9))
        #expect(start.longitude.isApproximatelyEqual(to: 12.96, absoluteTolerance: 1e-9))
    }
}
