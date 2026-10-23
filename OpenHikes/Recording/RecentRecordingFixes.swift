//
//  RecentRecordingFixes.swift
//  OpenHikes
//
//  The last stretch of the walk the recorder accepted, kept with its
//  timestamps so a photograph can be put where the hiker stood when its
//  shutter fired rather than where they stand when it is handed over.
//
//  The camera does not deliver a picture at the shutter. It shows the shot for
//  review first, and Use Photo is tapped whenever the hiker gets round to it —
//  see ``CameraCaptureMetadata``. The recorder's last accepted fix is where the
//  hiker is at that tap, which after a minute of walking is not where the
//  picture was taken (#970). The fixes accepted in between are what say where
//  it was, and the draft `Hike`'s route cannot: it is written only when the
//  recording stops.
//
//  Bounded by time rather than kept whole. The journal already holds the whole
//  walk on disk; what is needed in memory is only as far back as a review
//  screen is ever left up. A shutter further back than ``retention`` is not
//  answered at all — see
//  ``PhotoTrailAnchor/recordingCoordinate(atShutter:recent:latest:)`` — because
//  the fixes either side of it have been let go, and the oldest one kept would
//  otherwise pass for the start of the walk.
//

import DequeModule
import Foundation

nonisolated struct RecentRecordingFixes: Sendable {
    /// How far behind the newest fix the oldest one kept may be.
    ///
    /// Half an hour is far longer than anyone leaves the camera's review
    /// screen up, and at the recorder's densest — a fix a second — it is a few
    /// hundred kilobytes.
    static let retention: TimeInterval = 30 * 60

    /// Oldest first, in the order the recorder accepted them. Drained from the
    /// front as the walk goes on, so a `Deque`.
    private var storage: Deque<RecordingPoint> = []

    /// The fixes kept, oldest first. A copy, made once per photo.
    var points: [RecordingPoint] { Array(storage) }

    /// Adds a fix the recorder has just accepted, and lets go of the ones it
    /// has walked out of range of.
    ///
    /// The `.resumed` flag travels with the fix, so a pause between two kept
    /// fixes is still a pause to ``HikePhotoTimeline``; dropping the fix that
    /// carried one only ever drops a boundary with nothing kept before it.
    mutating func append(_ point: RecordingPoint) {
        storage.append(point)
        let horizon = point.timestamp.addingTimeInterval(-Self.retention)
        while let oldest = storage.first, oldest.timestamp < horizon {
            storage.removeFirst()
        }
    }

    /// Starts again from a walk rebuilt from the journal — a recovery, or a
    /// merge of the widget's fixes.
    mutating func replace(with walk: [RecordingPoint]) {
        storage = []
        guard let newest = walk.last else { return }
        let horizon = newest.timestamp.addingTimeInterval(-Self.retention)
        storage.append(contentsOf: walk.drop(while: { $0.timestamp < horizon }))
    }

    mutating func removeAll() {
        storage = []
    }
}
