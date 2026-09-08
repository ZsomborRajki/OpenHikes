//
//  LifecycleObservationTokenTests.swift
//  OpenHikesTests
//
//  Three pieces of Foundation behaviour that `MapView.Coordinator`,
//  `HikeLiveActivityController` and `MovementReminderController` all now rest
//  on, none of which any of their own suites can see.
//
//  All three replaced a named `Notification.Name` registration with a typed
//  `UIApplication.DidBecomeActiveMessage` / `DidEnterBackgroundMessage` /
//  `WillEnterForegroundMessage` observer, and with it the manual isolation
//  plumbing the old `NSObjectProtocol` tokens needed — the map lost its
//  `deinit` outright. What makes that safe is that a
//  `NotificationCenter.ObservationToken` *owns* its registration: observation
//  ends when the token goes out of scope. That is documented rather than
//  incidental, but it is the opposite of how a block-based observer behaves,
//  it is invisible at the call site, and getting it backwards costs either a
//  leak or an observer that was never live. So it is pinned here, as the
//  observation-behaviour pins in `RenderIsolationTests+Observation.swift` are,
//  and for the same reason: this is the tripwire if the runtime ever changes.
//
//  The third is the interoperability #217 asks for. UIKit still posts the
//  untyped notification, and the whole app is on the typed side of it now, so
//  every one of those observers depends on the bridge in between — which is
//  also what lets a test drive a lifecycle gate at all, having no way to
//  background a test host.
//

#if os(iOS)
import Foundation
import Testing
import UIKit

@MainActor
@Suite("Lifecycle observation tokens")
struct LifecycleObservationTokenTests {
    /// A centre of its own per test. The typed lifecycle messages are the ones
    /// the app really observes, and posting them on `.default` would reach
    /// every controller and map coordinator alive in the test host.
    private static func center() -> NotificationCenter { NotificationCenter() }

    /// Counts deliveries without being a `@MainActor` closure's captured
    /// `inout`.
    @MainActor
    final class Deliveries {
        private(set) var count = 0

        func record() { count += 1 }
    }

    /// The half that makes `scenePhaseObservers`, `lifecycleObservers` and
    /// every other stored token array load-bearing rather than decorative:
    /// a token nobody keeps takes its observer down with it.
    ///
    /// Goes red the day dropping a token stops deregistering — at which point
    /// three controllers are leaking an observer each and the comments above
    /// their storage are wrong.
    @Test("a token nobody keeps stops observing")
    func aDroppedTokenEndsItsObservation() {
        let center = Self.center()
        let deliveries = Deliveries()

        do {
            let token = center.addObserver(
                for: UIApplication.DidBecomeActiveMessage.self
            ) { _ in deliveries.record() }
            _ = token
            center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        }
        #expect(deliveries.count == 1, "precondition: the observer was live while its token was")

        center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        #expect(deliveries.count == 1, "an out-of-scope token is a deregistered observer")
    }

    /// The other half, and the reason the map keeps its token array at all
    /// rather than discarding what `addObserver` hands back: a retained token
    /// keeps delivering for as long as it is held, and `removeObserver` is
    /// still available for a registration that has to end before its holder
    /// does.
    @Test("a token that is kept goes on observing until it is removed")
    func aRetainedTokenObservesUntilRemoved() {
        let center = Self.center()
        let deliveries = Deliveries()
        let token = center.addObserver(
            for: UIApplication.DidBecomeActiveMessage.self
        ) { _ in deliveries.record() }

        center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        #expect(deliveries.count == 2)

        center.removeObserver(token)
        center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        #expect(deliveries.count == 2)
        withExtendedLifetime(token) { /* the token is the registration */ }
    }

    /// The bridge every one of these observers is reached through, in both
    /// shapes the app cares about: an untyped post carrying no object at all,
    /// which is what a test posts, and a registration made with no subject,
    /// which is what all three types do.
    ///
    /// Not a detail of the harness. `MapCoordinatorLifecycleTests`,
    /// `OrphanedActivityTests` and `MovementReminderControllerTests` all drive
    /// their gate this way because a test host cannot be backgrounded, so if
    /// this bridge ever stops working those suites go quiet rather than red —
    /// they would post into a centre nobody was listening to and assert that
    /// nothing had happened.
    @Test("a legacy post reaches a typed observer registered with no subject")
    func aLegacyPostReachesATypedObserver() {
        let center = Self.center()
        let deliveries = Deliveries()
        let token = center.addObserver(
            for: UIApplication.DidEnterBackgroundMessage.self
        ) { _ in deliveries.record() }

        center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        #expect(deliveries.count == 1)

        // And not to a message of a different name, which is the mistake a
        // typed registration is meant to make impossible but a hand-written
        // `static var name` could still make.
        center.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        #expect(deliveries.count == 1)
        withExtendedLifetime(token) { /* the token is the registration */ }
    }
}
#endif
