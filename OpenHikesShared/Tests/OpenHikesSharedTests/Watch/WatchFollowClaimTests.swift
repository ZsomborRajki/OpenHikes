//
//  WatchFollowClaimTests.swift
//  OpenHikesSharedTests
//
//  A trail map left while the watch records, and the Stop that follows it —
//  issue #996. The watch has no test bundle, so the decision is here and
//  ``WatchModel`` only asks it.
//

@testable import OpenHikesShared
import Testing

@Suite("Watch follow claim")
struct WatchFollowClaimTests {
    @Test("A map left during a recording does not restart the receiver at Stop")
    func mapLeftDuringRecordingIsNotRestoredAtStop() {
        var claim = WatchFollowClaim()
        #expect(claim.screenAppeared(holdingTrail: true, recording: false) == .start)

        // Recording along the trail, the hiker goes back to the list and
        // swipes to the Record tab. The recording keeps its feed.
        #expect(claim.screenLeft(recording: true) == .unchanged)
        #expect(!claim.isClaimed)

        // Stop takes the receiver down, and no map is asking for it back.
        #expect(claim.recordingStopped() == .unchanged)
    }

    @Test("A map still open when the recording stops gets its feed back")
    func mapStillOpenIsRestoredAtStop() {
        var claim = WatchFollowClaim()
        _ = claim.screenAppeared(holdingTrail: true, recording: false)

        #expect(claim.recordingStopped() == .start)
    }

    @Test("A map that comes back during the recording claims the feed again for after Stop")
    func mapReopenedDuringRecordingIsRestoredAtStop() {
        var claim = WatchFollowClaim()
        _ = claim.screenAppeared(holdingTrail: true, recording: false)
        _ = claim.screenLeft(recording: true)

        // Under the recording, which already has the receiver.
        #expect(claim.screenAppeared(holdingTrail: true, recording: true) == .unchanged)
        #expect(claim.recordingStopped() == .start)
    }

    @Test("Leaving with nothing recording stops the receiver")
    func leavingWhileIdleStopsTheFeed() {
        var claim = WatchFollowClaim()
        _ = claim.screenAppeared(holdingTrail: true, recording: false)

        #expect(claim.screenLeft(recording: false) == .stop)
        #expect(!claim.isClaimed)
        #expect(claim.recordingStopped() == .unchanged)
    }

    @Test("A map opened with no trail yet gets its feed when the trail lands")
    func trailLandingForAWaitingMapStartsTheFeed() {
        var claim = WatchFollowClaim()

        #expect(claim.screenAppeared(holdingTrail: false, recording: false) == .unchanged)
        #expect(claim.isClaimed)
        #expect(claim.trailArrived(recording: false) == .start)
    }

    @Test("A trail landing under a recording leaves the receiver to it")
    func trailLandingDuringRecordingChangesNothing() {
        var claim = WatchFollowClaim()
        _ = claim.screenAppeared(holdingTrail: false, recording: true)

        #expect(claim.trailArrived(recording: true) == .unchanged)
    }

    @Test("A trail landing after its map has gone starts nothing")
    func trailLandingAfterTheMapLeftChangesNothing() {
        var claim = WatchFollowClaim()
        _ = claim.screenAppeared(holdingTrail: false, recording: false)
        _ = claim.screenLeft(recording: false)

        #expect(claim.trailArrived(recording: false) == .unchanged)
    }

    @Test("Nothing claims the receiver before a map has opened")
    func noMapNoClaim() {
        let claim = WatchFollowClaim()

        #expect(!claim.isClaimed)
        #expect(claim.trailArrived(recording: false) == .unchanged)
        #expect(claim.recordingStopped() == .unchanged)
    }
}
