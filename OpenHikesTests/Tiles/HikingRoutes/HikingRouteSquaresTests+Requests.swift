//
//  HikingRouteSquaresTests+Requests.swift
//  OpenHikesTests
//
//  How the hiking-routes layer's requests go out: one at a time however many
//  tiles ask, with what queued meanwhile sent together, the disk drawn while
//  one is out, and the network asked again before each, so a request is not
//  sent on an answer that has since changed — nor once a request has found
//  that the squares are not the whole world.
//
//  The database holds every request until the case lets it go, so nothing
//  here waits on a duration — see *Deliberate test seams* in the repository
//  instructions.
//

import Foundation
@testable import OpenHikes
import Synchronization
import Testing

/// A database that holds each request until the case lets that one go, and
/// counts how many were out at once.
nonisolated private final class HeldRequests: TrailCellFetching, Sendable {
    private struct State {
        var asked: [[String]] = []
        var held: [CheckedContinuation<Void, Never>] = []
        var isOpen = false
        var out = 0
        var mostAtOnce = 0
    }

    private let state = Mutex(State())
    private let manifest: TrailCellFetch.Manifest

    /// - Parameter manifest: What every answer says the squares cover.
    init(manifest: TrailCellFetch.Manifest = .complete) {
        self.manifest = manifest
    }

    /// The names each request asked about, in the order they went out.
    var asked: [[String]] { state.withLock { $0.asked } }
    /// How many requests are out and held.
    var held: Int { state.withLock { $0.held.count } }
    /// The most requests that were ever out together.
    var mostAtOnce: Int { state.withLock { $0.mostAtOnce } }

    /// Lets the request that has been out longest answer.
    func releaseOne() {
        let first = state.withLock { state in
            state.held.isEmpty ? nil : state.held.removeFirst()
        }
        first?.resume()
    }

    /// Lets every request answer, now and from now on.
    func open() {
        let waiting = state.withLock { state in
            state.isOpen = true
            defer { state.held = [] }
            return state.held
        }
        for continuation in waiting {
            continuation.resume()
        }
    }

    /// No record of anything asked about: in a whole world, every square
    /// comes back with no routes, which is all a case about requests needs.
    @concurrent
    func fetch(cellsNamed names: [String]) async -> TrailCellFetch {
        await withCheckedContinuation { continuation in
            let isOpen = state.withLock { state in
                state.asked.append(names)
                state.out += 1
                state.mostAtOnce = max(state.mostAtOnce, state.out)
                if !state.isOpen { state.held.append(continuation) }
                return state.isOpen
            }
            if isOpen { continuation.resume() }
        }
        state.withLock { $0.out -= 1 }
        return TrailCellFetch(manifest: manifest, cells: Dictionary(uniqueKeysWithValues: names.map { ($0, .absent) }))
    }
}

extension HikingRouteSquaresTests {
    /// `count` squares in a row, starting `rowsAway` rows from the suite's.
    private static func row(of count: Int, rowsAway: Int = 0) -> [RouteSquare] {
        (0..<count).map { column in
            RouteSquare(level: .detail, row: square.row + rowsAway, column: square.column + column)
        }
    }

    /// A map panned over ground nobody has seen: each pan a tile of its own,
    /// asking while the one before is still out. Every request held at once
    /// is one more for CloudKit to keep open for its two minutes.
    @Test(
        "however many tiles ask, one request is out at a time, the disk is drawn meanwhile, and every square comes in",
        .timeLimit(.minutes(1))
    )
    func oneRequestAtATime() async {
        let directory = Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let waves = 32
        let kept = Self.row(of: waves)
        let missing = Self.row(of: waves, rowsAway: 1)
        await Self.bringIn(kept, from: Self.library(StubTrailCellDatabase(), directory: directory))

        let database = HeldRequests()
        let library = Self.library(database, directory: directory)
        for wave in 0..<waves {
            // Told once the kept square is in, which is before the network
            // has answered anything: every request is still held.
            let tile = HikingRouteSquares.Tile(x: Double(wave), y: 1, zoomScale: 1)
            await Self.bringIn([kept[wave], missing[wave]], from: library, for: tile)
            #expect(library.holdsAll([kept[wave]]), "a kept square is drawn while a request is out")
        }
        #expect(database.mostAtOnce == 1)

        for _ in 0..<waves where !library.holdsAll(missing) {
            await settleDelegateHop(until: "a request is out, or every square is in") {
                database.held > 0 || library.holdsAll(missing)
            }
            database.releaseOne()
        }
        await settleDelegateHop(until: "every square is in") { library.holdsAll(missing) }

        #expect(database.mostAtOnce == 1, "no request went out while another was")
        let asked = database.asked.flatMap(\.self)
        #expect(asked.count == waves, "no square was asked for twice")
        #expect(Set(asked) == Set(missing.map(Self.name)))
        #expect(database.asked.count < waves, "what queued while a request was out went out together")
    }

