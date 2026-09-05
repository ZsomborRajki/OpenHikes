//
//  TrailWalkSessionTests+Milestones.swift
//  OpenHikesTests
//
//  What a phase has to be before it is shown as one.
//
//  Split from `TrailWalkSessionTests` for the reason `+Ends` was: that suite
//  asks what a walk does, and these ask whether a milestone happened. Pause
//  and Resume are commits like an end — the screens, the widget and the Lock
//  Screen may only say Paused once the sidecar does, because a paused walk
//  accrues nothing of its own to write later, so a refusal the app reported
//  as a pause would outlive it and come back at the next launch as a walk
//  that was following the whole time.
//
//  Every session here goes through a save seam the test can close, the same
//  one `refusedCommitKeepsTheWalk` uses for an end.
//

import Foundation
@testable import OpenHikes
import SwiftData
import Testing

extension TrailWalkSessionTests {
    /// A Pause the store refuses is not a Pause. The record, the phase the
    /// screens read and the sidecar all stay following, and a relaunch that
    /// reads only what was committed finds the same walk still under way —
    /// rather than one the app called paused and the disk calls active.
    @Test("a refused pause leaves the walk following, on screen and on disk")
    func refusedPauseIsNotAPause() throws {
        var refusing = false
        let session = TrailWalkSession(
            context: context,
            clock: clock.read,
            save: { store in
                if refusing { throw CocoaError(.fileWriteUnknown) }
                try store.save()
            }
        )
        let hike = hike()
        let profile = RouteProfile(route: hike.route)
        walk(session, hike: hike, profile: profile, from: 0, through: 5)
        let open = try #require(hike.walkInProgress)
        #expect(open.phase == .following, "precondition: the sidecar has a following walk")

        refusing = true
        #expect(!session.pause(), "a phase the store refused is not a phase")

        #expect(session.phase == .following, "so the controls still offer Pause")
        #expect(session.record?.phase == .following)
        #expect(hike.walkInProgress == open, "and the write is off the column, not left pending on it")

        // What the next launch would see: only what was committed.
        let relaunched = TrailWalkSession(context: ModelContext(context.container), clock: clock.read)
        relaunched.restoreAtLaunch()
        #expect(relaunched.walkedHikeID == hike.id)
        #expect(relaunched.phase == .following, "the walk comes back as what it never stopped being")
    }

    /// A refused Resume leaves the walk paused on screen and on disk, and
    /// preserves the independent Follow This Trail preference.
    @Test("a refused resume leaves the walk paused, and following off")
    func refusedResumeIsNotAResume() throws {
        var refusing = false
        let session = TrailWalkSession(
            context: context,
            clock: clock.read,
            save: { store in
                if refusing { throw CocoaError(.fileWriteUnknown) }
                try store.save()
            }
        )
        let hike = hike()
        let profile = RouteProfile(route: hike.route)
        walk(session, hike: hike, profile: profile, from: 0, through: 5)
        hike.autoFollowEnabled = false
        session.autoFollowDidChange(hikeID: hike.id, enabled: false)
        #expect(session.pause())
        let paused = try #require(hike.walkInProgress)
        #expect(paused.phase == .paused, "precondition: the pause was written")

        clock.advance(by: 600)
        refusing = true
        #expect(!session.resume())

        #expect(session.phase == .paused, "so the controls still offer Resume")
        #expect(!hike.autoFollowEnabled, "and following is not turned on for a walk that did not resume")
        #expect(hike.walkInProgress == paused, "the sidecar is the pause it already held")

        let relaunched = TrailWalkSession(context: ModelContext(context.container), clock: clock.read)
        relaunched.restoreAtLaunch()
        #expect(relaunched.phase == .paused)
    }

    /// A write nothing committed leaves the next one due, rather than waiting
    /// out a cadence that measures a commit that never happened.
    @Test("a refused write does not advance the cadence and is retried at once")
    func refusedWriteIsRetriedOnTheNextFix() throws {
        var refusing = false
        let session = TrailWalkSession(
            context: context,
            clock: clock.read,
            save: { store in
                if refusing { throw CocoaError(.fileWriteUnknown) }
                try store.save()
            }
        )
        let hike = hike()
        let profile = RouteProfile(route: hike.route)
        walk(session, hike: hike, profile: profile, from: 0, through: 2)
        let written = try #require(hike.walkInProgress)

        refusing = true
        clock.advance(by: TrailWalkPolicy.persistInterval)
        session.recordForegroundMatch(hike: hike, profile: profile, distance: profile.distances[3])
        #expect(hike.walkInProgress == written, "a refused write is taken back off the column")

        refusing = false
        clock.advance(by: 1)
        session.recordForegroundMatch(hike: hike, profile: profile, distance: profile.distances[4])

        let retried = try #require(hike.walkInProgress)
        #expect(
            retried.coverage.coveredMeters > written.coverage.coveredMeters,
            "the next fix writes rather than waiting out a window nothing committed"
        )
    }

    /// The retry has to reach a *paused* walk too. Fixes keep arriving while
    /// the walker stands still, and until this they returned before any
    /// persistence at all — which is what made "written again at the next
    /// milestone" untrue for the one phase with no next milestone of its own.
    @Test("a fix arriving while paused still reaches the sidecar")
    func pausedFixesStillPersist() throws {
        let session = session()
        let hike = hike()
        let profile = RouteProfile(route: hike.route)
        walk(session, hike: hike, profile: profile, from: 0, through: 3)
        session.pause()
        let paused = try #require(hike.walkInProgress)

        clock.advance(by: 3600)
        session.recordForegroundMatch(hike: hike, profile: profile, distance: profile.distances[10])

        let seen = try #require(hike.walkInProgress)
        #expect(seen.phase == .paused)
        #expect(seen.lastMatchedAt == clock.now, "the walk was seen, and the sidecar knows when")
        #expect(seen.coverage == paused.coverage, "and a paused walk covers nothing for it")
    }
}
