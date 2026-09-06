//
//  MovementReminderHarness.swift
//  OpenHikesTests
//
//  The fixtures the reminder suites share: a notifier that records what it was
//  told instead of talking to `UserNotifications`, a clock the test moves by
//  hand, and a controller wired to both.
//
//  Its own type rather than static members on one suite, for the reason
//  ``LiveActivityHarness`` is: the suites are split by subject — the policy,
//  the controller, the recorder's half of the wiring, the walk's — and a
//  fixture reachable from only one of them would force that split to follow
//  the fixtures instead.
//

import CoreLocation
import Foundation
@testable import OpenHikes

/// Everything the controller says, in the order it said it.
///
/// The protocol's members are `async`; these witnesses are not, which is legal
/// and deliberate — a synchronous function witnesses an `async` requirement,
/// and a stub that suspended would be modelling a delay nothing here is about.
@MainActor
final class StubMovementReminderNotifier: MovementReminderNotifying {
    /// What the walker said to the permission prompt. Settable because
    /// "reminders are on but permission was refused" is a real state and the
    /// controller has to keep quiet in it.
    var isAuthorized = true
    private(set) var authorizationRequests = 0
    private(set) var posted: [MovementReminder] = []
    private(set) var withdrawn: [MovementReminderKind] = []

    var postedKinds: [MovementReminderKind] { posted.map(\.kind) }

    func authorize() -> Bool {
        authorizationRequests += 1
        return isAuthorized
    }

    func post(_ reminder: MovementReminder) {
        posted.append(reminder)
    }

    func withdraw(_ kind: MovementReminderKind) {
        withdrawn.append(kind)
    }
}

@MainActor
enum MovementReminderHarness {
    /// A fixed instant so nothing here reads the wall clock. The value is
    /// arbitrary; that it never moves is the point.
    nonisolated static let start = Date(timeIntervalSince1970: fixedEpoch)
    nonisolated private static let fixedEpoch: TimeInterval = 1_750_000_000

    /// The pause anchor every recording assertion is measured from, and a
    /// point due north of it by a given number of metres.
    nonisolated static let anchor = CLLocationCoordinate2D(
        latitude: anchorLatitude,
        longitude: anchorLongitude
    )
    nonisolated private static let anchorLatitude = 47.63
    nonisolated private static let anchorLongitude = 12.86
    /// Somewhere in the Alps, so the fixtures read as a walk rather than as
    /// coordinates at sea level off the coast of Africa.
    nonisolated private static let anchorElevation = 600.0

    /// One degree of latitude, near enough for a fixture: the assertions are
    /// about thresholds hundreds of metres apart, not about geodesy.
    nonisolated private static let metresPerDegreeLatitude = 111_320.0

    /// A fix `meters` north of ``anchor``, accurate enough to be measured.
    nonisolated static func fix(
        northOfAnchorBy meters: Double,
        accuracy: CLLocationAccuracy = 20
    ) -> CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(
                latitude: anchor.latitude + meters / metresPerDegreeLatitude,
                longitude: anchor.longitude
            ),
            altitude: anchorElevation,
            horizontalAccuracy: accuracy,
            verticalAccuracy: 5,
            timestamp: start
        )
    }

    struct Harness {
        let controller: MovementReminderController
        let notifier: StubMovementReminderNotifier
        /// The controller's own defaults suite, so a test can flip the
        /// walker's switch the way `SettingsView`'s `@AppStorage` does.
        let defaults: UserDefaults
    }

    /// A defaults suite of its own, never the developer's: the controller
    /// reads its switch on every decision, so a test writing to `.standard`
    /// would change the host app's behaviour for every suite after it.
    static func harness(remindersEnabled: Bool = true) -> Harness {
        let notifier = StubMovementReminderNotifier()
        let suite = UserDefaults(suiteName: "movement-reminders-\(UUID().uuidString)")
            ?? .standard
        suite.set(remindersEnabled, forKey: SettingsKey.movementRemindersEnabled)
        return Harness(
            controller: MovementReminderController(notifier: notifier, defaults: suite),
            notifier: notifier,
            defaults: suite
        )
    }
}
