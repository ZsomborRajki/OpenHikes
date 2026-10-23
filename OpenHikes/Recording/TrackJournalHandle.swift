//
//  TrackJournalHandle.swift
//  OpenHikes
//
//  The calls `TrackJournal` makes on its open file, and nothing else.
//
//  A seam for the suites, not an indirection the app needs: a short write
//  under storage pressure, or a `synchronize()` that fails after the bytes
//  went out, cannot be produced on demand from a real disk, and those are
//  the two failures the journal has to roll back from. `FileHandle` is the
//  only conformance the app ever opens.
//

import Foundation

nonisolated protocol TrackJournalHandle: AnyObject, Sendable {
    @discardableResult func seekToEnd() throws -> UInt64
    func write(contentsOf data: Data) throws
    func synchronize() throws
    /// Cuts the file to `offset` and leaves the file pointer there, so the
    /// next write lands at the cut.
    func truncate(atOffset offset: UInt64) throws
    func close() throws
}

nonisolated extension FileHandle: TrackJournalHandle {}
