//
//  LiveActivityHarness.swift
//  OpenHikesTests
//
//  The fixtures the two Live Activity controller suites share: a controller
//  wired to `StubHikeActivityPresenter`, a clock the test moves by hand, and
//  the two requests every assertion is written against.
//
//  Its own type rather than static members on one of the suites, because the
//  suites are split by subject — what the controller *starts* against what it
//  *ends* — and a helper reachable from only one of them would have forced the
//  split to follow the fixtures instead.
//

import Foundation
@testable import OpenHikes
import OpenHikesShared
import UIKit

@MainActor
enum LiveActivityHarness {
    static let sessionID = UUID()
    static let hikeID = UUID()
    /// `nonisolated` so the clock closure — which is `@Sendable` — can read it.
    /// A `@MainActor` type's static members are main-actor isolated too.
    nonisolated static let start = Date(timeIntervalSince1970: fixedEpoch)

    /// A fixed instant so nothing here reads the wall clock. The value is
    /// arbitrary; that it never moves is the point.
    nonisolated private static let fixedEpoch: TimeInterval = 1_750_000_000

    /// The length of the followed trail in ``followingRequest(_:)``, named so
    /// the progress assertions read as fractions of something.
    static let routeDistanceMeters: Double = 4000

    /// A defaults suite of its own, never the developer's. The controller
    /// reads its switch on every call, so a test that wrote to `.standard`
    /// would change the host app's behaviour for every suite after it.
    static func defaults(liveActivities: Bool = true) -> UserDefaults {
        guard let defaults = UserDefaults(suiteName: "live-activity-\(UUID().uuidString)") else {
            return .standard
        }
        defaults.set(liveActivities, forKey: SettingsKey.liveActivitiesEnabled)
        return defaults
    }

    struct Harness {
        let controller: HikeLiveActivityController
        let presenter: StubHikeActivityPresenter
        let now: Clock
        /// The controller's own suite, exposed so a test can flip the hiker's
        /// switch the way `SettingsView`'s `@AppStorage` does — which is the
        /// only trigger that reaches a controller with no walk to publish.
        let defaults: UserDefaults
        /// The controller's own notification centre, so a test can drive the
        /// app-becoming-active registration itself. `.default` would work and
        /// is what the app uses, but posting it here would reach every other
        /// controller alive in the test host — and the host is a running app.
        let lifecycleCenter: NotificationCenter

        /// Posts the app-lifecycle notification the controller's typed
        /// observer is built on.
        ///
        /// The *legacy* name rather than
        /// `lifecycleCenter.post(UIApplication.DidBecomeActiveMessage())`,
        /// deliberately: UIKit itself still posts the untyped notification,
        /// so bridging into a `MainActorMessage` observer is the thing that
        /// has to keep working, and a typed post would test the one path the
        /// app never takes.
        func postDidBecomeActive() {
            lifecycleCenter.post(
                name: UIApplication.didBecomeActiveNotification,
                object: nil
            )
        }

        /// A clock the test moves by hand. The controller's whole job is
        /// deciding what is worth doing *yet*, so a suite that waited out a
        /// twenty-second throttle would be measuring `Task.sleep`.
        final class Clock {
            var date: Date

            init(_ date: Date) { self.date = date }
        }
    }

    static func harness(liveActivities: Bool = true) -> Harness {
        let presenter = StubHikeActivityPresenter()
        let clock = Harness.Clock(start)
        let suite = defaults(liveActivities: liveActivities)
        let center = NotificationCenter()
        let controller = HikeLiveActivityController(
            presenter: presenter,
            defaults: suite,
            clock: { MainActor.assumeIsolated { clock.date } },
            lifecycleCenter: center
        )
        return Harness(
            controller: controller,
            presenter: presenter,
            now: clock,
            defaults: suite,
            lifecycleCenter: center
        )
    }

    static func recordingRequest(
        distanceMeters: Double = 1000,
        runState: HikeActivityAttributes.ContentState.RunState = .running,
        offRouteMeters: Double? = nil,
        elapsedSeconds: TimeInterval = 600,
        at date: Date = start
    ) -> HikeActivityRequest {
        HikeActivityRequest(
            attributes: .recording(
                sessionID: sessionID,
                title: "Morning walk",
                tintHex: "#34C759",
                startedAt: start
            ),
            state: .init(
                distanceMeters: distanceMeters,
                offRouteMeters: offRouteMeters,
                runState: runState,
                elapsedSeconds: elapsedSeconds,
                updatedAt: date
            )
        )
    }

    static func followingRequest(
        distanceMeters: Double = 500,
        offRouteMeters: Double? = 4,
        at date: Date = start
    ) -> HikeActivityRequest {
        HikeActivityRequest(
            attributes: HikeActivityAttributes(
                subject: .following(hikeID: hikeID),
                title: "Thumsee Loop",
                tintHex: "#34C759",
                startedAt: start,
                routeDistanceMeters: routeDistanceMeters
            ),
            state: .init(
                distanceMeters: distanceMeters,
                offRouteMeters: offRouteMeters,
                updatedAt: date
            )
        )
    }
}
