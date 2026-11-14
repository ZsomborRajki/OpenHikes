//
//  HikingRouteSquares.swift
//  OpenHikes
//
//  The hiking-routes layer's squares, as the map draws them: held in memory,
//  kept on disk, and fetched from the public database by name for whatever
//  ground the map is about to draw.
//
//  The renderer asks synchronously whether every square a tile needs is in
//  memory — see ``drawable(_:)`` — and that is all it ever waits on. Anything
//  else is ``request(_:whenDone:)``: the disk, then one request for the rest,
//  off the main thread and off MapKit's drawing threads, after which the tile
//  is drawn again. A tile that needs a square nobody can read stays empty
//  rather than being drawn without it, so a line never stops at the edge of a
//  square that failed.
//
//  Like the day hikes' search, this draws only from squares a manifest calls
//  the whole world — see ``TrailCellFetch/Manifest`` — because only then is a
//  square with no record a square with no routes rather than one not
//  uploaded yet. Until a manifest says so, the layer draws nothing, and asks
//  again after ``unavailableRetry``.
//

import Foundation
import MapKit
import os
import Synchronization

/// Where the layer's squares come from.
nonisolated final class HikingRouteSquares: Sendable {
    private static let logger = Logger(subsystem: "OpenHikes", category: "HikingRoutes")

    /// How many points are held in memory, across every square: tens of
    /// megabytes of map points, which is a region's every level several times
    /// over. Past it the squares held longest are let go.
    static let maximumHeldPoints = 3_000_000
    /// How many squares are kept on disk. A map view reads one to four of a
    /// level, so this is a few hundred views' worth.
    static let maximumStoredSquares = 600
    /// How many squares one request asks for.
    static let squaresPerRequest = 40
    /// How long a square that could not be read is left before it is asked
    /// for again, in seconds.
    static let failedRetry: TimeInterval = 60
    /// How long the layer waits before asking again whether there are squares
    /// at all, in seconds, after a manifest said they are not the whole world.
    static let unavailableRetry: TimeInterval = 600

    private struct State {
        var held: [RouteSquare: DrawnRouteSquare] = [:]
        /// The held squares, oldest first, for letting go of.
        var heldOrder: [RouteSquare] = []
        var heldPoints = 0
        var pending: Set<RouteSquare> = []
        var inFlight: Set<RouteSquare> = []
        var failedUntil: [RouteSquare: Date] = [:]
        var unavailableUntil: Date?
        var waiting: [@Sendable () -> Void] = []
        var isWorking = false
    }

    private let state = Mutex(State())
    private let database: any TrailCellFetching
    private let store: TrailCellStore?
    private let clock: @Sendable () -> Date

    /// - Parameter directory: Where fetched squares are kept between
    ///   launches; a suite passes one of its own, and must. See *Deliberate
    ///   test seams* in the repository instructions.
    init(
        database: any TrailCellFetching,
        directory: URL? = HikingRouteSquares.defaultDirectory(),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.database = database
        self.clock = clock
        store = directory.map { directory in
            TrailCellStore(directory: directory, maximumFiles: Self.maximumStoredSquares, clock: clock)
        }
    }

    /// The squares for this launch, read from the public database, or `nil`
    /// for a launch under test — UI tests included — on the terms
    /// ``OpenHikesModel/makeCommunityTransport()`` keeps: there is no sandbox
    /// for a public database, so no suite may fetch from it.
    static func forThisLaunch() -> HikingRouteSquares? {
        guard !AppLaunchEnvironment.isRunningTests else { return nil }
        return HikingRouteSquares(
            database: CloudKitTrailCellDatabase(manifestRecordName: RouteSquareGrid.manifestRecordName)
        )
    }

    /// `Caches`, beside the day hikes' squares: everything here is
    /// OpenStreetMap's and comes back with the next fetch.
    static func defaultDirectory() -> URL? {
        FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("HikingRouteSquares", isDirectory: true)
    }
}

// MARK: - What the renderer asks

nonisolated extension HikingRouteSquares {
    /// Whether every one of `squares` is in memory.
    func holdsAll(_ squares: [RouteSquare]) -> Bool {
        state.withLock { state in squares.allSatisfy { state.held[$0] != nil } }
    }

    /// Every one of `squares` when all of them are in memory, and none when
    /// any is not: a tile is drawn whole or not at all.
    func drawable(_ squares: [RouteSquare]) -> [DrawnRouteSquare] {
        state.withLock { state in
            var found: [DrawnRouteSquare] = []
            found.reserveCapacity(squares.count)
            for square in squares {
                guard let held = state.held[square] else { return [] }
                found.append(held)
            }
            return found
        }
    }

    /// Brings `squares` into memory — from disk, or from the database — and
    /// calls `whenDone` once they are, or once they cannot be. Nothing is
    /// asked about a square that failed a moment ago, or while the layer
    /// knows there are no squares to read; `whenDone` is not kept then, so a
    /// tile that asks again draws nothing rather than asking forever.
    ///
    /// - Returns: whether `whenDone` will be called.
    @discardableResult func request(_ squares: [RouteSquare], whenDone: @escaping @Sendable () -> Void) -> Bool {
        let now = clock()
        let (kept, starts) = state.withLock { state -> (Bool, Bool) in
            if let until = state.unavailableUntil, until > now { return (false, false) }
            let wanted = squares.filter { square in
                state.held[square] == nil
                    && !state.inFlight.contains(square)
                    && (state.failedUntil[square].map { $0 <= now } ?? true)
            }
            let waitsOnSomething = squares.contains { state.inFlight.contains($0) || state.pending.contains($0) }
            guard !wanted.isEmpty || waitsOnSomething else { return (false, false) }
            state.pending.formUnion(wanted)
            state.waiting.append(whenDone)
            guard !state.isWorking else { return (true, false) }
            state.isWorking = true
            return (true, true)
        }
        if starts {
            Task { await self.work() }
        }
        return kept
    }
}

