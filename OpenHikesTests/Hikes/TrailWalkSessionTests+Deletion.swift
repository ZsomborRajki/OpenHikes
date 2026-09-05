//
//  TrailWalkSessionTests+Deletion.swift
//  OpenHikesTests
//
//  What happens to a walk when its hike goes away.
//
//  Split from `TrailWalkSessionTests` the way `+Ends` was, and for the same
//  reason: that suite had reached its length, and these ask a question of
//  their own. A walk hangs off a hike, and there are exactly two ways the
//  hike can stop being there — the swipe in `MapSheet`, which says so, and
//  every other way, which does not. A deletion mirrored from the walker's
//  other device removes the row and calls nothing; the recorder's own
//  deletions go through `HikeDeletion` and call nothing either. So the walk
//  has to notice on its own, in the session while it is running and at the
//  next launch in the sidecar column it left behind — and the column matters
//  more than it looks, because `openWalkAtLaunch` returns exactly one open
//  walk and an orphan is always the newest.
//

import Foundation
@testable import OpenHikes
import SwiftData
import Testing

extension TrailWalkSessionTests {
    @Test("deleting the walked hike forgets the walk without a row")
    func deletedHikeDiscardsTheWalk() throws {
        let session = session()
        let hike = hike()
        let profile = RouteProfile(route: hike.route)
        walk(session, hike: hike, profile: profile, from: 0, through: 5)

        session.discardWalk(forDeletedHike: hike.id)

        #expect(session.walkedHikeID == nil)
        #expect(try walks(of: hike).isEmpty)
    }

    /// The swipe in `MapSheet` is the one deletion that says so. A hike
    /// deleted on the walker's other device arrives as a mirrored row
    /// deletion and calls nothing, so the walk is noticed on the next fix —
    /// without which no trail can start one, on any screen, until the app is
    /// relaunched.
    @Test("a hike that goes away underneath the walk is noticed on the next fix")
    func vanishedHikeIsNoticedOnTheNextFix() throws {
        let session = session()
        let walked = hike()
        let other = hike(title: "Still in the library")
        walk(session, hike: walked, profile: RouteProfile(route: walked.route), from: 0, through: 5)
        #expect(session.walkedHikeID == walked.id)

        // No `deleteLocalState()`, no `discardWalk`: the row and nothing else,
        // which is all a mirrored deletion can do to this store.
        context.delete(walked)
        try context.save()

        let profile = RouteProfile(route: other.route)
        session.recordForegroundMatch(hike: other, profile: profile, distance: profile.distances[0])

        #expect(try walks(of: walked).isEmpty, "a walk with no hike left to hang off keeps no row")
        #expect(session.walkedHikeID == other.id, "and the trail that is still here can be walked")
    }

    /// The `.resume` branch's own version of what the `.abandon` branch above
    /// it already did — and the launch this is about is not the first one.
    /// `openWalkAtLaunch` returns exactly one open walk, the newest, and an
    /// orphan is never overtaken: left set, the column is chosen at every
    /// launch, returns early, and the walk that is really under way on
    /// another trail is never adopted again.
    @Test("a walk left open on a hike that is gone is cleared, not adopted")
    func orphanedOpenWalkIsClearedAtLaunch() throws {
        // The genuine walk first, so the orphan is the newer of the two and
        // wins every launch until something clears it.
        let stillWalked = hike(title: "Walked today")
        let liveProfile = RouteProfile(route: stillWalked.route)
        walk(session(), hike: stillWalked, profile: liveProfile, from: 0, through: 5)

        clock.advance(by: 3600)
        let orphaned = hike()
        let orphanedID = orphaned.id
        walk(session(), hike: orphaned, profile: RouteProfile(route: orphaned.route), from: 0, through: 5)
        // The row and nothing else: `deleteLocalState()` is on the local
        // deletion path, which a mirrored deletion never reaches.
        context.delete(orphaned)
        try context.save()

        let relaunched = session()
        relaunched.restoreAtLaunch()

        #expect(relaunched.walkedHikeID == nil, "there is no hike to adopt the newest walk on")
        let sidecar = try #require(
            try context.fetch(FetchDescriptor<HikeLocalState>())
                .first { $0.hikeID == orphanedID }
        )
        #expect(sidecar.walkInProgress == nil, "and the column it left behind is cleared")

        // The launch after: with the orphan out of the way, the walk that is
        // really under way is adopted again.
        let after = session()
        after.restoreAtLaunch()
        #expect(after.walkedHikeID == stillWalked.id)
    }
}
