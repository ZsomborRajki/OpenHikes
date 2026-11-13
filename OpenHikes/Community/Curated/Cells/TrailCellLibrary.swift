//
//  TrailCellLibrary.swift
//  OpenHikes
//
//  A curated search answered from the pre-built squares: which squares the
//  area needs, the ones this device already holds, one request for the rest,
//  and the day hikes in them that are in the area.
//
//  ``CuratedTrailSource`` asks this first and Overpass only when this has no
//  answer. What makes that safe is that **having no answer is one of the
//  things this can say**, and it says it rather than guessing:
//
//  - ``TrailCellAnswer/trails(_:)`` is everything the squares hold in the
//    area. It is complete — an empty one means there are no waymarked day
//    hikes there — and it is only given when the squares are the whole
//    world, and every square the area needs was read or is known not to
//    exist.
//  - ``TrailCellAnswer/uncovered`` is the squares not reaching this area:
//    none published in this environment, or a set that is only part of the
//    world. See ``TrailCellFetch/Manifest``.
//  - ``TrailCellAnswer/unreachable`` is a square that should be readable and
//    was not.
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
//  there were squares, so nothing a hiker sees is ever worse than it was: the
//  squares can be absent, half uploaded, or out of reach, and the list still
//  fills.
//
//  A search is all-or-nothing on purpose. Answering from four squares of six
//  would be a list that looks complete and is missing a valley, with nothing
//  on screen to say so — the failure ``CuratedTrailNotice`` exists to rule
//  out.
//

import Foundation
import os

/// What the pre-built squares had to say about an area.
nonisolated enum TrailCellAnswer: Equatable, Sendable {
    /// Every waymarked day hike with a way in the area, each with its line,
    /// in no particular order.
    case trails([CuratedTrail])
    /// The squares do not reach this area, so nothing is known about it.
    case uncovered
    /// A square the area needs could not be read.
    case unreachable
}

/// The pre-built squares, read through a disk cache.
nonisolated struct TrailCellLibrary: Sendable {
    private static let logger = Logger(subsystem: "OpenHikes", category: "TrailCells")

    /// The most squares one search may need and still be answered from them.
    ///
    /// The widest search the app allows — see
    /// ``CuratedTrailQuery/maximumRadiusMeters`` — needs up to thirty-five at
    /// 47°N, forty-five at 60°N and sixty at 70°N, where a square is under
    /// ten kilometres wide. Past this the area is close enough to a pole that
    /// the count runs away, and Overpass is asked instead.
    static let maximumCellsPerSearch = 100

    private let database: any TrailCellFetching
    /// `nil` for a launch with nowhere to keep squares, which costs a fetch
    /// per search and breaks nothing.
    private let store: TrailCellStore?

    /// - Parameter directory: Where fetched squares are kept between
    ///   launches. A suite passes one of its own, and must: the default is
    ///   the app's `Caches`. See *Deliberate test seams* in the repository
    ///   instructions.
    init(
        database: any TrailCellFetching,
        directory: URL? = TrailCellStore.defaultDirectory(),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.database = database
        store = directory.map { TrailCellStore(directory: $0, clock: clock) }
    }

    /// What the squares hold in `boxes`, or why they cannot say.
    ///
    /// Throws only a cancellation: a search superseded mid-fetch is not an
    /// unreachable square, and reporting it as one would send a request to
    /// Overpass on behalf of a search nobody is waiting for.
    @concurrent
    func trails(in boxes: [CuratedTrailQuery.BoundingBox]) async throws -> TrailCellAnswer {
        let names = Self.recordNames(reaching: boxes)
        guard !names.isEmpty, names.count <= Self.maximumCellsPerSearch else { return .uncovered }

        var held: [String: TrailCellFile] = [:]
        for name in names {
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
            case .cells(let cells):
                held.merge(cells) { _, fresh in fresh }

            case .uncovered:
                Self.logger.notice("The trail squares are not the whole world, so Overpass is asked.")
                return .uncovered

            case .unreachable:
                Self.logger.notice("A trail square could not be read, so Overpass is asked.")
                return .unreachable
            }
        }

        var trails: [CuratedTrail] = []
        // A route is filed under one square, but an upload replaces squares
        // one at a time, so for its duration a route whose box moved can be
        // in the old square and the new.
        var offered: Set<Int64> = []
        for name in names {
            guard let cell = held[name] else { return .unreachable }
            for trail in CuratedTrailDecoding.trails(in: cell, touching: boxes)
            where offered.insert(trail.relationID).inserted {
                trails.append(trail)
            }
        }
        // Counts only: which squares were read is where the hiker is looking.
        Self.logger.notice(
            """
            A search read \(names.count, privacy: .public) trail squares, \
            \(missing.count, privacy: .public) of them fetched, and found \
            \(trails.count, privacy: .public) routes.
            """
        )
        return .trails(trails)
    }
}

// MARK: - Fetching what is not held

nonisolated private extension TrailCellLibrary {
    /// What a fetch of the squares this device did not hold amounts to.
    nonisolated enum Fetched {
        case cells([String: TrailCellFile])
        case uncovered
        case unreachable
    }

    func fetched(_ names: [String]) async throws -> Fetched {
        let fetch: TrailCellFetch
        do {
            fetch = try await database.fetch(cellsNamed: names)
        } catch {
            try Task.checkCancellation()
            Self.logger.error(
                "The trail squares could not be reached: \(error.localizedDescription, privacy: .public)"
            )
            return .unreachable
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
            return .unreachable
        }

        var cells: [String: TrailCellFile] = [:]
        var fresh: [(name: String, bytes: Data)] = []
        for name in names {
            switch fetch.cells[name] ?? .failed {
            case .found(let bytes):
                // Read before it is kept, so bytes that are not a square are
                // never what the next search finds on disk.
                guard let cell = try? TrailCellFile(decoding: bytes) else {
                    Self.logger.error("Square \(name, privacy: .public) is not a file this build reads.")
                    return .unreachable
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
                return .unreachable
            }
        }
        store?.save(fresh)
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
