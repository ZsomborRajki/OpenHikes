//
//  TrailCellLibrary.swift
//  OpenHikes
//
//  A curated search answered from the pre-built squares: which squares the
//  area needs, the ones this device already holds — those a downloaded area
//  brought (``DownloadedTrailCells``), then those kept from earlier searches
//  — a request for the rest, several for a wide search, and the day hikes in
//  them that are in the area and nearest its middle. So a search over ground
//  the hiker downloaded asks nothing of the network, and answers with no
//  signal.
//
//  ``CuratedTrailSource`` asks this first and Overpass only when this has no
//  answer. What makes that safe is that **having no answer is one of the
//  things this can say**, and it says it rather than guessing:
//
//  - ``TrailCellAnswer/trails(_:)`` is the page of what the squares hold in
//    the area: the routes nearest the point that was asked about, as many
//    as were asked for. It is chosen from all of them — an empty one means
//    there are no waymarked day hikes there — and it is only given when the
//    squares are the whole world, and every square the area needs was read
//    or is known not to exist.
//  - ``TrailCellAnswer/uncovered`` is the squares not reaching this area:
//    no archive of them the tile server lists that this build reads, or a
//    set that is only part of the world. See ``TrailCellFetch/Manifest``.
//  - ``TrailCellAnswer/partial(_:)`` is the same page chosen from the
//    squares this device could read, when at least one other square the area
//    needs should be readable and was not.
//  - ``TrailCellAnswer/unreachable`` is no square the area needs that could
//    be read.
//
//  **A square that is there is not enough.** A regional build files a square
//  for the routes its extract holds whole, and leaves out the ones that run
//  out of the extract or lie wholly beyond it, so in part of the world a
//  record cannot say what is missing from it: read as answers, two squares of
//  such a set give a search a list that is a route short, with nothing on
//  screen to say so. So what a manifest has not called the whole world is not
//  read at all.
//
//  The two non-answers send the search to Overpass exactly as it went before
//  there were squares, so no search Overpass could answer is ever worse than
//  it was: the squares can be absent, half uploaded, or out of reach, and the
//  list still fills. A search wider than Overpass is asked about has the
//  squares alone, and without them it fails as a search does: see
//  ``CuratedTrailSource/listings(near:limit:)``.
//
//  **A part is never passed off as the whole.** Answering from four squares
//  of six as if from six would be a list that looks complete and is missing
//  a valley, with nothing on screen to say so — the failure
//  ``CuratedTrailNotice`` exists to rule out. So four squares of six are a
//  ``TrailCellAnswer/partial(_:)``, which sends the search to Overpass as a
//  non-answer does, and is drawn only when Overpass cannot be asked or does
//  not answer, with the gap said under the button. That is the search over
//  ground the hiker downloaded, with no signal, framed wide enough to reach
//  past the download: the download's day hikes are there to draw, and a
//  non-answer would have put the last search's in their place.
//
//  **What did arrive is still kept.** The four squares are no whole answer,
//  and they are four the next search does not have to fetch. A wide search asks
//  in several requests, one after another — see ``maximumCellsPerRequest`` —
//  and each one's squares are kept as it lands, so on a connection too slow
//  to carry the search in one try, each try asks only for what the one before
//  could not read.
//

import Algorithms
import CoreLocation
import Foundation
import os

/// What the pre-built squares had to say about an area.
nonisolated enum TrailCellAnswer: Equatable, Sendable {
    /// A page of ``trails(_:)`` chosen from the squares that could be read,
    /// while at least one other square the area needs could not be: the
    /// routes of part of the area, which may be missing some that stand
    /// nearer.
    case partial([CuratedTrail])
    /// The waymarked day hikes with a way in the area that stand nearest the
    /// point asked about — as many as were asked for, nearest first, each
    /// with its line. Fewer than were asked for is all there are.
    case trails([CuratedTrail])
    /// The squares do not reach this area, so nothing is known about it.
    case uncovered
    /// No square the area needs could be read.
    case unreachable
}

