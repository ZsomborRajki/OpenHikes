//
//  ElevationSampleIdentityTests.swift
//  OpenHikesDataTests
//
//  The elevation chart's two series hand `ElevationSample.id` to `ForEach`,
//  and SwiftUI cannot tell two marks with one identity apart during an
//  update. Distance alone is not unique: a route short enough to be drawn
//  whole keeps every point it has, so two fixes recorded at one place, with
//  no pause between them, stand at one distance, and so do the two halves of
//  a pause's step. These pin that every plotted sample has an identity of its
//  own, that the heights at a repeated distance and at a pause are all kept,
//  and that an identity names one of the route's heights for good: through a
//  rebuild, as a recording grows, and when a route outgrows the plotting
//  budget and is thinned.
//

import Foundation
@testable import OpenHikesData
import Testing

@Suite("Elevation sample identity")
struct ElevationSampleIdentityTests {
    /// A walk north in steps of about 111 m. Each entry is a height, and the
    /// points named in `stayingAt` are recorded where the point before them
    /// was, as a hiker standing still gets them.
    private static func route(
        _ elevations: [Double],
        stayingAt stayed: Set<Int> = [],
        resumingAt resumed: Set<Int> = []
    ) -> [RouteCoordinate] {
        var step = 0
        return elevations.enumerated().map { index, elevation in
            if index > 0, !stayed.contains(index) { step += 1 }
            return RouteCoordinate(
                latitude: 47.63 + Double(step) * 0.001,
                longitude: 12.86,
                elevation: elevation,
                boundary: resumed.contains(index) ? .paused : nil
            )
        }
    }

    @Test("two fixes at one place are both plotted, each with its own identity")
    func repeatedFixesHaveDistinctIdentities() {
        let profile = RouteProfile(route: Self.route([500, 510, 515, 520], stayingAt: [2]))

        #expect(profile.samples.map(\.elevation) == [500, 510, 515, 520])
        #expect(profile.samples[1].distanceMeters == profile.samples[2].distanceMeters)
        #expect(Set(profile.samples.map(\.id)).count == profile.samples.count)
        #expect(profile.samples.map(\.repeatIndex) == [0, 0, 1, 0])
    }

    @Test("three fixes at one place count up from the first")
    func everyRepeatCountsOn() {
        let profile = RouteProfile(route: Self.route([500, 501, 502, 503], stayingAt: [1, 2, 3]))

        #expect(profile.samples.map(\.repeatIndex) == [0, 1, 2, 3])
        #expect(Set(profile.samples.map(\.id)).count == 4)
    }

    /// The step at a pause is a rise the chart draws at one distance, and it
    /// must survive alongside a repeat on either side of it.
    @Test("a pause's step keeps both heights beside a repeated fix")
    func pauseStepKeepsItsHeightsBesideARepeat() {
        let profile = RouteProfile(
            route: Self.route([500, 505, 900, 910], stayingAt: [1], resumingAt: [2])
        )

        let atJoin = profile.samples.filter { $0.distanceMeters == profile.samples[0].distanceMeters }
        #expect(atJoin.map(\.elevation) == [500, 505, 900])
        #expect(atJoin.map(\.resumesAfterPause) == [false, false, true])
        #expect(Set(profile.samples.map(\.id)).count == profile.samples.count)
    }

    /// A resumed fix followed by another at the same place folds into the
    /// resume, as it always has, and the later height is the one plotted. The
    /// sample is the later fix's, so it carries that fix's identity: the
    /// resume's would name 900 m until the second fix came and 905 m after.
    @Test("a fix folded into a pause's resume brings its own identity")
    func foldedFixBringsItsOwnIdentity() {
        let profile = RouteProfile(
            route: Self.route([500, 900, 905, 910], stayingAt: [1, 2], resumingAt: [1])
        )

        #expect(profile.samples.map(\.elevation) == [500, 905, 910])
        #expect(profile.samples.map(\.resumesAfterPause) == [false, true, false])
        #expect(profile.samples.map(\.repeatIndex) == [0, 2, 0])
        #expect(Set(profile.samples.map(\.id)).count == profile.samples.count)
    }

