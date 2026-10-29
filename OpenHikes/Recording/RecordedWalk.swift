//
//  RecordedWalk.swift
//  OpenHikes
//
//  The walk a saved recording *was*, and how the recorder writes it down.
//
//  Every other `HikeWalk` is accrued fix by fix along a trail that already
//  existed — `TrailWalkSession` starts one on a matched fix and closes it into
//  a row. A recording has no such trail to be matched against: it *is* the
//  route, and the walk along it is finished by the time there is anything to
//  match. So the row is written once, at the moment the recording becomes a
//  `Hike`, out of what the recorder prepared from the journalled points.
//
//  Coverage is the whole of the route by construction, which is not a claim
//  about the hiker so much as a statement of what the route is: the line was
//  drawn by walking it. What the row is *for* is the History segment, where a
//  recorded hike used to have nothing to show and now leads with the walk that
//  made it, above whatever follows were made along it afterwards.
//
//  Both figures the row is measured by come from the prepared geometry rather
//  than from the clock or the journal's metadata, and for the same reason in
//  each case: the points are the only record of the walk that cannot say
//  something the recorder never watched happen. See
//  ``PreparedRecording/routeLengthMeters`` and
//  ``PreparedRecording/recordedSeconds``.
//

import Foundation
import OpenHikesData
import SwiftData

extension HikeWalk {
    /// The row a finished recording leaves in its own History, or `nil` when
    /// the recording is not one a walk can be measured against.
    ///
    /// `nil` on two counts, and neither is a failure: a session with no
    /// `endedAt` was never finished, so it has no walk to write down yet, and
    /// a route of no length gives coverage nothing to be a fraction *of* —
    /// ``TrailWalkSession`` declines to start a walk on the same grounds.
    ///
    /// Deliberately not held to ``TrailWalkPolicy/minimumCoverageMeters``,
    /// which every followed walk is. That rule exists so opening a trail at
    /// the trailhead for a look leaves no row behind; a recording the hiker
    /// stopped and saved is never that glance, and a hike whose History
    /// disowned it would be the one hike in the list unable to say where it
    /// came from.
    static func recorded(
        _ metadata: TrackJournalMetadata,
        prepared: PreparedRecording
    ) -> HikeWalk? {
        guard let endedAt = metadata.endedAt else { return nil }
        // The route's own length rather than the hike's distance: see
        // ``PreparedRecording/routeLengthMeters`` for why the two differ and
        // why coverage has to be written on this one.
        let routeLength = prepared.routeLengthMeters
        guard routeLength > 0 else { return nil }
        return HikeWalk(
            hikeID: metadata.sessionID,
            startedAt: prepared.startedAt,
            endedAt: endedAt,
            // `startedAt` and `endedAt` still bound the walk, which is what
            // the summary's Started and Ended read; they are just not what its
            // active time is measured from — see
            // ``PreparedRecording/recordedSeconds``.
            activeSeconds: prepared.recordedSeconds,
            // One interval covering the whole route, which is the union a
            // walk along this line could ever have reached — written low to
            // high, because a recording's route is stored the way it was
            // walked.
            coveredIntervals: [0, routeLength],
            furthestDistanceMeters: routeLength,
            routeDistanceMeters: routeLength,
            endReason: .recorded,
            // The line the hike is saved with, so the History can tell this
            // walk's stretches from an edit made to it later.
            routeRevision: TrailWalkRecord.routeRevision(of: prepared.route)
        )
    }
}

extension HikeRecorder {
    /// Writes the recording's own walk beside the hike being saved, and hands
    /// the row back so a refused commit can take it away again.
    ///
    /// Inserted rather than saved: the row and the finalized hike land in one
    /// `save`, the way ``TrailWalkSession`` lands a closing walk and its
    /// cleared sidecar column together. A second save here would be a window
    /// in which a process that exited left a walk row pointing at a hike still
    /// marked as recording.
    func insertRecordedWalk(
        for hike: Hike,
        session: TrackJournalSession,
        prepared: PreparedRecording
    ) -> HikeWalk? {
        // Only ever reached for a draft being finalized — `persist` returns an
        // already-saved hike before this — so a second row for one recording
        // cannot be written, and no lookup is needed to rule one out.
        guard let walk = HikeWalk.recorded(session.metadata, prepared: prepared) else { return nil }
        container.mainContext.insert(walk)
        walk.hike = hike
        return walk
    }

    /// Takes the inserted row back by hand, for a save the store refused.
    ///
    /// By hand rather than through `ModelContext.rollback()`, for the reason
    /// ``TrailWalkSession`` gives where it undoes a walk row and a sidecar
    /// column: a rollback would also discard every other pending edit in this
    /// shared main context. The caller puts its own fields back by hand too,
    /// which a rollback would not have done on the iOS 18 floor either. And
    /// on iOS 27.0 a rollback of this pair — the draft's columns, and a walk
    /// row related to it — left the draft's walks unreadable: measured, the
    /// next read of them trapped inside SwiftData.
    func discardRecordedWalk(_ walk: HikeWalk?) {
        guard let walk else { return }
        walk.hike = nil
        container.mainContext.delete(walk)
    }
}
