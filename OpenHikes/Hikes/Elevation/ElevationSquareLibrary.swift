//
//  ElevationSquareLibrary.swift
//  OpenHikes
//
//  Heights for the points of a line that has none, read from the elevation
//  squares on the OpenHikes tile server: which squares the points need, the
//  ones this device already holds — those a downloaded area brought
//  (``DownloadedElevationSquares``), then those kept from earlier answers —
//  one request for the rest, and the height at each point read off the four
//  posts around it. See
//  ``ElevationSquareGrid`` for the squares, and ``CuratedElevationSourcing``
//  for the three callers — a curated route, a drawn trail and a library hike
//  with no heights.
//
//  ## Free, and nobody else's
//
//  The heights used to be a billed service's (Stadia Maps'), asked per call
//  with the coordinates of the line, and so were OpenHikes Pro's. These are
//  squares of an archive of our own, read through the tile server the map
//  already reads, so every hiker has them, and what leaves the device is the
//  names of the squares, as a map tile's address does.
//
//  ## What an answer is
//
//  Every square a point needs is read, or the answer is no answer: heights
//  for some points and not others would pair up wrongly, which is the one
//  thing ``CuratedElevationSourcing`` forbids. So:
//
//  - A square the server has no tile for, in an archive that is the whole
//    world, is sea at sea level, kept as an empty file.
//  - No archive this build reads throws ``CuratedElevationFailure/uncovered``,
//    and a square that would not come, or came and was not one, throws
//    ``CuratedElevationFailure/unreachable``.
//  - A point whose four posts are not all heights — ground Copernicus
//    withholds — is `nan`, and a line with one gets no profile at all
//    (``CuratedElevationSourcing/samples(of:)``) rather than a grade drawn
//    across ground nobody measured.
//
//  ## What a download brought answers first
//
//  A downloaded area's squares are the server's own, kept for as long as the
//  download, so they answer ahead of a kept copy and of the server: a line on
//  ground the hiker downloaded asks nothing of the network, and is given its
//  heights with no signal. A line that reaches past the download asks for the
//  rest, and with no signal has no answer, as any line whose squares would
//  not come.
//
//  ## What arrived is kept
//
//  In `Caches`, as the trail squares are (``TrailCellStore``), so the trail
//  maker's next ask as a drawing settles, and a second look at a valley,
//  send nothing at all. A square is read from the disk for each answer
//  rather than held in memory: one decodes in about a millisecond.
//

import Algorithms
import CoreLocation
import Foundation
import os

nonisolated struct ElevationSquareLibrary: CuratedElevationSourcing {
    private static let logger = Logger(subsystem: "OpenHikes", category: "Elevation")

    /// The most squares one answer may read: about a hundred and fifty
    /// kilometres of line in the Alps, 6 MB at the most. A longer line is
    /// answered with no heights rather than with a download that size, and
    /// its two hundred readings would be too far apart to draw a profile
    /// anybody could read anyway.
    static let maximumSquaresPerRequest = 64

    /// How many squares are kept: four of the longest answers, some 35 MB of
    /// files at the Alps' hundred kilobytes and a third more once each is a
    /// file here. In `Caches`, where the system takes the lot back when it
    /// wants the room.
    static let maximumFiles = 256

    /// How long one square's request may go quiet, and how long one answer
    /// may take in all: the day hikes' quiet, and twice their whole, since a
    /// long line's squares are larger than theirs.
    static let requestTimeout = TrailCellLibrary.requestTimeout
    static let resourceTimeout = TrailCellLibrary.resourceTimeout * 2

    /// Where the files live for an ordinary launch: `Caches`, beside the
    /// other squares, for the reason ``TrailCellStore/defaultDirectory()``
    /// gives.
    static func defaultDirectory() -> URL? {
        FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("ElevationSquares", isDirectory: true)
    }

    /// The library every launch that may reach the tile server shares, so
    /// that the server's list of archives is read once an hour rather than
    /// once an answer. Built only when first asked for, and asked for only
    /// behind the composition root's guards, so no suite reaches it.
    static let live = Self(
        database: SquareArchiveServer.live(
            .elevation,
            requestTimeout: requestTimeout,
            resourceTimeout: resourceTimeout
        ),
        downloads: OfflineCountryArchives.shared
    )

    private let database: any TrailCellFetching
    /// The squares the downloaded areas brought, read first. `nil` for a
    /// launch with none to read, every suite's unless it passes some.
    private let downloads: (any DownloadedElevationSquares)?
    /// `nil` for a launch with nowhere to keep squares, which costs a fetch
    /// per answer and breaks nothing.
    private let store: TrailCellStore?

    /// - Parameter downloads: The squares downloaded areas hold, which the
    ///   live library reads out of ``OfflineCountryArchives/shared``.
    /// - Parameter directory: Where fetched squares are kept between
    ///   launches. A suite passes one of its own, and must: the default is
    ///   the app's `Caches`. See *Deliberate test seams* in the repository
    ///   instructions.
    init(
        database: any TrailCellFetching,
        downloads: (any DownloadedElevationSquares)? = nil,
        directory: URL? = Self.defaultDirectory(),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.database = database
        self.downloads = downloads
        store = directory.map { TrailCellStore(directory: $0, maximumFiles: Self.maximumFiles, clock: clock) }
    }

    @concurrent
    func heights(at coordinates: [CLLocationCoordinate2D]) async throws -> [Double] {
        guard !coordinates.isEmpty else { return [] }
        let neighborhoods = coordinates.map { coordinate in
            ElevationSquareGrid.posts(aroundLatitude: coordinate.latitude, longitude: coordinate.longitude)
        }
        let squares = Array(
            neighborhoods.lazy
                .compactMap(\.self)
                .flatMap(\.posts)
                .map { ElevationSquareGrid.place(of: $0).square }
                .uniqued()
        )
        guard squares.count <= Self.maximumSquaresPerRequest else {
            Self.logger.notice("A line crosses \(squares.count, privacy: .public) elevation squares: too many to read.")
            throw CuratedElevationFailure.tooLong
        }
        let read = try await files(of: squares)
        return neighborhoods.map { around in
            around?.height { post in
                let place = ElevationSquareGrid.place(of: post)
                // Every square asked for is in `read`, or the answer threw.
                guard let square = read[place.square] else { return nil }
                // Sea is at sea level.
                guard let file = square else { return 0 }
                return file.height(at: place.index)
            } ?? .nan
        }
    }
}

