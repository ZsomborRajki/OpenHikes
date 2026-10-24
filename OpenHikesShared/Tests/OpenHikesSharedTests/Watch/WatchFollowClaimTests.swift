//
//  WatchFollowClaimTests.swift
//  OpenHikesSharedTests
//
//  A trail map left while the watch records, and the Stop that follows it —
//  issue #996 — and a map asking for one trail while the watch holds another
//  (issue #1022). The watch has no test bundle, so the decision is here and
//  ``WatchModel`` only asks it.
//

import Foundation
@testable import OpenHikesShared
import Testing

@Suite("Watch follow claim")
struct WatchFollowClaimTests {
    private let map = UUID()
    private let trail = UUID()

    @Test("A map left during a recording does not restart the receiver at Stop")
    func mapLeftDuringRecordingIsNotRestoredAtStop() {
        var claim = WatchFollowClaim()
        #expect(claim.screenAppeared(map, asking: trail, holding: trail, recording: false) == .start)

        // Recording along the trail, the hiker goes back to the list and
        // swipes to the Record tab. The recording keeps its feed.
        #expect(claim.screenLeft(map, recording: true) == .unchanged)
        #expect(!claim.isClaimed)

        // Stop takes the receiver down, and no map is asking for it back.
        #expect(claim.recordingStopped(holding: trail) == .unchanged)
    }

    @Test("A map still open when the recording stops gets its feed back")
    func mapStillOpenIsRestoredAtStop() {
        var claim = WatchFollowClaim()
        _ = claim.screenAppeared(map, asking: trail, holding: trail, recording: false)

        #expect(claim.recordingStopped(holding: trail) == .start)
    }

    @Test("A map that comes back during the recording claims the feed again for after Stop")
    func mapReopenedDuringRecordingIsRestoredAtStop() {
        var claim = WatchFollowClaim()
        _ = claim.screenAppeared(map, asking: trail, holding: trail, recording: false)
        _ = claim.screenLeft(map, recording: true)

        // Under the recording, which already has the receiver.
        #expect(claim.screenAppeared(map, asking: trail, holding: trail, recording: true) == .unchanged)
        #expect(claim.recordingStopped(holding: trail) == .start)
    }

    @Test("Stop starts nothing for a map still waiting for its trail")
    func mapWaitingForItsTrailIsNotStartedAtStop() {
        var claim = WatchFollowClaim()
        // Opened under a recording, on a watch the phone has sent no trail.
        _ = claim.screenAppeared(map, asking: trail, holding: nil, recording: true)

        #expect(claim.recordingStopped(holding: nil) == .unchanged)
        #expect(claim.isClaimed)
        // The trail landing is the moment the feed is for.
        #expect(claim.trailArrived(holding: trail, recording: false) == .start)
    }

    @Test("Leaving with nothing recording stops the receiver")
    func leavingWhileIdleStopsTheFeed() {
        var claim = WatchFollowClaim()
        _ = claim.screenAppeared(map, asking: trail, holding: trail, recording: false)

        #expect(claim.screenLeft(map, recording: false) == .stop)
        #expect(!claim.isClaimed)
        #expect(claim.recordingStopped(holding: trail) == .unchanged)
    }

    @Test(
        "A map that leaves after the next one opened leaves that one its claim",
        arguments: [false, true]
    )
    func lateLeaveKeepsTheNewerScreensClaim(recording: Bool) {
        var claim = WatchFollowClaim()
        let next = UUID()
        _ = claim.screenAppeared(map, asking: trail, holding: trail, recording: recording)
        _ = claim.screenAppeared(next, asking: trail, holding: trail, recording: recording)

        #expect(claim.screenLeft(map, recording: recording) == .unchanged)
        #expect(claim.claimant == next)
        #expect(claim.recordingStopped(holding: trail) == .start)
        #expect(claim.screenLeft(next, recording: recording) == (recording ? .unchanged : .stop))
        #expect(!claim.isClaimed)
    }

    @Test("A map that leaves twice stops the receiver once")
    func secondLeaveChangesNothing() {
        var claim = WatchFollowClaim()
        _ = claim.screenAppeared(map, asking: trail, holding: trail, recording: false)
        _ = claim.screenLeft(map, recording: false)

        #expect(claim.screenLeft(map, recording: false) == .unchanged)
    }

    @Test("A map opened with no trail yet gets its feed when the trail lands")
    func trailLandingForAWaitingMapStartsTheFeed() {
        var claim = WatchFollowClaim()

        // Stopping a receiver nothing started costs nothing; see
        // `WatchFollowClaimTrailTests` for a map that opens over another's feed.
        #expect(claim.screenAppeared(map, asking: trail, holding: nil, recording: false) == .stop)
        #expect(claim.isClaimed)
        #expect(claim.trailArrived(holding: trail, recording: false) == .start)
    }

    @Test("A trail landing under a recording leaves the receiver to it")
    func trailLandingDuringRecordingChangesNothing() {
        var claim = WatchFollowClaim()
        _ = claim.screenAppeared(map, asking: trail, holding: nil, recording: true)

        #expect(claim.trailArrived(holding: trail, recording: true) == .unchanged)
    }

    @Test("A trail landing after its map has gone starts nothing")
    func trailLandingAfterTheMapLeftChangesNothing() {
        var claim = WatchFollowClaim()
        _ = claim.screenAppeared(map, asking: trail, holding: nil, recording: false)
        _ = claim.screenLeft(map, recording: false)

        #expect(claim.trailArrived(holding: trail, recording: false) == .unchanged)
    }

    @Test("Nothing claims the receiver before a map has opened")
    func noMapNoClaim() {
        var claim = WatchFollowClaim()

        #expect(!claim.isClaimed)
        #expect(claim.trailArrived(holding: trail, recording: false) == .unchanged)
        #expect(claim.recordingStopped(holding: trail) == .unchanged)
        #expect(claim.screenLeft(map, recording: false) == .unchanged)
    }
}
