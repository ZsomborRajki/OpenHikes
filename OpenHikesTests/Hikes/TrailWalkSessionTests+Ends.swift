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
import SwiftData
import Testing

extension TrailWalkSessionTests {
    /// End has to be an end. Without a boundary the next accepted on-route
    /// fix finds no record and simply starts another walk — most visibly for
    /// a walk under the minimum, where End keeps nothing, the detail is still
    /// on screen, and the controls come back on the walker's next step.
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
        clock.advance(by: 60)
        session.recordForegroundMatch(hike: hike, profile: profile, distance: profile.distances[7])
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

        session.autoFollowDidChange(hikeID: hike.id, enabled: false)
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
