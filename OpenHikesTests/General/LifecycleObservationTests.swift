//
//  LifecycleObservationTests.swift
//  OpenHikesTests
//
//  The two properties every holder of a `LifecycleObservation` rests on — the
//  handler runs in the post, and the observation lives exactly as long as it
//  is held — for both of its forms: the typed message the app observes with
//  on iOS 26 and later, and the block-based observer below it, which this
//  simulator would otherwise never run. `MapCoordinatorLifecycleTests` and the
//  two preference-governed controllers' suites drive their gates the same way
//  these do, with an untyped post carrying no object.
//

#if os(iOS)
import Foundation
@testable import OpenHikes
import Testing
import UIKit

@MainActor
@Suite("Lifecycle observation")
struct LifecycleObservationTests {
    /// Which of the two forms a test holds.
    nonisolated enum Form: CaseIterable, CustomTestStringConvertible {
        /// What the app observes with on this release.
        case current
        /// The block-based observer, whatever the release.
        case earlier

        var testDescription: String {
            switch self {
            case .current: "the form this release uses"
            case .earlier: "the block-based form"
            }
        }
    }

    /// Counts deliveries without being a `@MainActor` closure's captured
    /// `inout`.
    final class Deliveries {
        private(set) var count = 0

        func record() { count += 1 }
    }

    private static func observe(
        _ moment: LifecycleObservation.Moment,
        on center: NotificationCenter,
        as form: Form,
        into deliveries: Deliveries
    ) -> LifecycleObservation {
        switch form {
        case .current: LifecycleObservation(moment, on: center) { deliveries.record() }
        case .earlier: LifecycleObservation(earlier: moment, on: center) { deliveries.record() }
        }
    }

    @Test("the handler runs in the post", arguments: Form.allCases)
    func theHandlerRunsInThePost(_ form: Form) {
        let center = NotificationCenter()
        let deliveries = Deliveries()
        let observation = Self.observe(.didBecomeActive, on: center, as: form, into: deliveries)

        center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        #expect(deliveries.count == 1, "delivered before the post returned")
        withExtendedLifetime(observation) { /* the observation is the registration */ }
    }

    @Test("an observation nobody keeps stops observing", arguments: Form.allCases)
    func aDroppedObservationEnds(_ form: Form) {
        let center = NotificationCenter()
        let deliveries = Deliveries()

        do {
            let observation = Self.observe(.didBecomeActive, on: center, as: form, into: deliveries)
            center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
            withExtendedLifetime(observation) { /* live until here */ }
        }
        #expect(deliveries.count == 1, "precondition: the observer was live while it was held")

        center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        #expect(deliveries.count == 1, "a released observation is a deregistered one")
    }

    @Test("each moment answers to its own notification and no other", arguments: Form.allCases)
    func eachMomentIsItsOwn(_ form: Form) {
        let center = NotificationCenter()
        let deliveries = Deliveries()
        let observation = Self.observe(.didEnterBackground, on: center, as: form, into: deliveries)

        center.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        #expect(deliveries.count == 0)

        center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        #expect(deliveries.count == 1)
        withExtendedLifetime(observation) { /* the observation is the registration */ }
    }
}
#endif
