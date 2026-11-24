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
//  and that a rebuild of the same route gives the same identities.
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
    /// resume, as it always has, and keeps the resume's identity.
    @Test("a fix folded into a pause's resume keeps the resume's identity")
    func foldedResumeKeepsItsIdentity() {
        let profile = RouteProfile(
            route: Self.route([500, 900, 905, 910], stayingAt: [1, 2], resumingAt: [1])
        )

        #expect(profile.samples.map(\.elevation) == [500, 905, 910])
        #expect(profile.samples.map(\.repeatIndex) == [0, 1, 0])
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
}
