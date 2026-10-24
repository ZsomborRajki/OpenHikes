//
//  WalkShareFiguresTests.swift
//  OpenHikesTests
//
//  What a walk's share card prints. Every figure is the walk's own — the
//  covered distance, the covered stretches' climb the way they were walked,
//  that distance over the active clock — and a figure with nothing true to
//  say is left off rather than printed as a dash on somebody else's screen.
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

    @Test("the speed is the covered distance over the active clock")
    func speedIsCoveredOverActive() throws {
        let speed = try #require(figures(walkedMeters: 5000, activeSeconds: 3600).averageMetersPerSecond)

        #expect(speed.isApproximatelyEqual(to: 5000.0 / 3600, absoluteTolerance: 1e-9))
        #expect(figures().value(of: .speed, locale: Self.metric) == "5,0 km/h")
    }

    @Test("a walk with no distance or no clock has no speed to print")
    func noSpeedWithoutDistanceOrTime() {
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
        let climb = try #require(profile.climb(over: [0...profile.totalDistanceMeters]))
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
        let summed = try #require(profile.climb(over: [first, second]))
        let a = try #require(profile.climb(from: first.lowerBound, to: first.upperBound))
        let b = try #require(profile.climb(from: second.lowerBound, to: second.upperBound))

        #expect(summed.gainMeters.isApproximatelyEqual(to: a.gainMeters + b.gainMeters, absoluteTolerance: 1e-9))
        #expect(profile.climb(over: []) == nil)
    }

    // MARK: Which way the walk went

    /// About 760 m rising a steady 100 m, a height every 15 m or so: each
    /// step is a match well inside the gap bound, and the midpoint is a
    /// height of its own.
    private static let hill = RouteProfile(route: (0...50).map { index in
        RouteCoordinate(latitude: 47, longitude: 11 + Double(index) * 0.0002, elevation: 100 + Double(index) * 2)
    })

    /// The card of a walk matched at each of `indices` along ``hill`` in
    /// turn, closed into the row the History segment keeps.
    private func card(walking indices: [Int]) -> WalkShareFigures {
        let profile = Self.hill
        var record = TrailWalkRecord(
            hikeID: UUID(),
            routeDistanceMeters: profile.totalDistanceMeters,
            startedAt: Date(timeIntervalSince1970: 1_750_000_000)
        )
        for index in indices {
            record.coverage.record(distance: profile.distances[index])
        }
        let walk = HikeWalk(closing: record, at: record.startedAt.addingTimeInterval(1800), reason: .ended)
        return WalkShareFigures(walk: walk, title: "Hill", profile: profile)
    }

    private func expectClimb(
        _ card: WalkShareFigures,
        ascent: Double,
        descent: Double,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(
            card.ascentMeters?.isApproximatelyEqual(to: ascent, absoluteTolerance: 0.001) == true,
            "ascent \(String(describing: card.ascentMeters))",
            sourceLocation: sourceLocation
        )
        #expect(
            card.descentMeters?.isApproximatelyEqual(to: descent, absoluteTolerance: 0.001) == true,
            "descent \(String(describing: card.descentMeters))",
            sourceLocation: sourceLocation
        )
    }

    @Test("a walk up the trail climbs what the trail climbs")
    func walkUpClimbs() {
        let card = card(walking: Array(0...50))

        expectClimb(card, ascent: 100, descent: 0)
        #expect(card.completion.isApproximatelyEqual(to: 1, absoluteTolerance: 1e-9))
    }

    /// The direction a GPX stores its points in is the importer's, and a walk
    /// from the stored end finishes like any other — so its card must not
    /// print the climb of a hill the hiker walked down (#993).
    @Test("a walk from the trail's stored end descends what the trail climbs")
    func walkDownDescends() {
        let card = card(walking: Array((0...50).reversed()))

        expectClimb(card, ascent: 0, descent: 100)
        #expect(card.completion.isApproximatelyEqual(to: 1, absoluteTolerance: 1e-9))
    }

    @Test("part of the trail walked down descends only that part")
    func partWalkedDownDescendsThatPart() {
        let card = card(walking: Array((25...50).reversed()))

        expectClimb(card, ascent: 0, descent: 50)
        #expect(card.completion.isApproximatelyEqual(to: 0.5, absoluteTolerance: 1e-9))
    }

    /// The union covers the stretch once, and the hiker climbed it and came
    /// back down it: the card counts the climb each way, and the distance and
    /// completion stay the ground covered.
    @Test("there and back over part of the trail climbs it and descends it")
    func thereAndBackClimbsBothWays() {
        let card = card(walking: Array(0...25) + Array((0...24).reversed()))

        expectClimb(card, ascent: 50, descent: 50)
        #expect(card.completion.isApproximatelyEqual(to: 0.5, absoluteTolerance: 1e-9))
        #expect(card.walkedMeters.isApproximatelyEqual(to: Self.hill.distances[25], absoluteTolerance: 1e-9))
    }

    /// Two matchers feed a walk and neither is smoothed, so a walk straight up
    /// the trail still has the odd match land behind the one before it. The
    /// card must not print that step as a descent.
    @Test("a match behind the one before it puts no descent on a walk up")
    func stepBackDescendsNothing() {
        let card = card(walking: Array(0...30) + [27] + Array(33...50))

        expectClimb(card, ascent: 100, descent: 0)
        #expect(card.completion.isApproximatelyEqual(to: 1, absoluteTolerance: 1e-9))
    }
}
