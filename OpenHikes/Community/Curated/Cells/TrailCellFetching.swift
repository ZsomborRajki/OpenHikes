//
//  TrailCellFetching.swift
//  OpenHikes
//
//  What the public database is asked about the pre-built squares, and the
//  three different things it can mean by not having one.
//
//  A search names the squares it needs — see ``TrailCellGrid/cells(reaching:)``
//  — and asks for them, and for the manifest, in one request. The manifest
//  rides along every time because a square that is not there is ambiguous
//  without it, and the two readings are opposite sentences to a hiker:
//
//  - the squares are **the whole world** and this one has no routes in it,
//    which is an answer: *no OpenStreetMap trails here*;
//  - the squares are **part of the world**, or none have been published in
//    this environment at all, and nothing is known about this one — which is
//    not an answer, and Overpass is asked as it always was.
//
//  That second reading is also what lets a build of the app ship before the
//  squares do, and lets a regional build be tried in development: until a
//  manifest says the squares are complete, a missing one only ever means *ask
//  the old way*.
//
//  A protocol for the reason ``CuratedTrailSourcing`` is one. The conformance
//  that reaches CloudKit is ``CloudKitTrailCellDatabase``, and no suite may
//  build it — see *A suite must never reach the real transport* in the
//  repository instructions.
//

import Foundation

/// What one request about some squares came back with.
nonisolated struct TrailCellFetch: Equatable, Sendable {
    /// What the database says its squares cover.
    nonisolated enum Manifest: Equatable, Sendable {
        /// There is no manifest: no squares are published here, or the first
        /// upload of them is still under way.
        case absent
        /// The squares are the whole world, so a square with no record is a
        /// square with no routes.
        case complete
        /// The squares are part of the world, so a square with no record is
        /// one nothing is known about.
        case partial
        /// The manifest could not be read, which is not the same as there
        /// being none.
        case unread
    }

    /// What the database says about one square.
    nonisolated enum Cell: Equatable, Sendable {
        /// There is no record under the square's name.
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
    /// and what the manifest says of them, in one request.
    ///
    /// Throws when the request as a whole fails; a square that could not be
    /// read while others could is ``TrailCellFetch/Cell/failed`` in the
    /// answer.
    @concurrent
    func fetch(cellsNamed names: [String]) async throws -> TrailCellFetch
}
