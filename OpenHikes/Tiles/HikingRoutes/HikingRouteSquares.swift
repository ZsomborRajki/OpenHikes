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
//  else is ``request(_:for:whenDone:)``: the disk, then one request for the
//  rest, off the main thread and off MapKit's drawing threads, after which
//  the tile is drawn again. A tile that needs a square nobody can read stays
//  empty rather than being drawn without it, so a line never stops at the
//  edge of a square that failed.
//
//  **The disk never waits for the network.** A round reads what is kept,
//  tells the tiles that were waiting, and hands the rest to a request it
//  does not wait for, so a valley seen yesterday draws at once beside one
//  that is still on its way over one bar of signal.
//
//  **A request is a tile's, and is refused like one.** Whether the network
//  may be asked is ``TileNetworkPolicy``'s answer for a tile somebody is
//  looking at, so Low Data Mode stops the layer where it stops the map. A
//  square that was refused, or that failed, is left for a minute, and then
//  the tiles that asked for it meanwhile are drawn again — nothing else would
//  ask, on a map nobody is moving. Only those: a tile already drawn whole is
//  not stroked again every minute of an afternoon offline.
//
//  Like the day hikes' search, this draws only from squares a manifest calls
//  the whole world — see ``TrailCellFetch/Manifest`` — because only then is a
//  square with no record a square with no routes rather than one not
//  uploaded yet. Until a manifest says so, the layer draws nothing, and asks
//  again after ``unavailableRetry``.
//

import Algorithms
import Foundation
import MapKit
import OrderedCollections
import os
import Synchronization

