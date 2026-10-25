//
//  WatchFollowClaimOnScreenTests.swift
//  OpenHikesSharedTests
//
//  The app leaving the screen with a trail map still pushed — issue #1022.
//  The map is told nothing, so the claim hears the scene go and come back:
//  following without a recording shows a live position while the app is on
//  screen and nothing behind it. Coming back is a restart, because the hiker
//  walked on while nothing was matched.
//

import Foundation
@testable import OpenHikesShared
import RealModule
import Testing

@Suite("Watch follow claim: on screen")
struct WatchFollowClaimOnScreenTests {
    private let map = UUID()
    private let trail = UUID()

    @Test("Leaving the screen stops the feed and keeps the claim for the way back")
    func leavingStopsTheFeedAndReturningRestartsIt() {
        var claim = WatchFollowClaim()
        _ = claim.screenAppeared(map, asking: trail, holding: trail, recording: false)

        #expect(claim.appLeftScreen(recording: false) == .stop)
        #expect(claim.isClaimed)
        #expect(!claim.isAppOnScreen)
        #expect(claim.appReturned(holding: trail, recording: false) == .restart)
        #expect(claim.isAppOnScreen)
    }

    @Test("Coming back lets go of where the hiker was, so the way home reads as the way home")
    func returningLetsGoOfThePosition() throws {
        var claim = WatchFollowClaim()
        var tracker = WatchRouteTracker(Self.outAndBack(trail))
        _ = claim.screenAppeared(map, asking: trail, holding: trail, recording: false)
        // A kilometre out, heading for the turn.
        for longitude in stride(from: Self.trailhead, through: Self.kilometerOut, by: Self.fixSpacing) {
            _ = tracker.advance(latitude: Self.latitude, longitude: longitude, courseDegrees: Self.east)
        }
        _ = claim.appLeftScreen(recording: false)

        // Behind the watch face, with the feed down: on to the turn, and back
        // to a kilometre from the trailhead, the ground the app left on.
        let change = claim.appReturned(holding: trail, recording: false)
        #expect(change == .restart)
        var anchored = tracker
        // What `WatchModel` does with a restart.
        if change == .restart { tracker.forgetPosition() }
        // Hoisted out of `#require`, whose closure cannot call a mutating
        // member.
        let fix = tracker.advance(latitude: Self.latitude, longitude: Self.kilometerOut, courseDegrees: Self.west)
        let homeward = try #require(fix)
        #expect(homeward.isOnTrail)
        #expect(homeward.fractionComplete.isApproximatelyEqual(to: 5.0 / 6, absoluteTolerance: 0.01))

        // What makes the reading above worth checking: kept, the anchor's
        // window holds only the outbound leg here, so the course has nothing
        // to choose between, and the hiker reads a sixth of the way along,
        // and falling, for the whole way home.
        let kept = anchored.advance(latitude: Self.latitude, longitude: Self.kilometerOut, courseDegrees: Self.west)
        let outbound = try #require(kept)
        #expect(outbound.fractionComplete.isApproximatelyEqual(to: 1.0 / 6, absoluteTolerance: 0.01))
    }

    @Test("Returning starts nothing once the map has gone")
    func returningWithNoMapStartsNothing() {
        var claim = WatchFollowClaim()
        _ = claim.screenAppeared(map, asking: trail, holding: trail, recording: false)
        _ = claim.appLeftScreen(recording: false)
        _ = claim.screenLeft(map, recording: false)

        #expect(claim.appReturned(holding: trail, recording: false) == .unchanged)
    }

    @Test("Returning starts nothing for a map still waiting for its trail")
    func returningUnderAWaitingMapStartsNothing() {
        var claim = WatchFollowClaim()
        _ = claim.screenAppeared(map, asking: trail, holding: nil, recording: false)
        _ = claim.appLeftScreen(recording: false)

        #expect(claim.appReturned(holding: UUID(), recording: false) == .unchanged)
        #expect(claim.trailArrived(holding: trail, recording: false) == .start)
    }

    @Test("A recording keeps its receiver when the app leaves the screen, and on return")
    func recordingKeepsItsFeedOffScreen() {
        var claim = WatchFollowClaim()
        _ = claim.screenAppeared(map, asking: trail, holding: trail, recording: true)

        #expect(claim.appLeftScreen(recording: true) == .unchanged)
        #expect(claim.appReturned(holding: trail, recording: true) == .unchanged)
    }

    @Test("A recording that ends off screen leaves the feed for the app's return")
    func recordingEndingOffScreenWaitsForTheReturn() {
        var claim = WatchFollowClaim()
        _ = claim.screenAppeared(map, asking: trail, holding: trail, recording: true)
        _ = claim.appLeftScreen(recording: true)

        // A workout session that fails behind the watch face ends it.
        #expect(claim.recordingStopped(holding: trail, whilePaused: false) == .unchanged)
        #expect(claim.appReturned(holding: trail, recording: false) == .restart)
    }

    @Test("Nothing that happens off screen starts the feed")
    func offScreenMomentsStartNothing() {
        var claim = WatchFollowClaim()
        _ = claim.screenAppeared(map, asking: trail, holding: nil, recording: false)
        _ = claim.appLeftScreen(recording: false)

        #expect(claim.trailArrived(holding: trail, recording: false) == .unchanged)
        #expect(claim.screenAppeared(UUID(), asking: trail, holding: trail, recording: false) == .unchanged)
        #expect(claim.appReturned(holding: trail, recording: false) == .restart)
    }

    @Test("Each change of scene is answered once")
    func repeatedPhasesChangeNothing() {
        var claim = WatchFollowClaim()
        _ = claim.screenAppeared(map, asking: trail, holding: trail, recording: false)

        // The first phase, reported at launch, is on screen already.
        #expect(claim.appReturned(holding: trail, recording: false) == .unchanged)
        _ = claim.appLeftScreen(recording: false)
        #expect(claim.appLeftScreen(recording: false) == .unchanged)
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
    private static let east = 90.0
    private static let west = 270.0

    /// Out to the turn and back along the same line, about 6 km in all: the
    /// shape whose two legs a stale anchor confuses.
    private static func outAndBack(_ hikeID: UUID) -> WatchTrailPackage {
        WatchTrailPackage(
            hikeID: hikeID,
            title: "Out and back",
            tintHex: "#1B7F3B",
            totalDistanceMeters: 0,
            points: [trailhead, turn, trailhead].map { WatchTrailPoint(latitude: latitude, longitude: $0) }
        )
    }
}
