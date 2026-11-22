//
//  TrailCellFetching.swift
//  OpenHikes
//
//  What the tile server is asked about the pre-built squares, and the three
//  different things it can mean by not having one.
//
//  A search names the squares it needs — see ``TrailCellGrid/cells(reaching:)``
//  — and asks for them, and with them what the squares cover. That rides
//  along every time because a square that is not there is ambiguous without
//  it, and the two readings are opposite sentences to a hiker:
//
//  - the squares are **the whole world** and this one has no routes in it,
//    which is an answer: *no OpenStreetMap trails here*;
//  - the squares are **part of the world**, or none have been published at
//    all, and nothing is known about this one — which is not an answer, and
//    Overpass is asked as it always was.
//
//  In part of the world a square that *is* there is no answer either: a
//  regional build leaves out the routes that run out of its extract, and
//  ``TrailCellLibrary`` reads none of its squares for that reason.
//
//  On the tile server the first reading is an archive its manifest lists,
//  because only a build of the whole planet goes up, and the second is none
//  listed that this build reads (``SquareArchiveServer``). The public
//  database, which builds before this one read, said so in a manifest record
//  of its own, and a regional build could be uploaded there to try the
//  upload; ``Manifest/partial`` is that record's other answer. Either way
//  it is what lets a build of the app ship before the squares do: until the
//  squares are known to be complete, every search is asked the old way.
//
//  A protocol for the reason ``CuratedTrailSourcing`` is one. The conformance
//  that reaches the server is ``SquareArchiveServer``, and no suite may
//  build it with a live transport — see *A suite must never reach the real
//  transport* in the repository instructions.
//

import Foundation

/// What one request about some squares came back with.
nonisolated struct TrailCellFetch: Equatable, Sendable {
    /// What the squares' source says they cover.
    nonisolated enum Manifest: Equatable, Sendable {
        /// No squares are published that this build reads: none are, or the
        /// first upload of them is still under way.
        case absent
        /// The squares are the whole world, so a square that is not there is
        /// a square with no routes.
        case complete
        /// The squares are part of the world, so nothing is known from them:
        /// a square that is not there may hold routes, and one that is may
        /// hold more than it lists.
        case partial
        /// What the squares cover could not be read, which is not the same as
        /// there being none.
        case unread
    }

    /// What the source says about one square.
    nonisolated enum Cell: Equatable, Sendable {
        /// There is no square under the name.
        case absent
        /// There may be one, and it could not be read.
        case failed
        /// The square's ``TrailCellFile``, as bytes.
        case found(Data)
    }

    var manifest: Manifest
    /// One entry for each square that was asked about. A name missing from
    /// here is read as ``Cell/failed``.
    var cells: [String: Cell]
}

/// Where the pre-built squares are fetched from.
nonisolated protocol TrailCellFetching: Sendable {
    /// The squares filed under `names` — ``TrailCellGrid/recordName(for:)`` —
    /// and what the source says they cover, in one request.
    ///
    /// Throws when the request as a whole fails; a square that could not be
    /// read while others could is ``TrailCellFetch/Cell/failed`` in the
    /// answer.
    @concurrent
    func fetch(cellsNamed names: [String]) async throws -> TrailCellFetch
}