// MARK: - Reading the squares

nonisolated extension ElevationSquareLibrary {
    /// Every square of `squares`, downloaded, kept or fetched: a file, or
    /// `nil` for sea. Throws when any of them cannot be had.
    private func files(of squares: [ElevationSquare]) async throws -> [ElevationSquare: ElevationSquareFile?] {
        var read = held(squares)
        let missing = squares.filter { read[$0] == nil }
        guard !missing.isEmpty else { return read }

        let names = missing.map(ElevationSquareGrid.recordName(for:))
        let fetch: TrailCellFetch
        do {
            fetch = try await database.fetch(cellsNamed: names)
        } catch {
            try Task.checkCancellation()
            Self.logger.error(
                "The elevation squares could not be reached: \(error.localizedDescription, privacy: .public)"
            )
            throw CuratedElevationFailure.unreachable
        }
        switch fetch.manifest {
        case .complete: break
        case .absent, .partial: throw CuratedElevationFailure.uncovered
        case .unread: throw CuratedElevationFailure.unreachable
        }

        var fresh: [(name: String, bytes: Data)] = []
        for (square, name) in zip(missing, names) {
            switch fetch.cells[name] ?? .failed {
            case .found(let bytes):
                // Read before it is kept, so bytes that are not a square are
                // never what the next answer finds on disk.
                guard let file = Self.file(decoding: bytes, as: square) else {
                    Self.logger.error("Elevation square \(name, privacy: .public) is not one this build reads.")
                    throw CuratedElevationFailure.unreachable
                }
                read[square] = .some(file)
                fresh.append((name, bytes))

            case .absent:
                // No tile, in an archive that is the whole world: sea.
                read[square] = .some(nil)
                fresh.append((name, Data()))

            case .failed:
                throw CuratedElevationFailure.unreachable
            }
        }
        store?.save(fresh)
        return read
    }

    /// The squares of `squares` this device holds: those a download brought,
    /// then those kept from earlier answers. A square missing from the
    /// answer is one to fetch.
    private func held(_ squares: [ElevationSquare]) -> [ElevationSquare: ElevationSquareFile?] {
        var read: [ElevationSquare: ElevationSquareFile?] = [:]
        for (square, bytes) in downloads?.elevationSquares(squares) ?? [:] {
            // One that does not read is fetched instead, as a kept one is.
            guard let file = Self.file(decoding: bytes, as: square) else {
                Self.logger.error("A downloaded elevation square is not one this build reads.")
                continue
            }
            read[square] = .some(file)
        }
        for square in squares where read[square] == nil {
            if let kept = kept(square) { read[square] = .some(kept) }
        }
        return read
    }

    /// The square as this device keeps it: `.some(nil)` for sea, `nil` for
    /// one not kept, expired, or no longer readable, which is one to fetch.
    private func kept(_ square: ElevationSquare) -> ElevationSquareFile?? {
        guard let bytes = store?.bytes(ofCellNamed: ElevationSquareGrid.recordName(for: square)) else { return nil }
        guard !bytes.isEmpty else { return .some(nil) }
        return Self.file(decoding: bytes, as: square).map { .some($0) }
    }

    /// `bytes` as a square of `square`'s size, or `nil`: a file of another
    /// size would put its heights on the wrong posts.
    static func file(decoding bytes: Data, as square: ElevationSquare) -> ElevationSquareFile? {
        guard let file = try? ElevationSquareFile(decoding: bytes),
              file.rows == ElevationSquareGrid.rowsPerSquare,
              file.columns == ElevationSquareGrid.columnsPerSquare(row: square.row)
        else { return nil }
        return file
    }
}
