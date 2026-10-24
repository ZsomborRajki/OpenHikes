//
//  WatchFollowClaimOnScreenTests.swift
//  OpenHikesSharedTests
//
//  The app leaving the screen with a trail map still pushed — issue #1022.
//  The map is told nothing, so the claim hears the scene go and come back:
//  following without a recording shows a live position while the app is on
//  screen and nothing behind it.
//

import Foundation
@testable import OpenHikesShared
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
        #expect(claim.appReturned(holding: trail, recording: false) == .start)
        #expect(claim.isAppOnScreen)
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
        #expect(claim.recordingStopped(holding: trail) == .unchanged)
        #expect(claim.appReturned(holding: trail, recording: false) == .start)
    }

    @Test("Nothing that happens off screen starts the feed")
    func offScreenMomentsStartNothing() {
        var claim = WatchFollowClaim()
        _ = claim.screenAppeared(map, asking: trail, holding: nil, recording: false)
        _ = claim.appLeftScreen(recording: false)

        #expect(claim.trailArrived(holding: trail, recording: false) == .unchanged)
        #expect(claim.screenAppeared(UUID(), asking: trail, holding: trail, recording: false) == .unchanged)
        #expect(claim.appReturned(holding: trail, recording: false) == .start)
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
}
