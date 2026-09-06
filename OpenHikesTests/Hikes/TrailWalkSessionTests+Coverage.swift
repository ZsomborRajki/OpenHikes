//
//  TrailWalkSessionTests+Coverage.swift
//  OpenHikesTests
//
//  What a walk's coverage union is allowed to claim while the walk is under
//  way. The gap bound bridges a lost signal on purpose; these are the cases
//  where something positively says the walker did not walk the stretch in
//  between, and the union has to say so too — it is what History, Show on
//  Map and the completion rule read.
//

import Foundation
@testable import OpenHikes
import SwiftData
import Testing

extension TrailWalkSessionTests {
    /// The matcher can make the same statement a pause does. A fix accepted
    /// and found off the route is positive evidence that the walker left the
    /// trail, so the stretch they rejoin at is not walked route — however
    /// bridgeable the gap looks.
    @Test("a confirmed off-route excursion is not saved as walked")
    func offRouteBreaksCoverage() throws {
        let session = session()
        let hike = hike()
        let profile = RouteProfile(route: hike.route)
        session.recordForegroundMatch(hike: hike, profile: profile, distance: 0)
        clock.advance(by: 120)
        session.recordForegroundMatch(hike: hike, profile: profile, distance: 200)

        // Down the road, cutting the loop out.
        session.recordOffRoute(hikeID: hike.id)
        clock.advance(by: 180)
        #expect(450 - 200 <= TrailWalkPolicy.gapBoundMeters, "precondition: bridgeable")
        session.recordForegroundMatch(hike: hike, profile: profile, distance: 450)

        #expect(try #require(session.record).coverage.coveredMeters == 200)
        session.end()
        let row = try #require(try walks(of: hike).first)
        #expect(row.coverage.coveredMeters == 200, "and the shortcut is not in History either")
        #expect(row.coverage.furthestDistanceMeters == 450, "the walker did reach there")
    }

    /// The break has to reach the sidecar, not only the record. An excursion
    /// accrues nothing of its own, so the fixes that keep arriving while the
    /// walker is off the route are the only thing that can carry a write the
    /// cadence deferred — and a relaunch mid-excursion is exactly when the
    /// old anchor would come back.
    @Test("a continuity break deferred by the cadence still reaches the sidecar")
    func offRouteBreakSurvivesARelaunch() throws {
        let session = session()
        let hike = hike()
        let profile = RouteProfile(route: hike.route)
        session.recordForegroundMatch(hike: hike, profile: profile, distance: 0)
        clock.advance(by: 120)
        session.recordForegroundMatch(hike: hike, profile: profile, distance: 200)

        // Off the route inside the write window: the break is in memory only.
        clock.advance(by: 10)
        session.recordOffRoute(hikeID: hike.id)
        #expect(
            try #require(hike.walkInProgress).coverage.lastMatchedDistance == 200,
            "precondition: the write was deferred, so the sidecar still has the anchor"
        )
        // Still off it when the cadence comes due, and that fix writes it.
        clock.advance(by: TrailWalkPolicy.persistInterval)
        session.recordOffRoute(hikeID: hike.id)
        #expect(try #require(hike.walkInProgress).coverage.lastMatchedDistance == nil)

        let relaunched = self.session()
        relaunched.restoreAtLaunch()
        clock.advance(by: 180)
        relaunched.recordForegroundMatch(hike: hike, profile: profile, distance: 450)
        relaunched.end()

        let row = try #require(try walks(of: hike).first)
        #expect(row.coverage.coveredMeters == 200, "the shortcut is not walked route on this launch either")
    }

    /// And a write the store refused is retried the same way, rather than
    /// left behind by the fix that happened to make the break.
    @Test("a continuity break the store refused is retried by a later off-route fix")
    func refusedBreakIsRetried() throws {
        var refusing = false
        let session = TrailWalkSession(context: context, clock: clock.read, save: { store in
            if refusing { throw CocoaError(.fileWriteUnknown) }
            try store.save()
        })
        let hike = hike()
        let profile = RouteProfile(route: hike.route)
        session.recordForegroundMatch(hike: hike, profile: profile, distance: 0)
        clock.advance(by: 120)
        session.recordForegroundMatch(hike: hike, profile: profile, distance: 200)

        refusing = true
        clock.advance(by: TrailWalkPolicy.persistInterval)
        session.recordOffRoute(hikeID: hike.id)
        #expect(
            try #require(hike.walkInProgress).coverage.lastMatchedDistance == 200,
            "the refusal left the column as it was"
        )

        refusing = false
        clock.advance(by: 1)
        session.recordOffRoute(hikeID: hike.id)
        #expect(try #require(hike.walkInProgress).coverage.lastMatchedDistance == nil, "the prompt retry carries it")
    }

    /// The other half of the rule: nothing said the walker left the route, so
    /// a re-acquisition inside the gap bound is still the lost signal it has
    /// always been.
    @Test("an ordinary signal gap is still bridged")
    func signalGapIsStillBridged() throws {
        let session = session()
        let hike = hike()
        let profile = RouteProfile(route: hike.route)
        session.recordForegroundMatch(hike: hike, profile: profile, distance: 0)
        clock.advance(by: 300)
        session.recordForegroundMatch(hike: hike, profile: profile, distance: 450)

        #expect(try #require(session.record).coverage.coveredMeters == 450)
    }

    /// An off-route fix along a trail nobody is walking says nothing about
    /// the walk under way — the walker can have another trail on screen.
    @Test("an off-route report for another hike leaves the walk's coverage alone")
    func offRouteForAnotherHikeIsIgnored() throws {
        let session = session()
        let hike = hike()
        let other = self.hike(title: "Other")
        let profile = RouteProfile(route: hike.route)
        session.recordForegroundMatch(hike: hike, profile: profile, distance: 0)
        clock.advance(by: 120)
        session.recordForegroundMatch(hike: hike, profile: profile, distance: 200)

        session.recordOffRoute(hikeID: other.id)
        clock.advance(by: 180)
        session.recordForegroundMatch(hike: hike, profile: profile, distance: 450)

        #expect(try #require(session.record).coverage.coveredMeters == 450)
    }
}
