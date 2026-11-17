//
//  TrailWalkSession+OffTrail.swift
//  OpenHikes
//
//  A hiker who has left the trail they are walking is asked what they mean by
//  it: go on following the trail, or record their own hike instead. Split
//  from the session for length, like its route edits.
//
//  ## When it is asked
//
//  When the *Off the trail* banner is first tried, and for the same
//  departure: ``MovementReminderController`` decides both from one rule, off
//  the trail by ``MovementReminderPolicy/offTrailMeters`` for
//  ``MovementReminderPolicy/offTrailDwell``, once until the hiker is back on
//  it. So a hiker who answers *Keep Following* is not asked again while they
//  stay off the trail, and one who rejoins it and leaves again is. The
//  question stands until it is answered, the hiker is back on the trail, or
//  the walk is paused or over: it is raised with the phone in a pocket as
//  often as in a hand, and is what the app shows when it is next looked at.
//  It is kept by this launch alone; a relaunch asks again with the banner.
//
//  ## Recording instead
//
//  A walk and a recording never run together, so the walk ends first, as End
//  ends it: kept in the trail's History when it covered enough. It ends where
//  it was last on its trail, not at the tap, because the question can wait
//  for hours and a walk along a trail is over where its hiker left the trail.
//  What it covered goes to the recording as the points it begins with — see
//  ``RecordingSeed/carrying(_:along:)`` — and those are clocked over the very
//  time the History's row spans, which is what keeps the library's totals
//  from counting that ground twice (`LibraryTotals`).
//

import Foundation
import OpenHikesData

/// What a hiker who has left the trail they are walking is asked about.
struct OffTrailQuestion: Equatable {
    let hikeID: UUID
    /// The trail's name when the question was raised, for the reason
    /// ``TrailWalkStartNotice`` keeps one: the alert reads nothing of the
    /// hike.
    let trailTitle: String
}

extension TrailWalkSession {
    /// Has the reminders say when to ask, and when the question is over — see
    /// ``MovementReminderController/offTrailQuestionDidChange``.
    func listenForOffTrailQuestion() {
        reminders?.offTrailQuestionDidChange = { [weak self] isAsked in
            if isAsked {
                self?.askAboutLeavingTrail()
            } else {
                self?.withdrawOffTrailQuestion()
            }
        }
    }

    /// Asks the hiker about the trail they have left. Only of a walk that is
    /// following: a paused walk's hiker is somewhere else on purpose.
    func askAboutLeavingTrail() {
        guard let record, record.phase == .following else { return }
        let question = OffTrailQuestion(hikeID: record.hikeID, trailTitle: walkedHikeTitle)
        if offTrailQuestion != question { offTrailQuestion = question }
    }

    /// Takes the question back: the hiker is on the trail again, or has
    /// turned reminders off.
    func withdrawOffTrailQuestion() {
        if offTrailQuestion != nil { offTrailQuestion = nil }
    }

    /// The hiker's *Keep Following*. The walk goes on as it was, and this
    /// departure is not asked about again.
    func keepFollowing() {
        withdrawOffTrailQuestion()
    }
}

// MARK: - Recording instead

extension TrailWalkSession {
    /// Ends the walk under way for a recording that takes over from it, and
    /// hands back what that recording begins with — `nil` for a walk that had
    /// covered nothing, or whose line could not be read.
    ///
    /// A refused end hands back nothing to begin with: the walk is still
    /// under way, and nothing may record beside it.
    func handOffToRecording() async -> (end: TrailWalkEnd, seed: RecordingSeed?) {
        guard let handed = record else { return (.discarded, nil) }
        let seed = await recordingSeed()
        // The line may have been read across a suspension. A walk that ended
        // in it is not there to end, and what it had covered is still what
        // the hiker asked to carry.
        guard let current = record, current.hikeID == handed.hikeID, current.startedAt == handed.startedAt else {
            return (.discarded, seed)
        }
        let end = finish(reason: .ended, at: min(current.lastActivityAt, clock()))
        if case .refused = end { return (end, nil) }
        return (end, seed)
    }

    /// What the walk under way has covered, as the points a recording can
    /// begin with. Read off the main actor: it walks the line, and for a walk
    /// with no profile in hand — one adopted at launch that its hike's screen
    /// has not fed yet — reads it first, in a read of its own.
    func recordingSeed() async -> RecordingSeed? {
        guard let record, let walkedHike, walkedHike.isAttached else { return nil }
        if let walkedProfile {
            return await Self.seed(carrying: record, along: walkedProfile)
        }
        let read = SelectedLine(fetch: lineLooks.fetch).read(of: walkedHike)
        return await Self.seed(carrying: record, alongLineOf: read)
    }

    @concurrent
    nonisolated private static func seed(
        carrying walk: TrailWalkRecord,
        along profile: RouteProfile
    ) async -> RecordingSeed? {
        RecordingSeed.carrying(walk, along: profile)
    }

    /// The same, of the line `read` holds. A line that is no longer the one
    /// the walk is along carries nothing: its distances are another line's.
    @concurrent
    nonisolated private static func seed(
        carrying walk: TrailWalkRecord,
        alongLineOf read: SelectedLine.Read
    ) async -> RecordingSeed? {
        let route = await read.route
        guard !route.isEmpty, walk.isAlong(route) else { return nil }
        return RecordingSeed.carrying(walk, along: RouteProfile(route: route))
    }
}
