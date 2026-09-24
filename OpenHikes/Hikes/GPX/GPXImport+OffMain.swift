//
//  GPXImport+OffMain.swift
//  OpenHikes
//
//  The parser's two entry points for the import, which must not run on the
//  main actor. Split from the parser for length.
//

import Foundation

nonisolated extension GPXImport {
    /// ``loadAll(from:limits:)`` without occupying the main actor — see
    /// ``loadOffMain(from:limits:)`` for what that does and does not buy.
    @concurrent
    static func loadAllOffMain(
        from url: URL,
        limits: Limits = .standard
    ) async throws(ImportFailure) -> Contents {
        assertOffMainThread(
            "GPX parsing and route preparation must stay off the main thread"
        )
        return try loadAll(from: url, limits: limits)
    }

    /// Parses and prepares a picked file without occupying the main actor.
    ///
    /// `@concurrent` rather than a detached task: the parse stays inside the
    /// importing task's tree, and the caller's priority carries through
    /// instead of being pinned here.
    ///
    /// What that does not buy is cancellation. `XMLParser.parse()` is
    /// synchronous and checks nothing, so abandoning the import abandons the
    /// *result* — the parse runs to completion regardless. What bounds it is
    /// ``Limits``: the file-size check before this, and the point ceiling the
    /// delegate aborts on.
    @concurrent
    static func loadOffMain(
        from url: URL,
        limits: Limits = .standard
    ) async throws(ImportFailure) -> Track {
        assertOffMainThread(
            "GPX parsing and route preparation must stay off the main thread"
        )
        return try load(from: url, limits: limits)
    }
}