    /// Low Data Mode turned on while the first of three requests is out.
    @Test(
        "once the network may not be asked, no further request goes out, and what came in is kept",
        .timeLimit(.minutes(1))
    )
    func networkIsAskedBeforeEachRequest() async {
        let clock = TestClock()
        let database = HeldRequests()
        let isAllowed = Mutex(true)
        let backOff = HeldBackPause()
        let library = HikingRouteSquares(
            database: database,
            directory: nil,
            clock: clock.read,
            allowsFetching: { isAllowed.withLock { $0 } },
            pause: { delay in await backOff.wait(delay) }
        )
        let squares = Self.row(of: 2 * HikingRouteSquares.squaresPerRequest + 1)
        #expect(library.request(squares, for: Self.tile) { /* told after the first request */ })
        await settleDelegateHop(until: "the first request is out") { database.held == 1 }

        isAllowed.withLock { $0 = false }
        database.releaseOne()
        await settleDelegateHop(until: "the squares not yet asked for wait out a back-off") { backOff.isWaiting }

        #expect(database.asked.count == 1, "no request went out once the network was refused")
        let first = Set(database.asked.first ?? [])
        let brought = squares.filter { first.contains(Self.name($0)) }
        let refused = squares.filter { !first.contains(Self.name($0)) }
        #expect(brought.count == HikingRouteSquares.squaresPerRequest)
        #expect(library.holdsAll(brought), "what the first request brought in is kept")
        #expect(!library.holdsAll(refused))
        let other = HikingRouteSquares.Tile(x: 1, y: 0, zoomScale: 1)
        let told = Mutex(0)
        #expect(library.request(refused, for: other) { told.withLock { $0 += 1 } })
        #expect(database.asked.count == 1, "nothing is asked for during the back-off")

        isAllowed.withLock { $0 = true }
        clock.advance(by: HikingRouteSquares.failedRetry)
        backOff.release()
        await settleDelegateHop(until: "the refused tile is told") { told.withLock { $0 } == 1 }
        database.open()
        await Self.bringIn(refused, from: library, for: other)
        await settleDelegateHop(until: "the refused squares are in") { library.holdsAll(squares) }
        #expect(database.asked.count == 3, "the rest went out once the network could be asked again")
    }

    /// The first of two requests learns that the squares are not the whole
    /// world, while the rest wait their turn behind it.
    @Test(
        "once a request finds the squares are not the whole world, nothing queued behind it is sent",
        .timeLimit(.minutes(1))
    )
    func nothingQueuedIsSentOnceTheSquaresAreNotTheWholeWorld() async {
        let clock = TestClock()
        let database = HeldRequests(manifest: .partial)
        let turns = Mutex(0)
        let backOff = HeldBackPause()
        let library = HikingRouteSquares(
            database: database,
            directory: nil,
            clock: clock.read,
            allowsFetching: {
                turns.withLock { $0 += 1 }
                return true
            },
            pause: { delay in await backOff.wait(delay) }
        )
        let squares = Self.row(of: HikingRouteSquares.squaresPerRequest + 1)
        #expect(library.request(squares, for: Self.tile) { /* told after the first request */ })
        await settleDelegateHop(until: "the first request is out") { database.held == 1 }

        database.releaseOne()
        await settleDelegateHop(until: "the square left behind has its turn") { turns.withLock { $0 } == 2 }
        // That turn is decided with the squares' state locked, and asking
        // takes the same lock, so this tile asks once the turn is decided.
        let other = HikingRouteSquares.Tile(x: 1, y: 0, zoomScale: 1)
        let told = Mutex(0)
        #expect(library.request(squares, for: other) { told.withLock { $0 += 1 } })

        clock.advance(by: HikingRouteSquares.unavailableRetry)
        await settleDelegateHop(until: "the wait for squares is being waited out") { backOff.isWaiting }
        backOff.release()
        await settleDelegateHop(until: "the tile is told") { told.withLock { $0 } == 1 }
        #expect(database.asked.count == 1, "nothing queued went out")
        #expect(backOff.waited == [HikingRouteSquares.unavailableRetry])
    }
}
