//
//  PlaceSquareLibrary.swift
//  OpenHikes
//
//  A place search answered from the pre-built squares: which squares the
//  search's boxes touch, the ones this device already holds, one request for
//  the rest, and the places in them that stand in the boxes.
//
//  ``TrailPointSource`` asks this first and Overpass only when this has no
//  answer, on the terms ``TrailCellLibrary`` keeps for the day hikes and for
//  its reasons:
//
//  - ``PlaceSquareAnswer/places(_:)`` is every place of the kinds asked for in
//    the boxes, given only when the squares are the whole world and every
//    square the boxes touch was read or is known not to exist. An empty one
//    means nothing of those kinds is mapped there.
//  - ``PlaceSquareAnswer/uncovered`` is the squares not reaching the search:
//    none published in this environment, or a set that is only part of the
//    world, whose squares are not read at all. See ``TrailCellFetch/Manifest``.
//  - ``PlaceSquareAnswer/unreachable`` is a square that should be readable
//    and was not.
//
//  Either of the last two sends the search to Overpass exactly as it went
//  before there were squares, so no search is worse than it was.
//
//  **What arrived is kept**, whatever the rest did, and so is a square with
//  no record in a set that is the whole world, as a square with no places in
//  it — see ``TrailCellStore``. What is kept is also what
//  ``keptPlaces(near:limit:)`` reads, with no request at all: what *Add Place*
//  offers before its search answers, and what a refused search draws.
//

import Algorithms
import CoreLocation
import Foundation
import OpenHikesData
import os

/// What the pre-built squares had to say about a place search.
nonisolated enum PlaceSquareAnswer: Sendable {
    /// Every place in the boxes drawn as one of the symbols asked for, in no
    /// particular order.
    case places([TrailPlace])
    /// The squares do not reach this search, so nothing is known from them.
    case uncovered
    /// A square the search needs could not be read.
    case unreachable
}

/// The places' pre-built squares, read through a disk cache.
nonisolated struct PlaceSquareLibrary: Sendable {
    private static let logger = Logger(subsystem: "OpenHikes", category: "PlaceSquares")

    /// The most squares one search may need and still be answered from them:
    /// one request's worth, the day hikes' — see
    /// ``TrailCellLibrary/maximumCellsPerRequest``.
    ///
    /// The widest place search, 20 km across, touches four squares at most
    /// short of 79°N, where a degree of longitude is still wider than it, and
    /// more than thirty-five only within a degree of a pole. There the search
    /// is Overpass's as it always was.
    static let maximumSquaresPerSearch = TrailCellLibrary.maximumCellsPerRequest

    /// How many squares are kept.
    ///
    /// A square is a degree each way and a search reads four at most, so this
    /// is the ground of a long trip's searches. The largest square measured
    /// is 217 KB, and the one around Berchtesgaden 142 KB; a third more once
    /// it is a file here. In `Caches`, where the system takes the lot back
    /// when it wants the room.
    static let maximumFiles = 100

    /// Where the files live for an ordinary launch: `Caches`, beside the day
    /// hikes' squares, for the reason ``TrailCellStore/defaultDirectory()``
    /// gives.
    static func defaultDirectory() -> URL? {
        FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("PlaceSquares", isDirectory: true)
    }

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
        directory: URL? = Self.defaultDirectory(),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.database = database
        store = directory.map { TrailCellStore(directory: $0, maximumFiles: Self.maximumFiles, clock: clock) }
    }

    /// Every place the squares hold in `boxes` that is drawn as one of
    /// `symbols`, or why they cannot say.
    ///
    /// Throws only a cancellation, for the reason
    /// ``TrailCellLibrary/trails(in:nearest:limit:)`` does.
    @concurrent
    func places(
        in boxes: [CuratedTrailQuery.BoundingBox],
        showing symbols: Set<TrailPlaceSymbol>
    ) async throws -> PlaceSquareAnswer {
        let names = Self.recordNames(covering: boxes)
        guard !names.isEmpty, names.count <= Self.maximumSquaresPerSearch else { return .uncovered }
        var held = kept(names)
        let missing = names.filter { held[$0] == nil }
        if !missing.isEmpty {
            switch try await fetched(missing) {
            case .squares(let squares):
                held.merge(squares) { _, fresh in fresh }

            case .uncovered:
                Self.logger.notice("The place squares are not the whole world, so they give no answer.")
                return .uncovered

            case .unreachable:
                Self.logger.notice("A place square could not be read, so the squares give no answer.")
                return .unreachable
            }
        }
        var found: [TrailPlace] = []
        for name in names {
            guard let square = held[name] else { return .unreachable }
            found += Self.places(in: square, showing: symbols) { coordinate in
                boxes.contains { $0.holds(coordinate) }
            }
        }
        // Counts only: which squares were read is where the hiker is looking.
        Self.logger.notice(
            """
            A place search read \(names.count, privacy: .public) squares, \
            \(missing.count, privacy: .public) of them fetched, and found \(found.count, privacy: .public) places.
            """
        )
        return .places(found)
    }

    /// The places of every kind the squares already on this device hold
    /// within `area`, nearest its middle first, asking for nothing.
    ///
    /// Every square kept was read from a set that was the whole world, so for
    /// the ground it covers this is what a search would have answered, as it
    /// stood when the square was fetched. Ground with no square kept answers
    /// nothing, which is not a claim that nothing is there: see
    /// ``TrailPointSourcing/cachedPlaces(near:limit:)`` for where this is
    /// used, and why that is enough.
    @concurrent
    func keptPlaces(near area: CommunitySearchArea, limit: Int) async -> [TrailPlace] {
        let names = Self.recordNames(covering: CuratedTrailQuery.searchBoxes(for: area))
        guard limit > 0, names.count <= Self.maximumSquaresPerSearch else { return [] }
        let center = area.coordinate
        return kept(names).values
            .flatMap { square in
                Self.places(in: square, showing: Set(TrailPlaceSymbol.allCases), where: area.contains)
            }
            .map { (place: $0, distance: RouteGeometry.distanceMeters(from: center, to: $0.clCoordinate)) }
            .min(count: limit) { $0.distance < $1.distance }
            .map(\.place)
    }
}

