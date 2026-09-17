//
//  SignificantLocationRegistrationTests.swift
//  OpenHikesTests
//
//  What the app tells CoreLocation when two unrelated features want the same
//  app-scoped registration, which is the thing neither feature's own suite can
//  see: every stub in `BackgroundTrackingTests` and `LocationPublishingTests`
//  belongs to one consumer and answers only for it.
//

import CoreLocation
@testable import OpenHikes
import Testing

@Suite("Significant location registration")
struct SignificantLocationRegistrationTests {
    private let issuer = StubLocationMonitor()
    private let registration: SignificantLocationRegistration
    private let movementFeed: SignificantLocationRegistration.Client
    private let trailMatching: SignificantLocationRegistration.Client
    private let movementFeedMonitor = StubLocationMonitor()
    private let trailMatchingMonitor = StubLocationMonitor()

    init() {
        registration = SignificantLocationRegistration(monitor: issuer)
        movementFeed = registration.client(for: .movementFeed, monitor: movementFeedMonitor)
        trailMatching = registration.client(for: .trailMatching, monitor: trailMatchingMonitor)
    }

    /// The load-bearing one. A launch inherits whatever registration the
    /// previous process left — that is what lets significant-change monitoring
    /// relaunch an app, and why a force-quit does not clear it — so the first
    /// stand-down has to reach CoreLocation even though nothing in *this*
    /// process ever armed anything. A registration tracked as a plain `Bool`
    /// starting at `false` treats it as a no-op and leaves the leak standing.
    @Test("the first stand-down reaches CoreLocation though this process never armed")
    func firstStandDownIsIssued() {
        trailMatching.stopSignificantLocationUpdates()

        #expect(issuer.stopCount == 1)
        #expect(registration.armed.isEmpty)
    }

    @Test("the first arming reaches CoreLocation too")
    func firstArmIsIssued() {
        movementFeed.startSignificantLocationUpdates()

        #expect(issuer.startCount == 1)
        #expect(registration.armed == [.movementFeed])
    }

    /// `syncMonitoring` re-states its wish on every authorization change,
    /// every selection and every region crossing, and the scene re-states the
    /// feed's on every return to the foreground.
    @Test("re-stating a wish costs no further calls")
    func armingIsIdempotent() {
        movementFeed.startSignificantLocationUpdates()
        movementFeed.startSignificantLocationUpdates()
        movementFeed.startSignificantLocationUpdates()

        #expect(issuer.startCount == 1)
    }

    @Test("a second reason arming does not register a second time")
    func secondReasonDoesNotRegisterAgain() {
        movementFeed.startSignificantLocationUpdates()
        trailMatching.startSignificantLocationUpdates()

        #expect(issuer.startCount == 1)
        #expect(registration.armed == [.movementFeed, .trailMatching])
    }

    /// The bug this type exists for, in the direction that broke the weather
    /// badge: the tracker re-syncs — a selection, an authorization change, a
    /// region crossing — decides it has nothing to do, and calls stop on a
    /// registration the foreground feed is relying on.
    @Test("one reason standing down leaves the other's registration alone")
    func standingOneReasonDownKeepsTheOther() {
        movementFeed.startSignificantLocationUpdates()
        trailMatching.startSignificantLocationUpdates()

        trailMatching.stopSignificantLocationUpdates()

        #expect(issuer.isMonitoring)
        #expect(issuer.stopCount == 0)
        #expect(registration.armed == [.movementFeed])
    }

    /// And the direction that left the app registered after the scene had
    /// resigned: the feed's own flag said it had stood down, and it had — but
    /// the tracker was still holding the same registration up.
    @Test("the registration comes down only when the last reason does")
    func lastReasonStandsTheRegistrationDown() {
        movementFeed.startSignificantLocationUpdates()
        trailMatching.startSignificantLocationUpdates()

        movementFeed.stopSignificantLocationUpdates()
        #expect(issuer.isMonitoring)

        trailMatching.stopSignificantLocationUpdates()
        #expect(!issuer.isMonitoring)
        #expect(issuer.stopCount == 1)
        #expect(registration.armed.isEmpty)
    }

    @Test("re-arming after the last reason stood down registers again")
    func armingAfterAFullStandDownRegistersAgain() {
        movementFeed.startSignificantLocationUpdates()
        movementFeed.stopSignificantLocationUpdates()

        movementFeed.startSignificantLocationUpdates()

        #expect(issuer.startCount == 2)
        #expect(issuer.isMonitoring)
    }

    /// Delivery is still per-manager: CoreLocation hands a significant change
    /// to every manager in the process that has a delegate, and each consumer
    /// needs its own. Only the decision is shared, so a client must put the
    /// delegate it is given on its own manager and not on the issuer's.
    @Test("each client's delegate goes on its own manager")
    func delegatesStayWithTheirOwnManager() {
        let feedDelegate = StubMonitorDelegate()
        let trackerDelegate = StubMonitorDelegate()

        movementFeed.monitorDelegate = feedDelegate
        trailMatching.monitorDelegate = trackerDelegate

        #expect(movementFeedMonitor.monitorDelegateObject === feedDelegate)
        #expect(trailMatchingMonitor.monitorDelegateObject === trackerDelegate)
        #expect(issuer.monitorDelegateObject == nil)
        #expect(movementFeed.monitorDelegate === feedDelegate)
    }

    /// Authorization is a question about the app, but it is answered by the
    /// consumer's own manager — the one whose delegate will carry the change —
    /// so that `authorizationChanged()` reads back from the same object that
    /// told it something had changed.
    @Test("a client answers authorization from its own manager")
    func authorizationComesFromTheClientsManager() {
        trailMatchingMonitor.authorization = .always
        movementFeedMonitor.authorization = .whenInUse

        #expect(trailMatching.isAlwaysAuthorized)
        #expect(!trailMatching.canRequestAlwaysAccess)
        #expect(!movementFeed.isAlwaysAuthorized)
        #expect(movementFeed.canRequestAlwaysAccess)

        trailMatching.requestAlwaysAccess()
        #expect(trailMatchingMonitor.alwaysAccessRequests == 1)
        #expect(movementFeedMonitor.alwaysAccessRequests == 0)
    }

    /// A stand-in for the delegate each consumer is: this suite is about where
    /// the reference lands, not about what is delivered to it.
    private final class StubMonitorDelegate: NSObject, CLLocationManagerDelegate {}
}
