//
//  TrailSurfaceBreakdownTests.swift
//  OpenHikesTests
//
//  "Trail surface breakdown", split out of TrailSurfaceTests.swift so that a
//  file declares one @Suite. That file's header still holds the context the
//  two share.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import RealModule
import Testing

@Suite("Trail surface breakdown")
struct TrailSurfaceBreakdownTests {
    @Test("shares are surveyed-first, then longest-first")
    func ordersShares() throws {
        let breakdown = TrailSurfaceBreakdown(
            metersByCategory: [
                .unmapped: 500,
                .paved: 100,
                .ground: 300,
                .gravel: 100,
            ]
        )

        #expect(
            breakdown.shares.map(\.category) == [.ground, .paved, .gravel, .unmapped]
        )
        // `paved` precedes `gravel` in `TrailSurface.displayOrdering`, which
        // is the tie-break, so a rebuild of the same data can't reshuffle the
        // legend.
        let dominant = try #require(breakdown.dominant)
        #expect(dominant.category == .ground)
    }

    @Test("fractions are of the measured total and sum to one")
    func fractionsSumToOne() {
        let breakdown = TrailSurfaceBreakdown(
            metersByCategory: [.paved: 250, .ground: 750]
        )

        #expect(breakdown.totalMeters == 1000)
        #expect(breakdown.meters(for: .paved) == 250)
        #expect(breakdown.meters(for: .rock) == 0)
        let total = breakdown.shares.reduce(0) { $0 + $1.fraction }
        #expect(total.isApproximatelyEqual(to: 1, absoluteTolerance: 1e-9))
    }

    @Test("the surveyed fraction excludes both ways of not knowing")
    func surveyedFractionCountsOnlyTaggedSurfaces() {
        let breakdown = TrailSurfaceBreakdown(
            metersByCategory: [
                .gravel: 600,
                .unknown: 200,
                .unmapped: 200,
            ]
        )

        #expect(breakdown.surveyedFraction.isApproximatelyEqual(to: 0.6, absoluteTolerance: 1e-9))
    }

    @Test("zero-length categories are dropped, and nothing at all is empty")
    func dropsEmptyShares() {
        let breakdown = TrailSurfaceBreakdown(
            metersByCategory: [.paved: 100, .rock: 0]
        )

        #expect(breakdown.shares.count == 1)
        #expect(TrailSurfaceBreakdown(metersByCategory: [:]).isEmpty)
        #expect(TrailSurfaceBreakdown(metersByCategory: [.paved: 0]).isEmpty)
    }
}