/// The pre-built squares, read through a disk cache.
nonisolated struct TrailCellLibrary: Sendable {
    private static let logger = Logger(subsystem: "OpenHikes", category: "TrailCells")

    /// The most squares one search may need and still be answered from them.
    ///
    /// The widest search the app allows — see
    /// ``CuratedTrailQuery/maximumRadiusMeters`` — needs up to 117 at 47°N,
    /// 162 at 60°N, 225 at 70°N and 477 short of 81°N, past the northernmost
    /// of Svalbard's islands, where a square is under five kilometres wide.
    /// Each is the most a map can need there wherever it stands on the grid,
    /// which is what a limit has to cover: a map panned north of Longyearbyen
    /// needs 378, and one over Ny-Ålesund 387. Past this the area is close
    /// enough to a pole that the count runs away, and the squares give no
    /// answer: Overpass is asked instead where the search is one it may be
    /// asked about, and a wider one fails.
    ///
    /// The count is not the cost. A square with no record costs nothing to
    /// be told of, and the far north is nearly all such squares: measured on
    /// 2026-11-14 against development, 369 of them were answered in 0.35
    /// seconds. What a search pays for is the squares that hold routes, a
    /// file each: see ``maximumCellsPerRequest`` for what those measured.
    static let maximumCellsPerSearch = 480

    /// The most squares one request names.
    ///
    /// The tile server answers a square at a time, a few of a request's at
    /// once (``SquareArchiveServer/concurrentRequests``), each square with
    /// ``requestTimeout`` to itself and the request with ``resourceTimeout``
    /// in all, so a slow connection that runs a request out of time loses
    /// only the squares still out: what arrived is kept. Thirty-five is what
    /// the widest search named before the ceiling was raised, at 47°N, and
    /// what a request to the public database, which gave back nothing when
    /// it failed as a whole, was cut to. A wider search is four requests at 47°N and five at 60°N, sent
    /// one after another, so a superseded search is heard of between them,
    /// and each one's squares are kept as it lands. Around Stuttgart, the
    /// busiest ground measured, 117 squares were 12 MB of files.
    static let maximumCellsPerRequest = 35

    /// How long one square's request may go quiet, and take in all, in
    /// seconds.
    ///
    /// Short, and set rather than left to the system's own (a minute of
    /// silence, and a week for the whole), because of what waits behind a
    /// failure here: ``CuratedTrailSource`` asks Overpass instead, and a
    /// hiker should reach that in seconds rather than after a spinner has
    /// outlasted their patience. A place search has Overpass behind it too,
    /// and takes these (see ``PlaceSquareLibrary``). The hiking-routes layer
    /// has nothing to fall back on, and sets its own (see
    /// ``HikingRouteSquares``).
    static let requestTimeout: TimeInterval = 15
    static let resourceTimeout: TimeInterval = 30

    private let database: any TrailCellFetching
    /// The squares the downloaded areas brought, read first. `nil` for a
    /// launch with none to read, every suite's unless it passes some.
    private let downloads: (any DownloadedTrailCells)?
    /// `nil` for a launch with nowhere to keep squares, which costs a fetch
    /// per search and breaks nothing.
    private let store: TrailCellStore?

    /// - Parameter downloads: The squares downloaded areas hold, which the
    ///   app's launch reads out of ``OfflineCountryArchives/shared``.
    /// - Parameter directory: Where fetched squares are kept between
    ///   launches. A suite passes one of its own, and must: the default is
    ///   the app's `Caches`. See *Deliberate test seams* in the repository
    ///   instructions.
    init(
        database: any TrailCellFetching,
        downloads: (any DownloadedTrailCells)? = nil,
        directory: URL? = TrailCellStore.defaultDirectory(),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.database = database
        self.downloads = downloads
        store = directory.map { TrailCellStore(directory: $0, clock: clock) }
    }

    /// The `limit` day hikes the squares hold in `boxes` that stand nearest
    /// `center`, those of the squares that could be read, or why they cannot
    /// say.
    ///
    /// Throws only a cancellation: a search superseded mid-fetch is not an
    /// unreachable square, and reporting it as one would send a request to
    /// Overpass on behalf of a search nobody is waiting for.
    @concurrent
    func trails(
        in boxes: [CuratedTrailQuery.BoundingBox],
        nearest center: CLLocationCoordinate2D,
        limit: Int
    ) async throws -> TrailCellAnswer {
        let names = Self.recordNames(reaching: boxes)
        guard !names.isEmpty, names.count <= Self.maximumCellsPerSearch else { return .uncovered }

        var held: [String: TrailCellFile] = [:]
        // What a download holds is the square the server would send, kept
        // for as long as the download, so it answers ahead of a kept copy:
        // the search reads one build where it can, and the copy no longer
        // has to last.
        for (name, bytes) in downloads?.trailCells(named: names) ?? [:] {
            guard let cell = try? TrailCellFile(decoding: bytes) else {
                Self.logger.error("Downloaded square \(name, privacy: .public) is not a file this build reads.")
                continue
            }
            held[name] = cell
        }
        let downloaded = held.count
        for name in names where held[name] == nil {
            // A kept square that no longer reads is one to fetch again, not a
            // reason to fail: the file is only a cache.
            guard let bytes = store?.bytes(ofCellNamed: name),
                  let cell = try? TrailCellFile(decoding: bytes)
            else { continue }
            held[name] = cell
        }
        let missing = names.filter { held[$0] == nil }
        if !missing.isEmpty {
            switch try await fetched(missing) {
            case .cells(let cells), .unreachable(let cells):
                // What arrived of a fetch that could not be read whole is
                // read all the same: see ``TrailCellAnswer/partial(_:)``.
                held.merge(cells) { _, fresh in fresh }

            case .uncovered:
                Self.logger.notice("The trail squares are not the whole world, so they give no answer.")
                return .uncovered
            }
        }

        // Every route in the area is measured, and only the page is drawn:
        // see ``CuratedTrailDecoding/trails(nearestOf:limit:)``. A route two
        // squares both hold is measured twice and drawn once — see
        // ``CuratedTrailDecoding/drawn(_:limit:)``.
        let read = names.compactMap { held[$0] }
        guard !read.isEmpty else {
            Self.logger.notice("No trail square could be read, so the squares give no answer.")
            return .unreachable
        }
        let candidates = read.flatMap { cell in
            CuratedTrailDecoding.candidates(in: cell, touching: boxes, from: center)
        }
        let trails = CuratedTrailDecoding.trails(nearestOf: candidates, limit: limit)
        // Counts only: which squares were read is where the hiker is looking.
        Self.logger.notice(
            """
            A search read \(read.count, privacy: .public) of \(names.count, privacy: .public) \
            trail squares, \(downloaded, privacy: .public) of them downloaded and \
            \(missing.count, privacy: .public) asked for, found \
            \(candidates.count, privacy: .public) routes and offers \
            \(trails.count, privacy: .public).
            """
        )
        return read.count == names.count ? .trails(trails) : .partial(trails)
    }
}

