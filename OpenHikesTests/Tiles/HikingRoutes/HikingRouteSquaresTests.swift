//
//  HikingRouteSquaresTests.swift
//  OpenHikesTests
//
//  Where the hiking-routes layer's squares come from: one request for what
//  is missing, the disk before the network and never waiting on it, nothing
//  drawn from squares that are not the whole world, no request where the
//  network may not be asked or while a failure is fresh, and a redraw of the
//  tiles it refused when one lapses.
//
//  The database is a stub and every directory the case's own — see
//  *Deliberate test seams* in the repository instructions.
//

import CoreLocation
import Foundation
import MapKit
@testable import OpenHikes
import RealModule
import Synchronization
import Testing

/// A database whose answer waits until the case lets it go, the way a
/// request over one bar of signal does.
nonisolated private final class HeldBackDatabase: TrailCellFetching, Sendable {
    private struct Gate {
        var isOpen = false
        var waiting: [CheckedContinuation<Void, Never>] = []
    }

    private let answers: StubTrailCellDatabase
    private let gate = Mutex(Gate())

    init(answers: StubTrailCellDatabase) {
        self.answers = answers
    }

    /// Whether a request is out and waiting.
    var isWaiting: Bool { gate.withLock { !$0.waiting.isEmpty } }

    func release() {
        let waiting = gate.withLock { gate in
            gate.isOpen = true
            defer { gate.waiting = [] }
            return gate.waiting
        }
        for continuation in waiting {
            continuation.resume()
        }
    }

    @concurrent
    func fetch(cellsNamed names: [String]) async throws -> TrailCellFetch {
        await withCheckedContinuation { continuation in
            let isOpen = gate.withLock { gate in
                if !gate.isOpen { gate.waiting.append(continuation) }
                return gate.isOpen
            }
            if isOpen { continuation.resume() }
        }
        return try await answers.fetch(cellsNamed: names)
    }
}

/// A back-off that lasts until the case lets it go.
nonisolated final class HeldBackPause: Sendable {
    private struct Gate {
        var waited: [TimeInterval] = []
        var waiting: [CheckedContinuation<Void, Never>] = []
        var isOpen = false
    }

    private let gate = Mutex(Gate())

    var isWaiting: Bool { gate.withLock { !$0.waiting.isEmpty } }
    var waited: [TimeInterval] { gate.withLock { $0.waited } }

    func release() {
        let waiting = gate.withLock { gate in
            gate.isOpen = true
            defer { gate.waiting = [] }
            return gate.waiting
        }
        for continuation in waiting {
            continuation.resume()
        }
    }

    func wait(_ delay: TimeInterval) async {
        await withCheckedContinuation { continuation in
            let isOpen = gate.withLock { gate in
                gate.waited.append(delay)
                if !gate.isOpen { gate.waiting.append(continuation) }
                return gate.isOpen
            }
            if isOpen { continuation.resume() }
        }
    }
}

@Suite("Hiking route squares")
struct HikingRouteSquaresTests {
    static let square = RouteSquareGrid.square(at: .detail, latitude: 47.55, longitude: 12.98)
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

    /// The tile every case asks on behalf of.
    static let tile = HikingRouteSquares.Tile(x: 0, y: 0, zoomScale: 1)

    /// A library over `database` that waits out no back-off: a case has no
    /// map to draw again, and nothing to gain from a minute's sleep.
    static func library(
        _ database: any TrailCellFetching,
        directory: URL? = nil,
        clock: @escaping @Sendable () -> Date = { Date() },
        allowsFetching: @escaping @Sendable () -> Bool = { true }
    ) -> HikingRouteSquares {
        HikingRouteSquares(
            database: database,
            directory: directory,
            clock: clock,
            allowsFetching: allowsFetching,
            pause: { _ in /* no waiting */ }
        )
    }

    static func name(_ square: RouteSquare) -> String {
        RouteSquareGrid.recordName(for: square)
    }

