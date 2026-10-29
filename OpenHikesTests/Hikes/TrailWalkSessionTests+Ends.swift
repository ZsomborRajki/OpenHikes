//
//  TrailWalkSessionTests+Ends.swift
//  OpenHikesTests
//
//  What an end has to be, and what it must not quietly undo.
//
//  Split from `TrailWalkSessionTests` because that suite had reached its
//  length, and because these ask a different question from the rest of it.
//  That one asks what a walk *does*; these ask whether an end is one. An End
//  the next matched fix undoes is not a boundary, a commit the store refused
//  is not a record, and the fix that completed a walk is not a fix to publish
//  as a fresh follow.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftData
import Testing

extension TrailWalkSessionTests {
    /// End has to be an end. Without a boundary the next accepted on-route
    /// fix finds no record and simply starts another walk — most visibly for
    /// a walk under the minimum, where End keeps nothing, the detail is still
    /// on screen, and the controls come back on the hiker's next step.
    @Test("End does not auto-start another walk on the next fix")
    func endIsAStableBoundary() {
        let session = session()
        let hike = hike()
        let profile = RouteProfile(route: hike.route)
        walk(session, hike: hike, profile: profile, from: 0, through: 5)
        session.end()
        #expect(session.walkedHikeID == nil)

        clock.advance(by: 60)
        session.recordForegroundMatch(hike: hike, profile: profile, distance: profile.distances[6])
        #expect(session.walkedHikeID == nil, "standing on the route it just ended on is not a new walk")
        #expect(!session.canStart(hike))

        // Leaving the route rearms it: coming back to the trail is a walk of
        // its own.
        session.recordOffRoute(hikeID: hike.id)
        #expect(session.canStart(hike))
        walk(session, hike: hike, profile: profile, from: 7, through: 9)
        #expect(session.walkedHikeID == hike.id)
    }

    /// The other way back: asking to follow this trail again.
    @Test("turning following off and on rearms a walk that was ended")
    func followingRearmsAfterAnEnd() {
        let session = session()
        let hike = hike()
        let profile = RouteProfile(route: hike.route)
        walk(session, hike: hike, profile: profile, from: 0, through: 5)
        session.end()
        #expect(!session.canStart(hike))

        hike.autoFollowEnabled = false
        session.autoFollowDidChange(hikeID: hike.id, enabled: false)
        #expect(session.hasEndedWalk(hikeID: hike.id), "turning following off must preserve the End boundary")
        hike.autoFollowEnabled = true
        session.autoFollowDidChange(hikeID: hike.id, enabled: true)

        #expect(session.canStart(hike))
    }

    /// A saved recording is an end too. The hiker is standing on the last
    /// point of the line they just drew, so without the hold the saved hike's
    /// detail matches the next fix and starts a second walk along it.
    @Test("a just-saved recording does not auto-start a walk until the hiker leaves it")
    func savedRecordingHoldsTheStart() {
        let session = session()
        let hike = hike()
        let profile = RouteProfile(route: hike.route)
        session.recordingDidSave(hikeID: hike.id)

        let last = profile.coordinates.count - 1
        session.recordForegroundMatch(hike: hike, profile: profile, distance: profile.distances[last])
        #expect(session.walkedHikeID == nil, "standing where the recording ended is not a new walk")
        #expect(session.startNotice == nil)
        #expect(session.hasEndedWalk(hikeID: hike.id), "so no follow panel starts over the recording's own")
        #expect(session.canStartByHand(hike), "Start is still a tap away")

        session.recordOffRoute(hikeID: hike.id)
        clock.advance(by: 60)
        startWalk(session, hike: hike, profile: profile, at: 1)
        #expect(session.walkedHikeID == hike.id, "coming back to the trail later is a walk of its own")
    }

    @Test("turning following back on rearms a just-saved recording")
    func followingRearmsAfterASavedRecording() {
        let session = session()
        let hike = hike()
        session.recordingDidSave(hikeID: hike.id)
        #expect(!session.canStart(hike))

        session.autoFollowDidChange(hikeID: hike.id, enabled: true)

        #expect(session.canStart(hike))
    }

    /// A commit the store refuses is not an end. Cleared state and a returned
    /// row would both be lies: the row and the cleared column exist only as
    /// pending edits, so a process that exits there finds a sidecar still
    /// describing an open walk and no row at all.
    @Test("a refused commit leaves the walk under way and says so")
    func refusedCommitKeepsTheWalk() throws {
        let hike = hike()
        let profile = RouteProfile(route: hike.route)
        walk(session(), hike: hike, profile: profile, from: 0, through: 6)
        let open = try #require(hike.walkInProgress)

        let refusing = TrailWalkSession(
            context: context,
            clock: clock.read,
            save: { _ in throw CocoaError(.fileWriteUnknown) }
        )
        refusing.restoreAtLaunch()
        #expect(refusing.walkedHikeID == hike.id, "precondition: it adopted the open walk")

        guard case .refused = refusing.end() else {
            Issue.record("a store that refuses the commit must refuse the end")
            return
        }

        #expect(refusing.walkedHikeID == hike.id, "the walk is still under way")
        #expect(refusing.phase == .following)
        #expect(hike.walkInProgress == open, "and the sidecar still describes it")
        #expect(try walks(of: hike).isEmpty, "with no row left behind")
    }

