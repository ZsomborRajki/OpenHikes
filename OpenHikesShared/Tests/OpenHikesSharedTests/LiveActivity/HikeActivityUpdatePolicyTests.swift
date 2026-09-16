//
//  HikeActivityUpdatePolicyTests.swift
//  OpenHikesSharedTests
//
//  "Hike activity update policy", split out of HikeActivityTests.swift so
//  that a file declares one @Suite. That file's header still holds the
//  context the two share.
//

import Foundation
@testable import OpenHikesShared
import Testing

@Suite("Hike activity update policy")
struct HikeActivityUpdatePolicyTests {
    private static let base = HikeActivityAttributes.ContentState(
        distanceMeters: 1000,
        offRouteMeters: 5
    )

    /// ActivityKit throttles an app that updates too often, and a metre of
    /// drift is invisible at the width these numbers are drawn at.
    @Test("a distance change too small to see is not worth an update")
    func smallDistanceIsNotWorthAnUpdate() {
        var moved = Self.base
        moved.distanceMeters = 1010
        #expect(!moved.warrantsUpdate(comparedTo: Self.base))

        moved.distanceMeters = 1030
        #expect(moved.warrantsUpdate(comparedTo: Self.base))
    }

    /// The two changes that alter what the activity *says* rather than what it
    /// reads, and so must never be throttled away.
    @Test("pausing is always worth an update")
    func pausingIsAlwaysWorthAnUpdate() {
        var paused = Self.base
        paused.runState = .paused
        #expect(paused.warrantsUpdate(comparedTo: Self.base))
    }

    @Test("stepping off the trail is always worth an update")
    func leavingTheTrailIsAlwaysWorthAnUpdate() {
        var offRoute = Self.base
        offRoute.offRouteMeters = nil
        #expect(offRoute.warrantsUpdate(comparedTo: Self.base))
        #expect(Self.base.warrantsUpdate(comparedTo: offRoute))
    }

    /// The hole this list had. Every chip on the panel is a figure, and the
    /// throttle only ever read one of them: a recording up a steep pitch
    /// gains fifty metres against ten of ground, so *Ascent* and *Elevation*
    /// went stale while the rule said nothing had changed.
    @Test("a climb with little ground covered is worth an update")
    func climbingIsWorthAnUpdate() {
        var climbing = Self.base
        climbing.elevationGainMeters = 40
        climbing.distanceMeters = Self.base.distanceMeters + 10

        #expect(climbing.warrantsUpdate(comparedTo: Self.base), "the ascent chip is on screen and is wrong")
    }

    /// And the same figure moving by less than the chip can show is not.
    @Test("a climb too small to see is not worth an update")
    func smallClimbIsNotWorthAnUpdate() {
        var base = Self.base
        base.elevationGainMeters = 40
        var climbing = base
        climbing.elevationGainMeters = 45

        #expect(!climbing.warrantsUpdate(comparedTo: base))
    }

    /// The trail's height under the hiker is the other chip drawn from a
    /// figure, and it moves on a descent where the ascent total does not.
    @Test("the current elevation moving is worth an update")
    func currentElevationIsWorthAnUpdate() {
        var base = Self.base
        base.currentElevationMeters = 1200
        var descended = base
        descended.currentElevationMeters = 1180

        #expect(descended.warrantsUpdate(comparedTo: base))
    }

    /// A chip appearing or vanishing is the most visible change there is —
    /// which is what a follow with no figures becoming one with them does.
    @Test("a chip appearing is worth an update")
    func aChipAppearingIsWorthAnUpdate() {
        var withFigures = Self.base
        withFigures.elevationGainMeters = 12

        #expect(withFigures.warrantsUpdate(comparedTo: Self.base))
        #expect(Self.base.warrantsUpdate(comparedTo: withFigures))
    }

    /// Deliberate, and the one place it is written down in a test: the panel
    /// reads `offRouteMeters` as a flag — `HikeActivityPresentation` asks only
    /// `!= nil` — and draws the number nowhere. An update spent on a drift
    /// from 5 m to 800 m would redraw a panel saying exactly what it said
    /// before. Today's publisher cannot even produce it: a fix off the route
    /// is published as no fix at all. If the figure is ever drawn, this
    /// expectation is the one that has to change with it.
    @Test("a bigger off-route deviation alone is not worth an update")
    func offRouteMagnitudeAloneIsNotWorthAnUpdate() {
        var drifted = Self.base
        drifted.offRouteMeters = 800

        #expect(!drifted.warrantsUpdate(comparedTo: Self.base))
    }

    /// The clock ticks by itself through `timerStart`, so spending an update
    /// on it would buy nothing at all.
    @Test("the elapsed clock alone is never worth an update")
    func elapsedAloneIsNeverWorthAnUpdate() {
        var later = Self.base
        later.elapsedSeconds += 600
        later.updatedAt = Self.base.updatedAt.addingTimeInterval(600)
        #expect(!later.warrantsUpdate(comparedTo: Self.base))
    }

    @Test("the same walk is recognised across a rename")
    func sameWalkIsRecognisedAcrossARename() {
        let hikeID = UUID()
        let original = HikeActivityAttributes(
            subject: .following(hikeID: hikeID),
            title: "Ridge",
            tintHex: "#FF0000",
            startedAt: .now
        )
        var renamed = original
        renamed.title = "Ridge Loop"
        renamed.tintHex = "#00FF00"
        #expect(original.describesSameWalk(as: renamed))

        var other = original
        other.subject = .following(hikeID: UUID())
        #expect(!original.describesSameWalk(as: other))
    }
}
