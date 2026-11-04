//
//  WatchLinkActivationTests.swift
//  OpenHikesSharedTests
//
//  What a launch may hand `WCSession` before activation has completed, and
//  what an activation that succeeds or fails does with what waited for it.
//

import Foundation
@testable import OpenHikesShared
import Testing

@Suite("Watch link activation")
struct WatchLinkActivationTests {
    private static let walk = UUID(uuidString: "6A2F9C1E-0B7D-4E1A-9C3F-2D8B5E7A1C40") ?? UUID()
    private static let hike = UUID(uuidString: "0F6D2B7A-3C1E-4D58-A9B2-71E4C6D80F13") ?? UUID()
    private static let now = Date(timeIntervalSince1970: 1_758_000_000)

    /// A launch that has called `activate()` and heard nothing back.
    private static func activating() -> WatchLinkActivation {
        var activation = WatchLinkActivation()
        _ = activation.begin()
        return activation
    }

    private static func activated() -> WatchLinkActivation {
        var activation = activating()
        _ = activation.finished(activated: true)
        return activation
    }

    /// Counts what reaches the session, as `PhoneLink.transfer` would.
    private final class Session {
        var submitted = 0

        func take() -> Bool {
            submitted += 1
            return true
        }
    }

    // MARK: Before activation

    @Test("nothing may be transferred before activate() or while it is in flight")
    func transfersWaitForTheCallback() {
        #expect(!WatchLinkActivation().allowsTransfers)
        #expect(!Self.activating().allowsTransfers)
        #expect(Self.activated().allowsTransfers)
    }

    @Test("a walk offered during activation reaches no session and is not left crossing")
    func walkDuringActivationIsNotHandedOver() {
        let session = Session()
        var delivery = WatchWalkDelivery()
        let went = delivery.offer(
            Self.walk, at: Self.now, on: Self.activating(), isCrossing: { false }, transfer: session.take
        )
        #expect(!went)
        #expect(session.submitted == 0)
        #expect(delivery.hasNeverOffered(Self.walk))
        #expect(delivery.shouldOffer(Self.walk, at: Self.now))
    }

    @Test("a drain during activation neither reads a walk nor looks through the session's queue")
    func drainDuringActivationAsksNothing() {
        var delivery = WatchWalkDelivery()
        var asked = false
        let due = delivery.isDue(Self.walk, at: Self.now, on: Self.activating()) {
            asked = true
            return false
        }
        #expect(!due)
        #expect(!asked)
    }

    // MARK: Activation succeeds

    @Test("a held library request and trail request are released together")
    func heldRequestsAreReleased() throws {
        let request = WatchTrailRequest(hikeID: Self.hike)
        var activation = Self.activating()
        activation.holdLibraryRequest()
        activation.hold(request)

        let answer = activation.finished(activated: true)
        let release = try #require(answer)
        #expect(release.asksForLibrary)
        #expect(release.trailRequest == request)
        #expect(activation.allowsTransfers)
    }

    @Test("a release with nothing held is still the moment to drain the walk queue")
    func nothingHeldStillReleases() {
        var activation = Self.activating()
        let release = activation.finished(activated: true)
        #expect(release == WatchLinkActivation.Release(asksForLibrary: false, trailRequest: nil))
    }

    @Test("the launch and the scene each asking for the library release one request")
    func repeatedLibraryRequestsAreOne() {
        var activation = Self.activating()
        activation.holdLibraryRequest()
        activation.holdLibraryRequest()
        let release = activation.finished(activated: true)
        #expect(release?.asksForLibrary == true)
    }

    @Test("the latest trail request replaces the one held, whole, so its answer still matches")
    func latestTrailRequestWins() {
        let earlier = WatchTrailRequest(hikeID: Self.hike)
        let latest = WatchTrailRequest(hikeID: Self.hike)
        var activation = Self.activating()
        activation.hold(earlier)
        activation.hold(latest)
        let release = activation.finished(activated: true)
        #expect(release?.trailRequest?.id == latest.id)
    }

    @Test("an answer repeated after a success releases nothing and drains nothing")
    func secondSuccessReleasesNothing() {
        var activation = Self.activating()
        activation.holdLibraryRequest()
        _ = activation.finished(activated: true)
        let again = activation.finished(activated: true)
        #expect(again == nil)
        #expect(activation.allowsTransfers)
    }

