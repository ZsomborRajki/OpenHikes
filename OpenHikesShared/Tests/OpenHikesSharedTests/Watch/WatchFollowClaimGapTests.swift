//
//  WatchFollowClaimGapTests.swift
//  OpenHikesSharedTests
//
//  The feed coming back after the two gaps the app's return to the screen
//  (#1054) left alone: a map opened when none was showing its trail, and a
//  recording stopped while paused. Nothing was matched in either, so the
//  position is let go, as a return lets it go. A map that takes over from
//  another one showing the same trail had no gap, and keeps it.
//

import Foundation
@testable import OpenHikesShared
import RealModule
import Testing

@Suite("Watch follow claim: after a gap")
struct WatchFollowClaimGapTests {
    private let map = UUID()
    private let trail = UUID()

    @Test("A map opened again after none was open lets go of the position")
    func reopenedMapRestarts() {
        var claim = WatchFollowClaim()
        _ = claim.screenAppeared(map, asking: trail, holding: trail, recording: false)
        #expect(claim.screenLeft(map, recording: false) == .stop)

        #expect(claim.screenAppeared(UUID(), asking: trail, holding: trail, recording: false) == .restart)
    }

    @Test("A map that takes over from one showing the same trail keeps the feed as it stands")
    func mapTakingOverKeepsThePosition() {
        var claim = WatchFollowClaim()
        let next = UUID()
        _ = claim.screenAppeared(map, asking: trail, holding: trail, recording: false)

        // The next map arrives before this one's `onDisappear`.
        #expect(claim.screenAppeared(next, asking: trail, holding: trail, recording: false) == .start)
        #expect(claim.screenLeft(map, recording: false) == .unchanged)
    }

    @Test("A map still open when a paused recording stops gets its feed back as a restart")
    func stopWhilePausedRestarts() {
        var claim = WatchFollowClaim()
        _ = claim.screenAppeared(map, asking: trail, holding: trail, recording: true)

        #expect(claim.recordingStopped(holding: trail, whilePaused: true) == .restart)
        #expect(claim.recordingStopped(holding: trail, whilePaused: false) == .start)
    }

    @Test("A paused recording stopping starts nothing with no map asking, or off screen")
    func stopWhilePausedWithNothingAskingStartsNothing() {
        var gone = WatchFollowClaim()
        _ = gone.screenAppeared(map, asking: trail, holding: trail, recording: true)
        _ = gone.screenLeft(map, recording: true)
        var offScreen = WatchFollowClaim()
        _ = offScreen.screenAppeared(map, asking: trail, holding: trail, recording: true)
        _ = offScreen.appLeftScreen(recording: true)

        #expect(gone.recordingStopped(holding: trail, whilePaused: true) == .unchanged)
        #expect(offScreen.recordingStopped(holding: trail, whilePaused: true) == .unchanged)
    }

    /// The model's half, through the real tracker: a kilometre out the map
    /// closes, the hiker walks on to the turn and back to the same ground,
    /// and opens the map again.
    @Test("A map opened again on the way home reads the way home")
    func reopenedMapReadsTheWayHome() throws {
        var claim = WatchFollowClaim()
        var tracker = WatchRouteTracker(Self.outAndBack(trail))
        _ = claim.screenAppeared(map, asking: trail, holding: trail, recording: false)
        for longitude in stride(from: Self.trailhead, through: Self.kilometerOut, by: Self.fixSpacing) {
            _ = tracker.advance(latitude: Self.latitude, longitude: longitude, courseDegrees: Self.east)
        }
        _ = claim.screenLeft(map, recording: false)

        let change = claim.screenAppeared(UUID(), asking: trail, holding: trail, recording: false)
        #expect(change == .restart)
        var kept = tracker
        // What `WatchModel` does with a restart.
        if change == .restart { tracker.forgetPosition() }
        // Hoisted out of `#require`, whose closure cannot call a mutating
        // member.
        let fix = tracker.advance(latitude: Self.latitude, longitude: Self.kilometerOut, courseDegrees: Self.west)
        let homeward = try #require(fix)
        #expect(homeward.fractionComplete.isApproximatelyEqual(to: 5.0 / 6, absoluteTolerance: 0.01))

        // Kept, the window around the last fix holds only the outbound leg
        // here, and the hiker reads a sixth of the way along, and falling,
        // for the whole way home.
        let stale = kept.advance(latitude: Self.latitude, longitude: Self.kilometerOut, courseDegrees: Self.west)
        let outbound = try #require(stale)
        #expect(outbound.fractionComplete.isApproximatelyEqual(to: 1.0 / 6, absoluteTolerance: 0.01))
    }

    /// Stop is on the Record tab, and swiping to it takes the map off screen,
    /// so the map a hiker swipes back to after Stop restarts — see
    /// `WatchFollowClaim`'s header.
    @Test("The map swiped back to after a Stop at the trailhead reads the walk finished")
    func mapAfterStopAtTheTrailheadReadsFinished() throws {
        var claim = WatchFollowClaim()
        var tracker = WatchRouteTracker(Self.outAndBack(trail))
        _ = claim.screenAppeared(map, asking: trail, holding: trail, recording: false)
        // Recorded out to the turn and home: a recording's fixes reach the
        // tracker whether or not a map is open.
        for longitude in stride(from: Self.trailhead, through: Self.turn, by: Self.fixSpacing) {
            _ = tracker.advance(latitude: Self.latitude, longitude: longitude, courseDegrees: Self.east)
        }
        for longitude in stride(from: Self.turn, through: Self.trailhead, by: -Self.fixSpacing) {
            _ = tracker.advance(latitude: Self.latitude, longitude: longitude, courseDegrees: Self.west)
        }

        // To the Record tab for Stop, and back to the map.
        _ = claim.screenLeft(map, recording: true)
        #expect(claim.recordingStopped(holding: trail, whilePaused: false) == .unchanged)
        let change = claim.screenAppeared(map, asking: trail, holding: trail, recording: false)
        #expect(change == .restart)
        if change == .restart { tracker.forgetPosition() }

        // Standing at the trailhead, which is both the start and the finish.
        let fix = tracker.advance(latitude: Self.latitude, longitude: Self.trailhead, courseDegrees: nil)
        let finished = try #require(fix)
        #expect(finished.fractionComplete.isApproximatelyEqual(to: 1, absoluteTolerance: 0.01))
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

    /// Out to the turn and back along the same line, about 6 km in all.
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