// MARK: - Reading a square

nonisolated extension PlaceSquareLibrary {
    /// The places of `square` standing where `isWanted` says, drawn as one of
    /// `symbols`, read as an Overpass answer's are — see
    /// ``TrailPointDecoding/place(elementType:id:latitude:longitude:tags:showing:)``.
    ///
    /// Where a place stands is asked first: a busy square holds thousands,
    /// and a search wants the few in its boxes.
    static func places(
        in square: PlaceSquareFile,
        showing symbols: Set<TrailPlaceSymbol>,
        where isWanted: (CLLocationCoordinate2D) -> Bool
    ) -> [TrailPlace] {
        let scale = Double(square.coordinateScale)
        return square.places.compactMap { place in
            let coordinate = CLLocationCoordinate2D(
                latitude: Double(place.point.latitude) / scale,
                longitude: Double(place.point.longitude) / scale
            )
            guard isWanted(coordinate) else { return nil }
            return TrailPointDecoding.place(
                elementType: place.element.name,
                id: place.id,
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                tags: place.tags,
                showing: symbols
            )
        }
    }

    /// The record names of every square `boxes` touch, each once.
    static func recordNames(covering boxes: [CuratedTrailQuery.BoundingBox]) -> [String] {
        var seen: Set<PlaceSquare> = []
        var names: [String] = []
        for box in boxes {
            let bounds = TrailCellBounds(south: box.south, west: box.west, north: box.north, east: box.east)
            for square in PlaceSquareGrid.squares(covering: bounds) where seen.insert(square).inserted {
                names.append(PlaceSquareGrid.recordName(for: square))
            }
        }
        return names
    }
}

// MARK: - Fetching what is not held

nonisolated private extension PlaceSquareLibrary {
    /// What a fetch of the squares this device did not hold amounts to.
    nonisolated enum Fetched {
        case squares([String: PlaceSquareFile])
        case uncovered
        case unreachable
    }

    /// The squares named `names` that this device keeps and can still read.
    /// A kept square that no longer reads is one to fetch again, not a reason
    /// to fail: the file is only a cache.
    func kept(_ names: [String]) -> [String: PlaceSquareFile] {
        var held: [String: PlaceSquareFile] = [:]
        for name in names {
            guard let bytes = store?.bytes(ofCellNamed: name),
                  let square = try? PlaceSquareFile(decoding: bytes)
            else { continue }
            held[name] = square
        }
        return held
    }

    /// The squares named `names`, in one request: a search needs at most
    /// ``maximumSquaresPerSearch``.
    func fetched(_ names: [String]) async throws -> Fetched {
        let fetch: TrailCellFetch
        do {
            fetch = try await database.fetch(cellsNamed: names)
        } catch {
            try Task.checkCancellation()
            Self.logger.error(
                "The place squares could not be reached: \(error.localizedDescription, privacy: .public)"
            )
            return .unreachable
        }

        // Asked before any square is looked at, the ones that arrived
        // included, for the reason ``TrailCellLibrary`` asks it: nothing is
        // read or kept from a set that is not the whole world.
        switch fetch.manifest {
        case .complete:
            break

        case .absent, .partial:
            return .uncovered

        case .unread:
            return .unreachable
        }

        var squares: [String: PlaceSquareFile] = [:]
        var fresh: [(name: String, bytes: Data)] = []
        var unread = 0
        for name in names {
            switch fetch.cells[name] ?? .failed {
            case .found(let bytes):
                // Read before it is kept, so bytes that are not a square are
                // never what the next search finds on disk.
                guard let square = try? PlaceSquareFile(decoding: bytes) else {
                    Self.logger.error("Square \(name, privacy: .public) is not a file this build reads.")
                    unread += 1
                    continue
                }
                squares[name] = square
                fresh.append((name: name, bytes: bytes))

            case .absent:
                // No record, in a set that is the whole world: ground with no
                // places on it, and worth remembering as such.
                let empty = PlaceSquareFile(places: [])
                squares[name] = empty
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
                \(unread, privacy: .public) of \(names.count, privacy: .public) place squares \
                could not be read; the rest are kept.
                """
            )
            return .unreachable
        }
        return .squares(squares)
    }
}

nonisolated private extension CuratedTrailQuery.BoundingBox {
    /// Whether `coordinate` stands in the box, edges included, as Overpass's
    /// own box filter has it.
    func holds(_ coordinate: CLLocationCoordinate2D) -> Bool {
        (south...north).contains(coordinate.latitude) && (west...east).contains(coordinate.longitude)
    }
}