/// Where the layer's squares come from.
nonisolated final class HikingRouteSquares: Sendable {
    private static let logger = Logger(subsystem: "OpenHikes", category: "HikingRoutes")

    /// How many points are held in memory, across every square: tens of
    /// megabytes of map points, which is a region's every level several times
    /// over. Past it the squares drawn longest ago are let go.
    static let maximumHeldPoints = 3_000_000
    /// How many squares are held, however few points they have: a sea of
    /// squares with no routes is still a square each.
    static let maximumHeldSquares = 400
    /// How many squares are kept on disk. A map view reads one to four of a
    /// level, so this is a few hundred views' worth.
    static let maximumStoredSquares = 600
    /// How many squares one request asks for.
    static let squaresPerRequest = 40
    /// How long a request may go quiet, and how long it may take in all, in
    /// seconds. Longer than the day hikes' search allows itself: nothing waits
    /// behind a failure here but the same request a minute later, and a
    /// region's few megabytes take most of a minute over one bar of signal.
    static let requestTimeout: TimeInterval = 30
    static let resourceTimeout: TimeInterval = 120
    /// How long a square that could not be read is left before it is asked
    /// for again, in seconds.
    static let failedRetry: TimeInterval = 60
    /// How long the layer waits before asking again whether there are squares
    /// at all, in seconds, after a manifest said they are not the whole world.
    static let unavailableRetry: TimeInterval = 600

    /// The tile a redraw is owed to. One closure is kept for each, however
    /// often MapKit asks about a tile while its squares are on their way.
    nonisolated struct Tile: Hashable, Sendable {
        var x: Double
        var y: Double
        var zoomScale: Double
    }

    nonisolated private struct State {
        /// The squares in memory, the one drawn longest ago first.
        var held: OrderedDictionary<RouteSquare, DrawnRouteSquare> = [:]
        var heldPoints = 0
        var pending: Set<RouteSquare> = []
        var inFlight: Set<RouteSquare> = []
        var failedUntil: [RouteSquare: Date] = [:]
        var unavailableUntil: Date?
        var waiting: [Tile: @Sendable () -> Void] = [:]
        /// The tiles refused while a square they need waits out a back-off,
        /// drawn again when the next one lapses.
        var afterBackOff: [Tile: @Sendable () -> Void] = [:]
        var isWorking = false
        var isWakeScheduled = false

        /// `square` if it is held, now the one drawn most recently.
        @discardableResult mutating func use(_ square: RouteSquare) -> DrawnRouteSquare? {
            guard let drawn = held.removeValue(forKey: square) else { return nil }
            held[square] = drawn
            return drawn
        }

        /// When the soonest back-off after `moment` lapses, forgetting the
        /// ones that already have.
        mutating func soonestRetry(after moment: Date, now: Date) -> Date? {
            failedUntil = failedUntil.filter { $0.value > now }
            if let until = unavailableUntil, until <= now { unavailableUntil = nil }
            return (Array(failedUntil.values) + [unavailableUntil].compacted())
                .filter { $0 > moment }
                .min()
        }
    }

    private let state = Mutex(State())
    private let database: any TrailCellFetching
    private let store: TrailCellStore?
    private let clock: @Sendable () -> Date
    private let allowsFetching: @Sendable () -> Bool
    private let pause: @Sendable (TimeInterval) async -> Void

    /// - Parameters:
    ///   - directory: Where fetched squares are kept between launches; a
    ///     suite passes one of its own, and must. See *Deliberate test seams*
    ///     in the repository instructions.
    ///   - allowsFetching: Whether the network may be asked at all, just
    ///     before it is.
    ///   - pause: Waits out a back-off before the renderers draw again.
    init(
        database: any TrailCellFetching,
        directory: URL? = HikingRouteSquares.defaultDirectory(),
        clock: @escaping @Sendable () -> Date = { Date() },
        allowsFetching: @escaping @Sendable () -> Bool = { true },
        pause: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) }
    ) {
        self.database = database
        self.clock = clock
        self.allowsFetching = allowsFetching
        self.pause = pause
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
        // A square is asked for because the map is drawing its ground, so it
        // is refused where a tile somebody is looking at would be.
        let tilesMayBeFetched: @Sendable () -> Bool = {
            TileNetworkPolicy.decide(.interactive, conditions: TileCache.shared.networkConditions).isAllowed
        }
        return HikingRouteSquares(database: liveDatabase(), allowsFetching: tilesMayBeFetched)
    }

    /// The public database, as the layer reads it: under its own manifest,
    /// never the day hikes', and on its own timeouts.
    static func liveDatabase() -> CloudKitTrailCellDatabase {
        CloudKitTrailCellDatabase(
            manifestRecordName: RouteSquareGrid.manifestRecordName,
            requestTimeout: requestTimeout,
            resourceTimeout: resourceTimeout
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
    /// Whether every one of `squares` is in memory. Asking counts as using
    /// them: a tile that may be drawn is about to be.
    func holdsAll(_ squares: [RouteSquare]) -> Bool {
        state.withLock { state in
            guard squares.allSatisfy({ state.held[$0] != nil }) else { return false }
            for square in squares {
                state.use(square)
            }
            return true
        }
    }

    /// Every one of `squares` when all of them are in memory, and none when
    /// any is not: a tile is drawn whole or not at all.
    func drawable(_ squares: [RouteSquare]) -> [DrawnRouteSquare] {
        state.withLock { state in
            guard squares.allSatisfy({ state.held[$0] != nil }) else { return [] }
            return squares.compactMap { state.use($0) }
        }
    }

    /// Brings `squares` into memory — from disk, or from the database — and
    /// calls `whenDone` once any of them is, or once they cannot be; a tile
    /// still short of a square asks again and is kept waiting. Nothing is
    /// asked about a square that failed a moment ago, or while the layer
    /// knows there are no squares to read; `whenDone` is kept then until the
    /// back-off lapses.
    ///
    /// - Returns: whether `whenDone` will be called — every time but when
    ///   all of `squares` are in memory already.
    @discardableResult func request(
        _ squares: [RouteSquare],
        for tile: Tile,
        whenDone: @escaping @Sendable () -> Void
    ) -> Bool {
        let now = clock()
        let (kept, starts) = state.withLock { state -> (Bool, Bool) in
            if let until = state.unavailableUntil, until > now {
                state.afterBackOff[tile] = whenDone
                return (true, false)
            }
            let wanted = squares.filter { square in
                state.held[square] == nil
                    && !state.inFlight.contains(square)
                    && (state.failedUntil[square].map { $0 <= now } ?? true)
            }
            let waitsOnSomething = squares.contains { state.inFlight.contains($0) || state.pending.contains($0) }
            guard !wanted.isEmpty || waitsOnSomething else {
                guard squares.contains(where: { state.held[$0] == nil }) else { return (false, false) }
                state.afterBackOff[tile] = whenDone
                return (true, false)
            }
            state.pending.formUnion(wanted)
            state.waiting[tile] = whenDone
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
    /// Takes what is pending until nothing is: the disk at once, and the
    /// rest handed to a request this does not wait for.
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
            if !stored.isEmpty { finish(stored) }
            let missing = batch.filter { !stored.contains($0) }
            guard !missing.isEmpty else { continue }
            Task { await self.bringIn(missing) }
        }
    }

    /// Asks the database for `missing`, a request's worth at a time, when
    /// the network may be asked at all.
    @concurrent
    func bringIn(_ missing: [RouteSquare]) async {
        if allowsFetching() {
            for chunk in missing.chunks(ofCount: Self.squaresPerRequest) {
                await fetch(Array(chunk))
            }
        } else {
            Self.logger.notice("Hiking route squares are not fetched on this connection.")
            fail(missing)
        }
        finish(Set(missing))
    }

    /// Lets go of `squares` and tells every waiting tile to ask again.
    func finish(_ squares: Set<RouteSquare>) {
        let waiting = state.withLock { state in
            state.inFlight.subtract(squares)
            defer { state.waiting = [:] }
            return Array(state.waiting.values)
        }
        for whenDone in waiting {
            whenDone()
        }
    }

    func readStored(_ square: RouteSquare) -> DrawnRouteSquare? {
        guard let bytes = store?.bytes(ofCellNamed: RouteSquareGrid.recordName(for: square)),
              let file = try? RouteSquareFile(decoding: bytes)
        else { return nil }
        return DrawnRouteSquare(file, square: square)
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
            scheduleWake()
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
                read.append((square, DrawnRouteSquare(file, square: square)))
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
                state.heldPoints += drawn.pointCount
            }
            while state.heldPoints > Self.maximumHeldPoints || state.held.count > Self.maximumHeldSquares,
                  state.held.count > 1 {
                state.heldPoints -= state.held.removeFirst().value.pointCount
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
        scheduleWake()
    }

    /// Draws again, when the soonest back-off lapses, every tile refused
    /// while it lasted: one wake at a time, however many squares are waiting
    /// one out. A tile still short of a square in a later back-off is
    /// refused again, and waits for that one.
    ///
    /// - Parameter last: The back-off the wake before this one waited out.
    ///   Only a later one is waited for, so a clock that stands still — a
    ///   suite's — cannot have this wake itself for ever.
    func scheduleWake(after last: Date? = nil) {
        let now = clock()
        let due = state.withLock { state -> Date? in
            guard !state.isWakeScheduled,
                  let due = state.soonestRetry(after: max(now, last ?? now), now: now)
            else { return nil }
            state.isWakeScheduled = true
            return due
        }
        guard let due else { return }
        Task {
            await pause(due.timeIntervalSince(now))
            let refused = state.withLock { state in
                state.isWakeScheduled = false
                defer { state.afterBackOff = [:] }
                return Array(state.afterBackOff.values)
            }
            for whenDone in refused {
                whenDone()
            }
            // A square that failed after this wake was set is still waiting.
            scheduleWake(after: due)
        }
    }
}
