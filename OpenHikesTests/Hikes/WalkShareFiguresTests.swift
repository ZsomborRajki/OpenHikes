//
//  WalkShareFiguresTests.swift
//  OpenHikesTests
//
//  What a walk's share card prints. Every figure is the walk's own — the
//  covered distance, the covered stretches' climb, that distance over the
//  active clock — and a figure with nothing true to say is left off rather
//  than printed as a dash on somebody else's screen.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import RealModule
import Testing

@Suite("Walk share figures")
struct WalkShareFiguresTests {
    private static let metric = Locale(identifier: "de_DE")

    private func figures(
        walkedMeters: Double = 5000,
        activeSeconds: Double = 3600,
        ascentMeters: Double? = 420,
        completion: Double = 0.5
    ) -> WalkShareFigures {
        WalkShareFigures(
            title: "Ridge Loop",
            walkedMeters: walkedMeters,
            activeSeconds: activeSeconds,
            ascentMeters: ascentMeters,
            descentMeters: ascentMeters,
            completion: completion,
            startedAt: Date(timeIntervalSince1970: 1_750_000_000)
        )
    }

    @Test("the pace is the covered distance over the active clock")
    func paceIsCoveredOverActive() throws {
        let pace = try #require(figures(walkedMeters: 5000, activeSeconds: 3600).averageMetersPerSecond)

        #expect(pace.isApproximatelyEqual(to: 5000.0 / 3600, absoluteTolerance: 1e-9))
        #expect(figures().value(of: .speed, locale: Self.metric) == "5,0 km/h")
    }

    @Test("a walk with no distance or no clock has no pace to print")
    func noPaceWithoutDistanceOrTime() {
        #expect(figures(walkedMeters: 0).value(of: .speed) == nil)
        #expect(figures(activeSeconds: 0).value(of: .speed) == nil)
        #expect(figures(activeSeconds: 0).value(of: .time) == nil)
    }

    @Test("a climb that cannot be said leaves the card")
    func unknownClimbIsLeftOff() {
        #expect(figures(ascentMeters: nil).value(of: .ascent) == nil)
        #expect(figures(ascentMeters: nil).value(of: .descent) == nil)
        #expect(figures(ascentMeters: 420).value(of: .ascent, locale: Self.metric) == "420 m")
    }

    @Test("distance and completion are formatted the way the app writes them")
    func distanceAndCompletion() {
        let card = figures(walkedMeters: 2345, completion: 0.62)

        #expect(card.value(of: .distance, locale: Self.metric) == "2,3 km")
        #expect(card.value(of: .completion, locale: Locale(identifier: "en_US")) == "62%")
    }

    /// Over the whole route the walk's climb is the trail's, through the same
    /// accumulator — so the card cannot disagree with the detail screen about
    /// a walk that covered everything.
    @Test("a walk over the whole route climbs what the route climbs")
    func wholeRouteClimbIsTheRoutes() throws {
        let profile = RouteProfile(route: Fixture.ridgeRoute)
        let climb = try #require(WalkShareFigures.climb(over: [0...profile.totalDistanceMeters], along: profile))
        let route = try #require(profile.climb(from: 0, to: profile.totalDistanceMeters))

        #expect(climb.gainMeters.isApproximatelyEqual(to: route.gainMeters, absoluteTolerance: 1e-9))
        #expect(climb.lossMeters.isApproximatelyEqual(to: route.lossMeters, absoluteTolerance: 1e-9))
    }

    @Test("stretches' climbs are added up, and none means nothing to say")
    func stretchesAreSummed() throws {
        let profile = RouteProfile(route: Fixture.ridgeRoute)
        let total = profile.totalDistanceMeters
        let first = 0...(total * 0.45)
        let second = (total * 0.55)...total
        let summed = try #require(WalkShareFigures.climb(over: [first, second], along: profile))
        let a = try #require(profile.climb(from: first.lowerBound, to: first.upperBound))
        let b = try #require(profile.climb(from: second.lowerBound, to: second.upperBound))

        #expect(summed.gainMeters.isApproximatelyEqual(to: a.gainMeters + b.gainMeters, absoluteTolerance: 1e-9))
        #expect(WalkShareFigures.climb(over: [], along: profile) == nil)
    }
}
