//
//  RecordingSeed.swift
//  OpenHikes
//
//  What a recording begins with when it takes over from a hike already under
//  way, and how the recorder takes it.
//
//  A recording used to begin with nothing: Start, then the first fix. A hiker
//  who left the trail they were following and chose to record instead would
//  then have a recording that began where they left it, and the part of the
//  day they had already walked would be in the trail's History and nowhere in
//  the hike they came home with. So a recording can be handed the ground
//  already covered — see ``RecordingSeed/carrying(_:along:)`` for how a walk
//  along a trail becomes one — and from there it is a recording like any
//  other.
//
//  The points go into the journal with the session, in the one call that
//  starts it, so a crash a moment later recovers a recording that has them:
//  there is no second write to lose. What the recorder then does with them is
//  what recovery does with a journal it found, for the same reason — the
//  points are the record, and the live state is rebuilt from them rather than
//  kept beside them.
//
//  A seed is one start's, and one handoff's. The walk it came from was ended
//  before the recording was asked for, into its trail's History only when it
//  had covered enough to be kept there, so a start that fails before a
//  session takes the seed (precise location refused, a journal that will not
//  open) would leave the ground walked nowhere at all. The recorder keeps it
//  then, as ``HikeRecorder/unclaimedSeed``, and the recording screen's Start,
//  where that failure is explained, tries the handoff again with it. Any
//  other start, the map's button or Siri, is a recording of its own and
//  begins where the hiker stands; it, or any session that starts, lets the
//  walk go.
//

import Foundation
import OpenHikesShared

/// The points a recording begins with, and when the hike they belong to began.
nonisolated struct RecordingSeed: Equatable, Sendable {
    /// When the hike began, which the recording takes as its own start: its
    /// date, its default name and the clock on its screen all count from here.
    let startedAt: Date
    /// The ground already covered, oldest first and each later than the one
    /// before. A point that opens a stretch the hike did not reach from the
    /// one before it carries ``RecordingPointFlags/resumed``, which is how a
    /// recording says the same of its own pauses.
    let points: [RecordingPoint]
}

extension HikeRecorder {
    /// Starts a recording that begins with `seed`, or an ordinary one when
    /// there is nothing to carry.
    ///
    /// The seed waits on the recorder for as long as the start does — the
    /// permission prompt and the precision sheet are the hiker's to answer —
    /// and is taken by the activation that makes the session.
    func start(carrying seed: RecordingSeed?) async {
        // As `start()` clears a refusal with no session behind it, and here
        // before the seed is kept, because that clearing lets go of one.
        if case .failed = phase, sessionID == nil {
            resetSession()
        }
        guard phase == .idle else { return }
        // A retry hands the unclaimed walk back in as `seed`; any other start
        // is a recording of its own, which the walk is not part of.
        unclaimedSeed = nil
        carriedSeed = seed.flatMap { carried in carried.points.isEmpty ? nil : carried }
        await start()
    }

    /// Takes the session just made on from the points it was started with,
    /// which are already in its journal. Nothing to do for a start that
    /// carried none.
    ///
    /// What ``recoverOpenSession(automaticallyResume:)`` does with the points
    /// it reads back, less the two things that are about a launch: there is
    /// nothing to decide, and the sensors were started a line ago.
    func adoptCarriedSeed(_ seed: RecordingSeed?) {
        guard let seed, let last = seed.points.last else { return }
        carriedSeed = nil
        lastAcceptedPoint = last
        // A fix taken before the last carried point is the hike's own past,
        // and the points already say where the hiker was then. One taken
        // since is the first news of where they went next, however long ago
        // the recording was asked for.
        fixWindow = RecordingFixWindow(opensAt: last.timestamp)
        // The clock on the recording's screen counts from when the hike
        // began, not from this hand-off.
        sessionUptimeBase = uptime() - max(0, clock().timeIntervalSince(seed.startedAt))
        rebuildLiveState(from: seed.points)
        // The heights carried are the trail's own, and the next fix's would
        // be the receiver's, whose difference is no climb. So the barometer
        // measures on from where the carried line ends, as it does from the
        // last point a recovery or a resume found, with GPS let in slowly.
        // Nothing has read the barometer since the session made it a line ago.
        elevationFilter.restart(at: last.elevation)
        // Where the hike started, not where the recording took over.
        nameStartPlace(at: seed.points.first?.coordinate)
        if phase != .recording {
            phase = .recording
        }
        publishSharedRecordingSnapshot(force: true)
    }
}
