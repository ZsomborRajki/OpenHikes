//
//  TrackJournalSession.swift
//  OpenHikes
//
//  What `TrackJournal` reads back: the session's metadata, written beside the
//  journal as JSON, and the points decoded from its records.
//

import Foundation

nonisolated struct RecordingPauseInterval: Codable, Equatable, Sendable {
    var startedAt: Date
    var endedAt: Date?

    /// Whether `date` falls inside the pause, its two ends left out: the fix
    /// a pause began on and the one it resumed on are both part of the walk.
    /// A pause still open has no end yet.
    func contains(_ date: Date) -> Bool {
        date > startedAt && endedAt.map { date < $0 } ?? true
    }
}

nonisolated struct TrackJournalMetadata: Codable, Equatable, Sendable {
    var sessionID: UUID
    var startedAt: Date
    var endedAt: Date?
    var lastUpdatedAt: Date
    var pausedIntervals: [RecordingPauseInterval]
    var title: String?
}

nonisolated struct TrackJournalSession: Equatable, Sendable {
    var metadata: TrackJournalMetadata
    var points: [RecordingPoint]
}
