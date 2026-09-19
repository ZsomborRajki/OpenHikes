//
//  WatchRecordedWalk.swift
//  OpenHikesShared
//
//  A walk the watch recorded on its own, on its way to becoming a `Hike`.
//
//  ## Finished, not live
//
//  This crosses once, when the hiker stops. There is deliberately no payload
//  for a recording *in progress*, and that is the answer to the question issue
//  #509 raised as the unresolved one — which side owns the recording.
//
//  It is owned by whichever side started it, and only ever one side at a time.
//  A watch recording is the watch's from the first fix to the last: the phone's
//  `HikeRecorder` is never told about it, never enters a phase for it, and has
//  no draft to recover for it. Streaming a live one to the phone would make
//  both of them able to answer "is a hike being recorded?", and the repository
//  instructions already say what that costs — the recorder is the single
//  authority precisely because the widget, the Live Activity and the recording
//  screen all read it and a fourth answer kept beside them could only ever
//  disagree. A finished walk arriving as a track to import is not a fourth
//  answer; it is the same thing an imported GPX is.
//
//  ## What it does and does not carry
//
//  Every fix the watch accepted, with the timestamps, so the phone can rebuild
//  distance, climb and duration from the track rather than trusting figures it
//  cannot check. The watch's own totals ride along anyway, because they are
//  what the hiker was *shown* while walking and a hike that reads differently
//  the moment it lands on the phone is a hike the hiker will not trust.
//  `WatchWalkImport` on the phone is where the two are reconciled, and it
//  prefers the track.
//
//  Pauses cross as the flag on the fix that *ended* one, which is the same
//  convention `RouteBoundary` uses on the phone — a boundary describes the
//  stretch leading to the point that carries it. That is what lets the saved
//  route say "nothing was meant to be observed here" across a pause rather
//  than drawing a straight line through ground nobody walked.
//

import Foundation

/// One accepted fix from a watch recording.
public struct WatchRecordedFix: Codable, Sendable, Equatable {
    public var latitude: Double
    public var longitude: Double
    public var elevationMeters: Double?
    public var timestamp: Date
    public var horizontalAccuracy: Double
    /// Whether the stretch leading to this fix is a pause the hiker took,
    /// rather than ground they walked. See this file's header.
    public var resumesAfterPause: Bool

    public init(
        latitude: Double,
        longitude: Double,
        timestamp: Date,
        horizontalAccuracy: Double,
        elevationMeters: Double? = nil,
        resumesAfterPause: Bool = false
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.timestamp = timestamp
        self.horizontalAccuracy = horizontalAccuracy
        self.elevationMeters = elevationMeters
        self.resumesAfterPause = resumesAfterPause
    }
}

/// A finished watch recording, as it crosses to the phone.
public struct WatchRecordedWalk: SharedPayload, Equatable, Identifiable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int

    /// Stable for the life of the recording and reused on every retry, which
    /// is what makes the phone's import idempotent: a transfer the watch could
    /// not confirm is sent again, and the second arrival is recognised rather
    /// than saved twice. See `WatchWalkImport`.
    public var sessionID: UUID
    /// The trail the hiker was following while they recorded, if any. Carried
    /// so the phone can name the walk after it; it does **not** make this a
    /// walk along that trail in the `HikeWalk` sense, which is a coverage
    /// figure only the phone's matcher can produce.
    public var trailHikeID: UUID?
    /// What the watch called it — the followed trail's name, or `nil` for a
    /// free recording, which the phone names the way it names any other.
    public var title: String?
    public var startedAt: Date
    public var endedAt: Date
    /// The watch's own running total, which is the figure the hiker watched.
    public var distanceMeters: Double
    /// The walk's clock with its pauses taken out.
    public var activeSeconds: TimeInterval
    public var elevationGainMeters: Double?
    public var elevationLossMeters: Double?
    public var fixes: [WatchRecordedFix]

    public var id: UUID { sessionID }

    public init(
        sessionID: UUID,
        startedAt: Date,
        endedAt: Date,
        distanceMeters: Double,
        activeSeconds: TimeInterval,
        fixes: [WatchRecordedFix],
        trailHikeID: UUID? = nil,
        title: String? = nil,
        elevationGainMeters: Double? = nil,
        elevationLossMeters: Double? = nil
    ) {
        self.sessionID = sessionID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.distanceMeters = distanceMeters
        self.activeSeconds = activeSeconds
        self.fixes = fixes
        self.trailHikeID = trailHikeID
        self.title = title
        self.elevationGainMeters = elevationGainMeters
        self.elevationLossMeters = elevationLossMeters
        schemaVersion = Self.currentSchemaVersion
    }

    /// Whether this is worth sending at all.
    ///
    /// Two points, because one is a place rather than a walk and the phone
    /// would save a hike with no line. A recording the hiker stopped before
    /// their watch had a second fix is discarded on the watch, where they can
    /// still be told so, rather than crossing to become a row they have to
    /// find and delete.
    public var isWorthKeeping: Bool { fixes.count > 1 }
}

/// The phone confirming it has the walk, so the watch can stop holding it.
///
/// Its own payload rather than an empty reply, because the watch has to know
/// *which* walk was kept: a queue can hold more than one when the phone has
/// been out of range, and transfers do not come back in the order they were
/// sent.
public struct WatchWalkReceipt: SharedPayload, Equatable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public var sessionID: UUID

    public init(sessionID: UUID) {
        self.sessionID = sessionID
        schemaVersion = Self.currentSchemaVersion
    }
}