    /// Nor is it the end of the walk's reminders. Told before the commit that
    /// nobody was following any more, a refused End took down the warnings
    /// standing over a walk that was still under way, and re-armed the
    /// once-per-walk after-dark warning, which the next estimate then said a
    /// second time.
    @Test("a refused commit leaves the walk's reminders standing")
    func refusedCommitKeepsTheReminders() async throws {
        let harness = MovementReminderHarness.harness(clock: clock)
        // Dusk in eight minutes: the rest of this trail takes far longer.
        let dusk = clock.read().addingTimeInterval(8 * 60)
        var refusing = false
        let session = TrailWalkSession(
            context: context,
            reminders: harness.controller,
            clock: clock.read,
            daylight: { _, _ in WeatherDaylight(civilDusk: dusk) },
            save: { store in
                if refusing { throw CocoaError(.fileWriteUnknown) }
                try store.save()
            }
        )
        let hike = hike()
        let profile = RouteProfile(route: hike.route)
        walk(session, hike: hike, profile: profile, from: 0, through: 3)
        await harness.controller.settle()
        #expect(harness.notifier.postedKinds == [.afterDark], "precondition: the walk was warned")
        let withdrawn = harness.notifier.withdrawn

        refusing = true
        guard case .refused = session.end() else {
            Issue.record("a store that refuses the commit must refuse the end")
            return
        }
        await harness.controller.settle()
        #expect(harness.notifier.withdrawn == withdrawn, "the walk is still under way, and so is what it was told")

        refusing = false
        walk(session, hike: hike, profile: profile, from: 4, through: 5)
        await harness.controller.settle()
        #expect(harness.notifier.postedKinds == [.afterDark], "once per walk, and this is still the same walk")

        if case .refused = session.end() {
            Issue.record("a store that accepts the commit ends the walk")
            return
        }
        await harness.controller.settle()
        #expect(harness.notifier.withdrawn.contains(.afterDark), "the end that lands takes the warning down")
    }

    /// The other once-only warning. Told before the commit that nobody was
    /// following any more, a refused End also forgot a departure the walk
    /// had already been warned about, so a hiker still off the line was told
    /// "Off the trail" again one dwell later.
    @Test("a refused commit leaves an off-trail warning spent")
    func refusedCommitKeepsTheOffTrailWarningSpent() async {
        let harness = MovementReminderHarness.harness(clock: clock)
        var refusing = false
        let session = TrailWalkSession(
            context: context,
            reminders: harness.controller,
            clock: clock.read,
            save: { store in
                if refusing { throw CocoaError(.fileWriteUnknown) }
                try store.save()
            }
        )
        let hike = hike()
        walk(session, hike: hike, profile: RouteProfile(route: hike.route), from: 0, through: 3)
        stayOffTheTrail(session, hike: hike)
        await harness.controller.settle()
        #expect(harness.notifier.postedKinds == [.leftTheTrail], "precondition: the walk was warned")

        refusing = true
        guard case .refused = session.end() else {
            Issue.record("a store that refuses the commit must refuse the end")
            return
        }
        refusing = false
        stayOffTheTrail(session, hike: hike)
        await harness.controller.settle()
        #expect(harness.notifier.postedKinds == [.leftTheTrail], "once per departure, and this is the same one")
    }

    /// Two fixes well off the line, a dwell apart: what being told takes.
    private func stayOffTheTrail(_ session: TrailWalkSession, hike: Hike) {
        for _ in 0..<2 {
            clock.advance(by: MovementReminderPolicy.offTrailDwell)
            session.recordRouteDistance(
                hikeID: hike.id,
                offRouteMeters: MovementReminderPolicy.offTrailMeters * 2,
                at: clock.now
            )
        }
    }

    /// An end at the other end. The direction a GPX stores its points in is
    /// the importer's, not the hiker's, so a hiker who covers the route
    /// from its stored end to its stored start has walked the trail — and
    /// what that has to leave behind is everything a forward walk leaves: a
    /// row that reads Completed rather than Left open, and a
    /// ``TrailWalkSession/lastEndedWalk`` for the summary to be pushed from
    /// and the closing panel to linger on.
    @Test("a walk in the route's reverse direction ends as completed")
    func reverseWalkReachesTheEnd() throws {
        let session = session()
        // A point-to-point trail, where the trailhead and the far end are two
        // different places — unlike the out-and-back the rest of these use.
        let hike = Fixture.hike(in: context, title: "Ridge Line", route: Fixture.ridgeRoute)
        let profile = RouteProfile(route: hike.route)
        walk(session, hike: hike, profile: profile, from: profile.coordinates.count - 1, through: 1)
        #expect(session.walkedHikeID == hike.id, "one point short of the trailhead is still walking")

        walk(session, hike: hike, profile: profile, from: 0, through: 0)

        #expect(session.walkedHikeID == nil)
        let ended = try #require(session.lastEndedWalk, "so the summary has something to push and the panel lingers")
        #expect(ended.endReason == .reachedEnd)
        #expect(ended.coveredFraction > 0.99)
        #expect(try walks(of: hike).count == 1)
    }

    /// The fix that completes a walk has to say so. With the record cleared,
    /// `publishes` says yes and `payload` says nothing, so a caller that went
    /// on to publish would start a fresh plain follow over the finished panel
    /// the end has just queued.
    @Test("the fix that completes a walk reports it to its caller")
    func completingFixReportsTheEnd() {
        let session = session()
        let hike = hike()
        let profile = RouteProfile(route: hike.route)
        let last = profile.coordinates.count - 1
        walk(session, hike: hike, profile: profile, from: 0, through: last - 1)
        clock.advance(by: 60)

        let completed = session.recordForegroundMatch(
            hike: hike,
            profile: profile,
            distance: profile.distances[last]
        )

        #expect(completed)
        #expect(session.walkedHikeID == nil)
        #expect(session.publishes(hikeID: hike.id), "which on its own would have published a plain follow")
        #expect(session.payload(for: hike.id) == nil)
    }
}