    @Test("what one activation released is not released again by a later one")
    func releasedRequestsAreGone() {
        var activation = Self.activating()
        activation.holdLibraryRequest()
        activation.hold(WatchTrailRequest(hikeID: Self.hike))
        _ = activation.finished(activated: true)
        _ = activation.finished(activated: false)
        _ = activation.begin()
        let later = activation.finished(activated: true)
        #expect(later == WatchLinkActivation.Release(asksForLibrary: false, trailRequest: nil))
    }

    @Test("a walk turned away during activation goes once when the drain after it comes")
    func walkGoesOnceAfterActivation() {
        let session = Session()
        var delivery = WatchWalkDelivery()
        var activation = Self.activating()
        _ = delivery.offer(Self.walk, at: Self.now, on: activation, isCrossing: { false }, transfer: session.take)
        _ = activation.finished(activated: true)

        let first = delivery.offer(
            Self.walk, at: Self.now, on: activation, isCrossing: { false }, transfer: session.take
        )
        let second = delivery.offer(
            Self.walk, at: Self.now, on: activation, isCrossing: { true }, transfer: session.take
        )
        #expect(first)
        #expect(!second)
        #expect(session.submitted == 1)
        #expect(!delivery.shouldOffer(Self.walk, at: Self.now))
    }

    @Test("a transfer an earlier process left crossing is adopted, once the queue can be read")
    func crossingTransferIsAdoptedAfterActivation() {
        let session = Session()
        var delivery = WatchWalkDelivery()
        let went = delivery.offer(
            Self.walk, at: Self.now, on: Self.activated(), isCrossing: { true }, transfer: session.take
        )
        #expect(!went)
        #expect(session.submitted == 0)
        #expect(!delivery.hasNeverOffered(Self.walk))
    }

    @Test("a walk that would not encode is not left crossing, even on an active session")
    func refusedTransferIsNotHandedOver() {
        var delivery = WatchWalkDelivery()
        let went = delivery.offer(
            Self.walk, at: Self.now, on: Self.activated(), isCrossing: { false }, transfer: { false }
        )
        #expect(!went)
        #expect(delivery.hasNeverOffered(Self.walk))
    }

    // MARK: Activation fails

    @Test("a failed activation opens nothing and releases nothing")
    func failureReleasesNothing() {
        var activation = Self.activating()
        activation.holdLibraryRequest()
        let release = activation.finished(activated: false)
        #expect(release == nil)
        #expect(!activation.allowsTransfers)
    }

    @Test("a finished walk stays retryable through a failed activation and goes on the retry")
    func walkSurvivesFailedActivation() {
        let session = Session()
        var delivery = WatchWalkDelivery()
        var activation = Self.activating()
        _ = activation.finished(activated: false)

        let refused = delivery.offer(
            Self.walk, at: Self.now, on: activation, isCrossing: { false }, transfer: session.take
        )
        #expect(!refused)
        #expect(session.submitted == 0)
        #expect(delivery.hasNeverOffered(Self.walk))

        _ = activation.begin()
        _ = activation.finished(activated: true)
        let went = delivery.offer(
            Self.walk, at: Self.now, on: activation, isCrossing: { false }, transfer: session.take
        )
        #expect(went)
        #expect(session.submitted == 1)
    }

    @Test("what a failed activation held is released by the retry that succeeds")
    func retryReleasesWhatFailureKept() throws {
        let request = WatchTrailRequest(hikeID: Self.hike)
        var activation = Self.activating()
        activation.holdLibraryRequest()
        activation.hold(request)
        _ = activation.finished(activated: false)

        let retries = activation.begin()
        #expect(retries)
        let answer = activation.finished(activated: true)
        let release = try #require(answer)
        #expect(release.asksForLibrary)
        #expect(release.trailRequest == request)
    }

    @Test("activate() is called to start and after a failure, and at no other time")
    func beginAnswersOncePerAttempt() {
        var activation = WatchLinkActivation()
        let starts = activation.begin()
        let whileInFlight = activation.begin()
        _ = activation.finished(activated: false)
        let afterFailure = activation.begin()
        _ = activation.finished(activated: true)
        let onceActivated = activation.begin()
        #expect(starts)
        #expect(!whileInFlight)
        #expect(afterFailure)
        #expect(!onceActivated)
    }
}
