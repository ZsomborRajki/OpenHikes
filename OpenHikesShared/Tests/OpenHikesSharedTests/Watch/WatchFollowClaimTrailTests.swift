//
//  WatchFollowClaimTrailTests.swift
//  OpenHikesSharedTests
//
//  A map asking for one trail while the watch holds another — issue #1022.
//  The waiting view draws nothing a fix could move, so the feed must not run
//  under it until its own trail lands. A trail of one point is held too, but
//  draws the same waiting view, so it is no trail to follow.
//

import Foundation
@testable import OpenHikesShared
import Testing

@Suite("Watch follow claim: whose trail")
struct WatchFollowClaimTrailTests {
    private let map = UUID()
    private let held = UUID()
    private let asked = UUID()

    @Test("A map for another trail than the one held does not start the feed")
    func mapForAnotherTrailStartsNothing() {
        var claim = WatchFollowClaim()

        #expect(claim.screenAppeared(map, asking: asked, holding: held, recording: false) == .stop)
        #expect(claim.claimedHikeID == asked)
        // Its own trail landing is what it was waiting for.
        #expect(claim.trailArrived(holding: asked, recording: false) == .start)
    }

    @Test("Stop does not start the feed for a map waiting for another trail")
    func stopUnderAWaitingMapStartsNothing() {
        var claim = WatchFollowClaim()
        // Opened under a recording along the held trail, for a different one
        // the phone, out of range, has not sent.
        _ = claim.screenAppeared(map, asking: asked, holding: held, recording: true)

        #expect(claim.recordingStopped(holding: held) == .unchanged)
        #expect(claim.trailArrived(holding: asked, recording: false) == .start)
    }

    @Test("A map that opens over another trail's feed stops it")
    func mapOpeningOverAnotherTrailsFeedStopsIt() {
        var claim = WatchFollowClaim()
        let previous = UUID()
        #expect(claim.screenAppeared(previous, asking: held, holding: held, recording: false) == .start)

        // The next map arrives before the previous one's `onDisappear`, which
        // then leaves the new claim alone.
        #expect(claim.screenAppeared(map, asking: asked, holding: held, recording: false) == .stop)
        #expect(claim.screenLeft(previous, recording: false) == .unchanged)
        #expect(claim.claimant == map)
    }

    @Test("A held trail replaced by one the map did not ask for stops the feed")
    func heldTrailReplacedByAnotherStopsTheFeed() {
        var claim = WatchFollowClaim()
        _ = claim.screenAppeared(map, asking: held, holding: held, recording: false)

        #expect(claim.trailArrived(holding: asked, recording: false) == .stop)
        // Or by nothing a map can follow, such as a line of one point.
        #expect(claim.trailArrived(holding: nil, recording: false) == .stop)
    }

    @Test("Another trail landing under a recording leaves the receiver to it")
    func anotherTrailLandingDuringRecordingChangesNothing() {
        var claim = WatchFollowClaim()
        _ = claim.screenAppeared(map, asking: asked, holding: nil, recording: true)

        #expect(claim.trailArrived(holding: held, recording: true) == .unchanged)
    }

    @Test("A map's leaving forgets the trail it asked for")
    func leavingForgetsTheTrail() {
        var claim = WatchFollowClaim()
        _ = claim.screenAppeared(map, asking: asked, holding: nil, recording: false)
        _ = claim.screenLeft(map, recording: false)

        #expect(claim.claimedHikeID == nil)
        #expect(claim.trailArrived(holding: asked, recording: false) == .unchanged)
    }

    @Test("A trail of one point is held, but is not one a map can follow")
    func onePointTrailIsNotFollowable() {
        let place = Self.trail(asked, longitudes: [Self.trailhead])
        let line = Self.trail(asked, longitudes: [Self.trailhead, Self.end])
        #expect(place.followableHikeID == nil)
        #expect(line.followableHikeID == asked)

        // Its map draws the waiting view and its tracker has nothing to
        // match, so a feed started for it would run under a screen that
        // shows none of it.
        var claim = WatchFollowClaim()
        #expect(claim.screenAppeared(map, asking: asked, holding: place.followableHikeID, recording: false) == .stop)
        #expect(claim.recordingStopped(holding: place.followableHikeID) == .unchanged)
        // The same trail as a line is what the map is waiting for.
        #expect(claim.trailArrived(holding: line.followableHikeID, recording: false) == .start)
    }

    // MARK: Fixture

    private static let latitude = 47.55
    private static let trailhead = 12.90
    private static let end = 12.94

    private static func trail(_ hikeID: UUID, longitudes: [Double]) -> WatchTrailPackage {
        WatchTrailPackage(
            hikeID: hikeID,
            title: "Asked for",
            tintHex: "#1B7F3B",
            totalDistanceMeters: 0,
            points: longitudes.map { WatchTrailPoint(latitude: latitude, longitude: $0) }
        )
    }
}