// MARK: - Fetching what is not held

nonisolated private extension TrailCellLibrary {
    /// What a fetch of the squares this device did not hold amounts to.
    nonisolated enum Fetched {
        case cells([String: TrailCellFile])
        case uncovered
        /// A square could not be read, and these are the ones that were: each
        /// out of a set that is the whole world, as every kept square is.
        case unreachable([String: TrailCellFile])
    }

    /// The squares named `names`, asked for a request's worth at a time.
    ///
    /// A request that could not be read whole ends the fetch: the network
    /// that failed it would most likely fail the ones after it, and the
    /// search already has no whole answer. What the requests before it
    /// brought is kept — see this file's header — and handed back, for a
    /// ``TrailCellAnswer/partial(_:)``. A cancellation ends it too.
    func fetched(_ names: [String]) async throws -> Fetched {
        var cells: [String: TrailCellFile] = [:]
        for request in names.chunks(ofCount: Self.maximumCellsPerRequest) {
            // Asked before every request rather than left to the request
            // that is out, which may finish rather than hear of it: the
            // browser starts the next search only once this one has ended.
            try Task.checkCancellation()
            switch try await fetched(request: Array(request)) {
            case .cells(let arrived):
                cells.merge(arrived) { _, fresh in fresh }

            case .uncovered:
                return .uncovered

            case .unreachable(let arrived):
                cells.merge(arrived) { _, fresh in fresh }
                return .unreachable(cells)
            }
        }
        return .cells(cells)
    }

    func fetched(request names: [String]) async throws -> Fetched {
        let fetch: TrailCellFetch
        do {
            fetch = try await database.fetch(cellsNamed: names)
        } catch {
            try Task.checkCancellation()
            Self.logger.error(
                "The trail squares could not be reached: \(error.localizedDescription, privacy: .public)"
            )
            return .unreachable([:])
        }

        // Asked before any square is looked at, the ones that arrived
        // included: see this file's header for why a record that is there
        // answers nothing in a set that is part of the world. It also means
        // nothing is kept from such a set, so every kept square came out of
        // one that was the whole world.
        switch fetch.manifest {
        case .complete:
            break

        case .absent, .partial:
            return .uncovered

        case .unread:
            return .unreachable([:])
        }

        var cells: [String: TrailCellFile] = [:]
        var fresh: [(name: String, bytes: Data)] = []
        var unread = 0
        for name in names {
            switch fetch.cells[name] ?? .failed {
            case .found(let bytes):
                // Read before it is kept, so bytes that are not a square are
                // never what the next search finds on disk.
                guard let cell = try? TrailCellFile(decoding: bytes) else {
                    Self.logger.error("Square \(name, privacy: .public) is not a file this build reads.")
                    unread += 1
                    continue
                }
                cells[name] = cell
                fresh.append((name: name, bytes: bytes))

            case .absent:
                // No record, in a set that is the whole world: a square with
                // nothing in it, and worth remembering as one.
                let empty = TrailCellFile(relations: [])
                cells[name] = empty
                fresh.append((name: name, bytes: empty.encoded()))

            case .failed:
                unread += 1
            }
        }
        // Kept whether or not the rest arrived — see this file's header.
        store?.save(fresh)
        guard unread == 0 else {
            Self.logger.notice(
                """
                \(unread, privacy: .public) of \(names.count, privacy: .public) trail squares \
                could not be read; the rest are kept.
                """
            )
            return .unreachable(cells)
        }
        return .cells(cells)
    }

    /// The record names of every square within reach of `boxes`, each once.
    static func recordNames(reaching boxes: [CuratedTrailQuery.BoundingBox]) -> [String] {
        var seen: Set<TrailCell> = []
        var names: [String] = []
        for box in boxes {
            let bounds = TrailCellBounds(south: box.south, west: box.west, north: box.north, east: box.east)
            for cell in TrailCellGrid.cells(reaching: bounds) where seen.insert(cell).inserted {
                names.append(TrailCellGrid.recordName(for: cell))
            }
        }
        return names
    }
}