    static func scratchDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("route-squares-\(UUID().uuidString)")
    }

    /// Asks for `squares` and waits until the library calls back — once
    /// they are in when one request carries them all — or records an issue
    /// when it says it will not.
    static func bringIn(
        _ squares: [RouteSquare],
        from library: HikingRouteSquares,
        for tile: HikingRouteSquares.Tile = Self.tile
    ) async {
        await withCheckedContinuation { continuation in
            let willCall = library.request(squares, for: tile) { continuation.resume() }
            if !willCall {
                Issue.record("the library did not take the request")
                continuation.resume()
            }
        }
    }

    @Test("the squares a tile needs are fetched in one request and then drawn from memory")
    func fetchesOnceThenHolds() async {
        let database = StubTrailCellDatabase(cells: [Self.name(Self.square): .found(Self.file.encoded())])
        let library = Self.library(database)
        #expect(!library.holdsAll([Self.square, Self.neighbor]))
        #expect(library.drawable([Self.square]).isEmpty)

        await Self.bringIn([Self.square, Self.neighbor], from: library)

        #expect(database.requests.count == 1)
        #expect(Set(database.requests.first ?? []) == [Self.name(Self.square), Self.name(Self.neighbor)])
        #expect(library.holdsAll([Self.square, Self.neighbor]))
        let drawn = library.drawable([Self.square, Self.neighbor])
        #expect(drawn.map(\.lines.count) == [1, 0], "a square with no record is a square with no routes")
        #expect(drawn.first?.lines.first?.networks == .national)
        let askedAgain = library.request([Self.square], for: Self.tile) { /* never called: held already */ }
        #expect(!askedAgain, "a square in memory is not asked for again")
        #expect(database.requests.count == 1)
    }

    @Test("a tile is drawn whole or not at all")
    func drawableNeedsEverySquare() async {
        let database = StubTrailCellDatabase(cells: [Self.name(Self.square): .found(Self.file.encoded())])
        let library = Self.library(database)
        await Self.bringIn([Self.square], from: library)

        #expect(library.drawable([Self.square]).count == 1)
        #expect(library.drawable([Self.square, Self.neighbor]).isEmpty)
    }

    @Test("a square fetched once is read from the disk by the next launch")
    func diskBeforeNetwork() async {
        let directory = Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = StubTrailCellDatabase(cells: [Self.name(Self.square): .found(Self.file.encoded())])
        await Self.bringIn([Self.square], from: Self.library(first, directory: directory))

        let second = StubTrailCellDatabase()
        let relaunched = Self.library(second, directory: directory)
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
        let library = Self.library(database, clock: clock.read)
        await Self.bringIn([Self.square], from: library)

        #expect(library.drawable([Self.square]).isEmpty)
        #expect(library.request([Self.square], for: Self.tile) { /* kept until the wait is over */ })
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
        let library = Self.library(database, clock: clock.read)
        await Self.bringIn([Self.square], from: library)

        #expect(library.drawable([Self.square]).isEmpty)
        #expect(library.request([Self.square], for: Self.tile) { /* kept until the back-off lapses */ })
        #expect(database.requests.count == 1)

        clock.advance(by: HikingRouteSquares.failedRetry + 1)
        await Self.bringIn([Self.square], from: library)
        #expect(database.requests.count == 2)
    }

    /// The valley seen yesterday draws at once, beside one still on its way.
    @Test("a square on disk is drawn while the request for another is still out")
    func diskDoesNotWaitForTheNetwork() async {
        let directory = Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let answers = StubTrailCellDatabase(cells: [Self.name(Self.square): .found(Self.file.encoded())])
        await Self.bringIn([Self.square], from: Self.library(answers, directory: directory))

        let slow = HeldBackDatabase(answers: answers)
        let library = Self.library(slow, directory: directory)
        await Self.bringIn([Self.square, Self.neighbor], from: library)

        #expect(library.drawable([Self.square]).count == 1, "the kept square is in before the request answers")
        #expect(!library.holdsAll([Self.neighbor]))
        await settleDelegateHop(until: "the request for the other square is out") { slow.isWaiting }
        slow.release()
        await settleDelegateHop(until: "the other square is in") { library.holdsAll([Self.neighbor]) }
    }

    /// Low Data Mode, or no connection: the map's own tiles are not fetched
    /// then, and neither are the layer's squares.
    @Test("nothing is asked for where the network may not be, and what is on disk is still drawn")
    func refusedWhereTilesAre() async {
        let directory = Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = StubTrailCellDatabase(cells: [Self.name(Self.square): .found(Self.file.encoded())])
        await Self.bringIn([Self.square], from: Self.library(database, directory: directory))

        let library = Self.library(database, directory: directory, allowsFetching: { false })
        await Self.bringIn([Self.square], from: library)
        await Self.bringIn([Self.neighbor], from: library)

        #expect(database.requests.count == 1, "only the first launch's request was made")
        #expect(library.drawable([Self.square]).count == 1)
        #expect(!library.holdsAll([Self.neighbor]))
        #expect(library.request([Self.neighbor], for: Self.tile) { /* kept: refused a moment ago */ })
        #expect(database.requests.count == 1)
    }

    /// Nothing else would ask again on a map nobody is moving — and a tile
    /// already drawn whole has nothing to ask, so an afternoon offline does
    /// not stroke it again every minute.
    @Test("when a failure's back-off lapses, the tiles it refused are drawn again, and no other")
    func refusedTilesAreDrawnAgainWhenABackOffLapses() async {
        let clock = TestClock()
        let database = StubTrailCellDatabase(cells: [Self.name(Self.neighbor): .found(Self.file.encoded())])
        let backOff = HeldBackPause()
        let library = HikingRouteSquares(
            database: database,
            directory: nil,
            clock: clock.read,
            pause: { delay in await backOff.wait(delay) }
        )
        await Self.bringIn([Self.neighbor], from: library)
        database.fail(with: URLError(.notConnectedToInternet))
        await Self.bringIn([Self.square], from: library)
        await settleDelegateHop(until: "the back-off is being waited out") { backOff.isWaiting }

        let refused = Mutex(0)
        let whole = Mutex(0)
        #expect(library.request([Self.square], for: Self.tile) { refused.withLock { $0 += 1 } })
        let drawnTile = HikingRouteSquares.Tile(x: 1, y: 0, zoomScale: 1)
        #expect(!library.request([Self.neighbor], for: drawnTile) { whole.withLock { $0 += 1 } })
        #expect(refused.withLock { $0 } == 0, "the tile waits out the back-off")

        clock.advance(by: HikingRouteSquares.failedRetry)
        backOff.release()
        await settleDelegateHop(until: "the refused tile is told") { refused.withLock { $0 } == 1 }
        #expect(backOff.waited == [HikingRouteSquares.failedRetry])
        #expect(whole.withLock { $0 } == 0, "a tile that has its squares is left as it is")
        #expect(database.requests.count == 2, "nothing was asked for during the back-off")
    }

    /// Built, never asked: nothing here reaches CloudKit, which only a fetch
    /// would.
    @Test("the layer reads its own manifest, and waits longer for its squares than a search does")
    func liveDatabase() {
        let database = HikingRouteSquares.liveDatabase()
        #expect(database.manifestRecordName == RouteSquareGrid.manifestRecordName)
        #expect(database.requestTimeout > CloudKitTrailCellDatabase.searchRequestTimeout)
        #expect(database.resourceTimeout > CloudKitTrailCellDatabase.searchResourceTimeout)
    }

    /// MapKit asks about a waiting tile on every region change.
    @Test("a tile asked about twice while its square is on its way is told once")
    func oneRedrawATile() async {
        let slow = HeldBackDatabase(answers: StubTrailCellDatabase())
        let library = Self.library(slow)
        let told = Mutex(0)
        #expect(library.request([Self.square], for: Self.tile) { told.withLock { $0 += 1 } })
        await settleDelegateHop(until: "the request is out") { slow.isWaiting }
        #expect(library.request([Self.square], for: Self.tile) { told.withLock { $0 += 1 } })

        slow.release()
        await settleDelegateHop(until: "the square is in") { library.holdsAll([Self.square]) }
        await settleDelegateHop(until: "the tile is told") { told.withLock { $0 } > 0 }
        #expect(told.withLock { $0 } == 1)
    }

    @Test("past its limit the library lets go of the squares drawn longest ago, not the ones still in use")
    func leastRecentlyDrawnGoFirst() async {
        let library = Self.library(StubTrailCellDatabase())
        let row = (0..<HikingRouteSquares.maximumHeldSquares).map { column in
            RouteSquare(level: .detail, row: Self.square.row, column: column)
        }
        let first = row[0], second = row[1]
        await Self.bringIn([first], from: library)
        await Self.bringIn([second], from: library)
        let rest = Array(row.dropFirst(2))
        await Self.bringIn(rest, from: library)
        // More than one request carries them, and the tile is told after
        // each: waited for by what it brings in, not by the call back.
        await settleDelegateHop(until: "the rest are in") { library.holdsAll(rest) }
        #expect(library.holdsAll([first]), "drawn again, so no longer the one drawn longest ago")

        let beyond = RouteSquare(level: .detail, row: Self.square.row + 1, column: 0)
        await Self.bringIn([beyond], from: library)
        await settleDelegateHop(until: "the square past the limit is in") { library.holdsAll([beyond]) }
        #expect(library.holdsAll([first]))
        #expect(!library.holdsAll([second]), "the one drawn longest ago went")
    }

    @Test("bytes that are not a square are not drawn")
    func corruptSquareIsNotDrawn() async {
        let database = StubTrailCellDatabase(cells: [Self.name(Self.square): .found(Data("not a square".utf8))])
        let library = Self.library(database)
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
