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
//  And it is asked once more, saying so, when *Record Instead* could not be
//  done: the departure has already been asked about, so nothing else would
//  ask, and the hiker who wanted the hike so far in a recording would be
//  left with End, which carries nothing.
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
//  The points are built off the main actor, from the walk's line, which a
//  walk adopted at launch has to read first. The walk goes on meanwhile: a
//  fix can match, the walk can end, and another can begin. So the points and
//  the row are made from one state of the walk, with nothing between the
//  last look at it and its end, and the points are built again when a fix
//  moved it on. A walk that ended meanwhile hands over nothing, and its
//  recording begins where the hiker stands, as the record button's does; one
//  that another walk replaced starts no recording, because nothing records
//  beside a walk. A line that could not be read ends nothing: the walk is
//  left under way to be tried again, rather than ended with its ground in
//  the recording and, under the History's minimum, nowhere at all. Neither
//  does an end the store refused, and both ask the question again.
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
    /// Whether this is the question asked again because *Record Instead*
    /// could not be done, which the alert says: the walk is still under way.
    var handOffFailed = false
}

/// What handing the walk under way to a recording came to — see
/// ``TrailWalkSession/handOffToRecording()``.
enum WalkHandOff {
    /// The walk ended, as the ``TrailWalkEnd`` says, a refusal included, and
    /// this is what a recording that takes over begins with: `nil` for a walk
    /// that had covered nothing, and for one the store would not end — which
    /// is still under way, and asked about again.
    case ended(TrailWalkEnd, seed: RecordingSeed?)
    /// The walk's line could not be read, so nothing was ended: the walk is
    /// still under way, and the question is asked again for the hiker to try
    /// again.
    case lineUnreadable
    /// There was no walk to hand over: none was under way, or the one asked
    /// about ended on its own while its line was read, and is in its trail's
    /// History by that end. A recording begins with nothing.
    case noWalk
    /// Another walk took the place of the one asked about while its line was
    /// read. Nothing may record beside it.
    case overtaken
}

/// The line a walk is along, read for what it covered to be carried on.
nonisolated enum CarriedLine: Sendable {
    case along(RouteProfile)
    /// No line to carry along: the row is gone, or its line is no longer the
    /// one the walk is along, and its distances are another line's.
    case nothing
    /// The fetch failed, which says nothing about the line.
    case unreadable
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
    /// hands back what that recording begins with — see ``WalkHandOff``.
    ///
    /// The walk is looked at again after every suspension, because it goes
    /// on through them: see *Recording instead* in the file header. The loop
    /// ends at the first build no fix overtook, which is the first, unless a
    /// fix landed in the milliseconds the points took.
    func handOffToRecording() async -> WalkHandOff {
        guard let asked = record else { return .noWalk }
        let line = await carriedLine()
        var walk = asked
        var seed: RecordingSeed?
        repeat {
            guard let current = record else { return .noWalk }
            guard current.hikeID == asked.hikeID, current.startedAt == asked.startedAt else { return .overtaken }
            walk = current
            switch line {
            case .unreadable:
                askAgainAfterFailedHandOff()
                return .lineUnreadable
            case .nothing: seed = nil
            case let .along(profile): seed = await Self.seed(carrying: walk, along: profile)
            }
        } while record != walk
        // Nothing between the look above and the end: the points and the
        // row describe one walk.
        let end = finish(reason: .ended, at: min(walk.lastActivityAt, clock()))
        if case .refused = end {
            askAgainAfterFailedHandOff()
            return .ended(end, seed: nil)
        }
        return .ended(end, seed: seed)
    }

    /// Asks again about the trail the hiker left, saying their *Record
    /// Instead* could not be done: the walk is still under way, so they can
    /// try again, and *Keep Following* still changes nothing. See *When it is
    /// asked* in the file header.
    private func askAgainAfterFailedHandOff() {
        guard let record else { return }
        offTrailQuestion = OffTrailQuestion(hikeID: record.hikeID, trailTitle: walkedHikeTitle, handOffFailed: true)
    }

    /// The line the walk under way is along: the profile in hand, or — for a
    /// walk adopted at launch that its hike's screen has not fed yet — the
    /// line read off the main actor, in a read of its own.
    func carriedLine() async -> CarriedLine {
        guard let record, let walkedHike, walkedHike.isAttached else { return .nothing }
        if let walkedProfile { return .along(walkedProfile) }
        let read = SelectedLine(fetch: lineLooks.fetch).read(of: walkedHike)
        return await Self.line(of: read, along: record)
    }

    @concurrent
    nonisolated private static func line(of read: SelectedLine.Read, along walk: TrailWalkRecord) async -> CarriedLine {
        if await read.failed { return .unreadable }
        let route = await read.route
        guard !route.isEmpty, walk.isAlong(route) else { return .nothing }
        return .along(RouteProfile(route: route))
    }

    /// What `walk` covered, as the points a recording can begin with. Off the
    /// main actor, because it walks the line.
    @concurrent
    nonisolated private static func seed(
        carrying walk: TrailWalkRecord,
        along profile: RouteProfile
    ) async -> RecordingSeed? {
        RecordingSeed.carrying(walk, along: profile)
    }
}