// MARK: - Bringing squares in

nonisolated private extension HikingRouteSquares {
    /// Takes what is pending until nothing is, and tells every waiting tile
    /// after each round.
    @concurrent
    func work() async {
        while true {
            let batch = state.withLock { state -> [RouteSquare] in
                let batch = Array(state.pending)
                state.pending = []
                state.inFlight.formUnion(batch)
                if batch.isEmpty { state.isWorking = false }
                return batch
            }
            guard !batch.isEmpty else { return }
            let fromDisk = batch.compactMap { square in
                readStored(square).map { (square, $0) }
            }
            hold(fromDisk)
            let stored = Set(fromDisk.map(\.0))
            let missing = batch.filter { !stored.contains($0) }
            for chunk in stride(from: 0, to: missing.count, by: Self.squaresPerRequest) {
                await fetch(Array(missing[chunk..<min(chunk + Self.squaresPerRequest, missing.count)]))
            }
            let waiting = state.withLock { state in
                state.inFlight.subtract(batch)
                defer { state.waiting = [] }
                return state.waiting
            }
            for whenDone in waiting {
                whenDone()
            }
        }
    }

    func readStored(_ square: RouteSquare) -> DrawnRouteSquare? {
        guard let bytes = store?.bytes(ofCellNamed: RouteSquareGrid.recordName(for: square)),
              let file = try? RouteSquareFile(decoding: bytes)
        else { return nil }
        return DrawnRouteSquare(file)
    }

    /// One request for `squares`, read into memory and kept on disk.
    func fetch(_ squares: [RouteSquare]) async {
        let names = squares.map(RouteSquareGrid.recordName(for:))
        let started = ContinuousClock.now
        let answer: TrailCellFetch
        do {
            answer = try await database.fetch(cellsNamed: names)
        } catch {
            Self.logger.error(
                "Hiking route squares could not be reached: \(error.localizedDescription, privacy: .public)"
            )
            fail(squares)
            return
        }
        switch answer.manifest {
        case .complete:
            break
        case .absent, .partial:
            Self.logger.notice("The hiking route squares are not the whole world, so the layer draws nothing.")
            state.withLock { $0.unavailableUntil = clock().addingTimeInterval(Self.unavailableRetry) }
            return
        case .unread:
            Self.logger.error("The hiking route squares' manifest could not be read, so the squares wait a minute.")
            fail(squares)
            return
        }
        var read: [(RouteSquare, DrawnRouteSquare)] = []
        var kept: [(name: String, bytes: Data)] = []
        var failed: [RouteSquare] = []
        for (square, name) in zip(squares, names) {
            switch answer.cells[name] ?? .failed {
            case .found(let bytes):
                guard let file = try? RouteSquareFile(decoding: bytes) else {
                    Self.logger.error("Hiking route square \(name, privacy: .public) is not a file this build reads.")
                    failed.append(square)
                    continue
                }
                read.append((square, DrawnRouteSquare(file)))
                kept.append((name: name, bytes: bytes))
            case .absent:
                // No record in a set that is the whole world: no routes here,
                // and worth remembering as such.
                read.append((square, .empty))
                kept.append((name: name, bytes: RouteSquareFile(routes: [], lines: [], coordinateScale: 1).encoded()))
            case .failed:
                failed.append(square)
            }
        }
        store?.save(kept)
        hold(read)
        fail(failed)
        // Counts only: which squares were read is where the hiker is looking.
        Self.logger.notice(
            """
            Fetched \(read.count, privacy: .public) hiking route squares, \
            \(kept.reduce(0) { $0 + $1.bytes.count }, privacy: .public) bytes, \
            \(failed.count, privacy: .public) failed, in \(started.duration(to: .now), privacy: .public).
            """
        )
    }

    func hold(_ squares: [(RouteSquare, DrawnRouteSquare)]) {
        guard !squares.isEmpty else { return }
        state.withLock { state in
            for (square, drawn) in squares where state.held[square] == nil {
                state.held[square] = drawn
                state.heldOrder.append(square)
                state.heldPoints += drawn.pointCount
            }
            while state.heldPoints > Self.maximumHeldPoints, state.heldOrder.count > 1 {
                let oldest = state.heldOrder.removeFirst()
                state.heldPoints -= state.held.removeValue(forKey: oldest)?.pointCount ?? 0
            }
        }
    }

    func fail(_ squares: [RouteSquare]) {
        guard !squares.isEmpty else { return }
        let until = clock().addingTimeInterval(Self.failedRetry)
        state.withLock { state in
            for square in squares {
                state.failedUntil[square] = until
            }
        }
    }
}
