//
//  WatchRouteTrackerFirstFixTests.swift
//  OpenHikesSharedTests
//
//  The first fix after a fresh start, when it carries no course: a hiker who
//  opens the app, comes back to it or resumes a walk standing still. On a
//  trail that comes back along itself that fix is a guess between the legs,
//  and the guess, kept, held every later fix to its window: a hiker on the way
//  home was read on the way out, and falling, all the way back.
//

import Foundation
@testable import OpenHikesShared
import RealModule
import Testing

@Suite("Watch route tracker: the first fix")
struct WatchRouteTrackerFirstFixTests {
    @Test("A first fix with no course is shown but not kept, and the first with one decides the leg")
    func aGuessIsNotKept() throws {
        var tracker = WatchRouteTracker(Self.outAndBack)
        // A kilometre from the trailhead on the way home, standing still.
        // Hoisted out of `#require`, whose closure cannot call a mutating
        // member.
        let still = tracker.advance(latitude: Self.latitude, longitude: Self.kilometerOut, courseDegrees: nil)
        let guess = try #require(still)
        // Nothing yet tells the two legs apart, so the first one reads.
        #expect(guess.fractionComplete.isApproximatelyEqual(to: 1.0 / 6, absoluteTolerance: 0.01))

        var readings: [Double] = []
        for longitude in stride(from: Self.kilometerOut, to: Self.trailhead, by: -Self.fixSpacing) {
            let fix = tracker.advance(latitude: Self.latitude, longitude: longitude, courseDegrees: Self.west)
            readings.append(try #require(fix).fractionComplete)
        }
        let first = try #require(readings.first)
        #expect(first.isApproximatelyEqual(to: 5.0 / 6, absoluteTolerance: 0.01), "the first step home")
        #expect(readings == readings.sorted(), "the way home reads as progress at every step: \(readings)")
    }

    @Test("Standing still before any course reads the same fix the same way every time")
    func standingStillIsSteady() throws {
        var tracker = WatchRouteTracker(Self.outAndBack)
        var readings: [Double] = []
        for _ in 0..<3 {
            let fix = tracker.advance(latitude: Self.latitude, longitude: Self.kilometerOut, courseDegrees: nil)
            readings.append(try #require(fix).fractionComplete)
        }

        #expect(Set(readings).count == 1, "\(readings)")
    }

    @Test("A course that is no bearing is no course either", arguments: [-1, Double.nan, .infinity])
    func aCourseThatIsNoBearingSetsNothing(courseDegrees: Double) throws {
        var tracker = WatchRouteTracker(Self.outAndBack)
        _ = tracker.advance(latitude: Self.latitude, longitude: Self.kilometerOut, courseDegrees: courseDegrees)

        let fix = tracker.advance(latitude: Self.latitude, longitude: Self.kilometerOut, courseDegrees: Self.west)
        let homeward = try #require(fix)
        #expect(homeward.fractionComplete.isApproximatelyEqual(to: 5.0 / 6, absoluteTolerance: 0.01))
    }

    // MARK: Fixture

    private static let latitude = 47.55
    private static let trailhead = 12.90
    /// Three kilometres east of the trailhead.
    private static let turn = 12.94
    /// A kilometre from the trailhead, a third of the way to the turn: the
    /// same ground on the way out and on the way home.
    private static let kilometerOut = trailhead + (turn - trailhead) / 3
    /// About 75 m between fixes.
    private static let fixSpacing = 0.001
    /// Clockwise from north, the way `CLLocation.course` reports it.
    private static let west = 270.0

    /// Out to the turn and back along the same line, about 6 km in all.
    private static var outAndBack: WatchTrailPackage {
        WatchTrailPackage(
            hikeID: UUID(),
            title: "Out and back",
            tintHex: "#1B7F3B",
            totalDistanceMeters: 0,
            points: [trailhead, turn, trailhead].map { WatchTrailPoint(latitude: latitude, longitude: $0) }
        )
    }
}