    @Test("a rebuild of a route with repeats gives the same identities")
    func identitiesAreStableAcrossRebuilds() {
        let route = Self.route([500, 510, 515, 520, 530], stayingAt: [2, 3], resumingAt: [4])
        let first = RouteProfile(route: route)
        let second = RouteProfile(route: route)

        #expect(first.samples.map(\.id) == second.samples.map(\.id))
    }

    /// A sample's identity must not move as a recording grows past it, or
    /// every tick would diff the chart's existing marks as replaced.
    @Test("a sample keeps its identity as the route grows past it")
    func identityHoldsAsTheRouteGrows() {
        let full = Self.route([500, 510, 515, 520], stayingAt: [2])
        let shorter = RouteProfile(route: Array(full.prefix(3))).samples.map(\.id)
        let longer = RouteProfile(route: full).samples.map(\.id)

        #expect(Array(longer.prefix(3)) == shorter)
    }

    /// At the plotting budget a route is drawn whole, and one point more has
    /// it thinned. Here the thinning keeps the fix a pause resumed on and
    /// drops the one before the pause, which stood at the same distance: the
    /// resumed fix must keep its own identity rather than take the dropped
    /// fix's, or both series would move that fix's mark onto another height.
    @Test("a pause's resumed fix keeps its identity when the route outgrows the plotting budget")
    func resumedFixKeepsItsIdentityPastTheBudget() throws {
        let budget = RouteProfile.plottedSampleBudget
        var elevations = Array(repeating: 100.0, count: budget + 1)
        elevations[budget - 2] = 125
        elevations[budget - 1] = 150
        let route = Self.route(elevations, resumingAt: [budget - 1])

        let whole = RouteProfile(route: Array(route.prefix(budget)))
        let thinned = RouteProfile(route: route)
        let resumedFix = whole.samples.first(where: \.resumesAfterPause)
        let thinnedFix = thinned.samples.first(where: \.resumesAfterPause)
        let resumed = try #require(resumedFix)
        let thinnedResumed = try #require(thinnedFix)

        #expect(whole.samples.count == budget)
        #expect(!thinned.samples.contains { $0.elevation == 125 })
        #expect(thinnedResumed.elevation == 150)
        #expect(thinnedResumed.id == resumed.id)
    }

    /// A recording grows one fix at a time, through the plotting budget and
    /// past it, and every growth step thins the series afresh. Whatever each
    /// step keeps, an identity must go on naming the height it named first,
    /// or the chart's marks would be diffed onto heights that are not theirs.
    /// The route stands still at every fifth point and pauses at every 45th,
    /// each pause with a fix at the same place after it, so repeats, steps
    /// and folds all fall across the budget.
    @Test("an identity names one height as a recording grows past the plotting budget")
    func identitiesNameOneHeightAcrossTheBudget() {
        let budget = RouteProfile.plottedSampleBudget
        let count = budget + 30
        let elevations = (0..<count).map { 500 + Double(($0 * 37) % 61) }
        let stayed = Set((1..<count).filter { $0.isMultiple(of: 5) })
        let resumed = Set((1..<count).filter { $0 % 45 == 44 })
        let route = Self.route(elevations, stayingAt: stayed, resumingAt: resumed)

        var heights: [ElevationSample.Identity: Double] = [:]
        for length in (budget - 10)...count {
            let samples = RouteProfile(route: Array(route.prefix(length))).samples
            #expect(Set(samples.map(\.id)).count == samples.count, "\(length) points")
            for sample in samples {
                let named = heights[sample.id, default: sample.elevation]
                #expect(named == sample.elevation, "\(sample.id) at \(length) points")
                heights[sample.id] = sample.elevation
            }
        }
        #expect(RouteProfile(route: route).samples.count < count)
    }
}
