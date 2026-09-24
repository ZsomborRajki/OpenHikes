//
//  WalkingTimeEstimateTests.swift
//  OpenHikesSharedTests
//

import Foundation
import OpenHikesShared
import Testing

@Suite("Walking time estimate")
struct WalkingTimeEstimateTests {
    /// The issue's own example, and the one that motivated the rule: eight
    /// kilometres with a thousand metres of ascent is two hours at a flat
    /// pace and four hours twenty by the signposts.
    @Test("a climb counts in full and the flat at half when the climb is longer")
    func theClimbDominatesAnAlpineRoute() {
        let seconds = WalkingTimeEstimate.seconds(
            distanceMeters: 8000,
            ascentMeters: 1000,
            descentMeters: 0
        )
        // Vertical 3h20, horizontal 2h: 3h20 + 1h. A third of an hour is
        // not exact in binary, hence the tolerance.
        #expect(abs(seconds - (4 * 3600 + 20 * 60)) < 0.001)
    }

    @Test("on the flat it is four kilometres an hour")
    func theFlatIsFourKilometresAnHour() {
        #expect(WalkingTimeEstimate.seconds(distanceMeters: 12_000, ascentMeters: 0, descentMeters: 0) == 3 * 3600)
    }

    /// Where Naismith would add nothing for the way down.
    @Test("descent is counted at five hundred metres an hour")
    func descentCounts() {
        let seconds = WalkingTimeEstimate.seconds(
            distanceMeters: 4000,
            ascentMeters: 0,
            descentMeters: 1000
        )
        // Vertical 2h, horizontal 1h: 2h + 30m.
        #expect(seconds == 2 * 3600 + 30 * 60)
    }

    @Test("the smaller half is the horizontal one on a gentle route")
    func theFlatDominatesAGentleRoute() {
        let seconds = WalkingTimeEstimate.seconds(
            distanceMeters: 16_000,
            ascentMeters: 300,
            descentMeters: 500
        )
        // Horizontal 4h, vertical 1h + 1h: 4h + 1h.
        #expect(seconds == 5 * 3600)
    }

    @Test("a nonsensical input counts as nothing rather than as a negative time")
    func nonsenseCountsAsZero() {
        #expect(WalkingTimeEstimate.seconds(distanceMeters: -5, ascentMeters: .nan, descentMeters: .infinity) == 0)
        #expect(WalkingTimeEstimate.seconds(distanceMeters: 0, ascentMeters: 0, descentMeters: 0) == 0)
    }
}
