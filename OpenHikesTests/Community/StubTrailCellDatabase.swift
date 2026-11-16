//
//  StubTrailCellDatabase.swift
//  OpenHikesTests
//
//  What a suite's trail squares are fetched from instead of the public
//  database, and the squares themselves.
//
//  Its own file because every set of squares is fetched through
//  ``TrailCellFetching``, so the suites of all four drive it: the day
//  hikes', the places', the trail graph's and the hiking-routes layer's.
//  The squares here are the day hikes'.
//

import Foundation
@testable import OpenHikes
import Synchronization

/// What the squares are fetched from instead of CloudKit.
///
/// A stub for the reason ``StubCuratedTrailSource`` is one: the real
/// conformance reaches the public database, and no suite may. See
/// ``TrailCellFetching``.
///
/// `final class` behind a `Mutex` rather than an actor, for the reason that
/// stub gives: the requirement is `@concurrent`, so calls arrive off the main
/// actor, and an actor would make every read of what was asked a suspension
/// the next request could overtake.
nonisolated final class StubTrailCellDatabase: TrailCellFetching, Sendable {
    private struct State {
        var requests: [[String]] = []
        var manifest: TrailCellFetch.Manifest
        var cells: [String: TrailCellFetch.Cell]
        var failure: (any Error)?
        var cancelsCaller = false
        var answersCancelledCaller = false
    }

    private let state: Mutex<State>

    /// - Parameter cells: What the database holds, by record name. A square
    ///   asked about and not named here is one it has no record of.
    init(manifest: TrailCellFetch.Manifest = .complete, cells: [String: TrailCellFetch.Cell] = [:]) {
        state = Mutex(State(manifest: manifest, cells: cells))
    }

    /// The names each request asked about, in order.
    var requests: [[String]] { state.withLock { $0.requests } }

    /// Makes every request from here on fail as a whole, the way a phone
    /// with no signal makes one fail.
    func fail(with error: any Error) {
        state.withLock { $0.failure = error }
    }

    /// Changes what the database holds under `name`, as an upload would.
    func hold(_ cell: TrailCellFetch.Cell, as name: String) {
        state.withLock { $0.cells[name] = cell }
    }

    /// Makes every request from here on end the way a superseded search's
    /// does: the task that asked is cancelled while the request is out.
    ///
    /// Cancelled from in here rather than by the case, so there is no moment
    /// at which the request has failed and the task has not yet been told —
    /// which is the moment that would decide the case by a race.
    ///
    /// So a case runs the search in a task of its own and awaits its value.
    /// Awaited in the case's own task, the search cancels the case, which
    /// Swift Testing then reports as skipped rather than passed.
    ///
    /// - Parameter answering: Whether the request answers all the same, as
    ///   one that finished before it heard can, rather than failing.
    func cancelCallers(answering: Bool = false) {
        state.withLock { state in
            state.cancelsCaller = true
            state.answersCancelledCaller = answering
        }
    }

    @concurrent
    func fetch(cellsNamed names: [String]) async throws -> TrailCellFetch {
        let asked = state.withLock { state in
            state.requests.append(names)
            return state
        }
        await Task.yield()
        if asked.cancelsCaller {
            withUnsafeCurrentTask { $0?.cancel() }
            if !asked.answersCancelledCaller { throw CancellationError() }
        }
        if let failure = asked.failure { throw failure }
        var cells: [String: TrailCellFetch.Cell] = [:]
        for name in names {
            cells[name] = asked.cells[name] ?? .absent
        }
        return TrailCellFetch(manifest: asked.manifest, cells: cells)
    }
}

/// Squares for a suite to hand ``StubTrailCellDatabase``.
nonisolated enum TrailCellFixture {
    /// A point as a square stores one, from degrees.
    static func point(_ latitude: Double, _ longitude: Double) -> TrailCellFile.Point {
        let scale = Double(TrailCellFile.standardCoordinateScale)
        return TrailCellFile.Point(
            latitude: Int32((latitude * scale).rounded()),
            longitude: Int32((longitude * scale).rounded())
        )
    }

    /// A relation of one way in the main role, which is all most cases read.
    static func relation(
        _ id: Int64,
        name: String,
        from start: TrailCellFile.Point,
        to end: TrailCellFile.Point
    ) -> TrailCellFile.Relation {
        TrailCellFile.Relation(
            id: id,
            tags: ["name": name, "route": "hiking"],
            ways: [TrailCellFile.Way(role: "", points: [start, end])]
        )
    }

    /// A square holding `relations`, as the bytes its record's asset carries.
    static func found(_ relations: [TrailCellFile.Relation]) -> TrailCellFetch.Cell {
        .found(TrailCellFile(relations: relations).encoded())
    }

    /// The record name of the square that holds a point.
    static func name(at latitude: Double, _ longitude: Double) -> String {
        TrailCellGrid.recordName(
            for: TrailCellGrid.cell(containingLatitude: latitude, longitude: longitude)
        )
    }
}
