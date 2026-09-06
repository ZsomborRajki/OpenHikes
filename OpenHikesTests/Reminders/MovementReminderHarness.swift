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
/// Most of the protocol's members are `async` and most of these witnesses are
/// not, which is legal and deliberate — a synchronous function witnesses an
/// `async` requirement, and a stub that suspended would be modelling a delay
/// nothing here is about.
///
/// ``authorize()`` is the exception, because for it the delay *is* the
/// subject: the walker can leave a permission prompt on screen for as long as
/// they like, and what the app does with an answer that arrives after they
/// resumed is the whole of what ``holdsThePrompt`` exists to test.
@MainActor
final class StubMovementReminderNotifier: MovementReminderNotifying {
    /// What the walker said to the permission prompt. Settable because
    /// "reminders are on but permission was refused" is a real state and the
    /// controller has to keep quiet in it.
    var isAuthorized = true
    /// Leaves the next prompt on screen until ``answerPrompt(allowing:)``,
    /// modelling the walker who reads it slowly. One prompt only: a second
    /// one is answered from ``isAuthorized`` as usual, which is what lets a
    /// test hold *the first* answer and still pause again behind it.
    var holdsThePrompt = false
    private var pendingPrompt: CheckedContinuation<Bool, Never>?
    private(set) var authorizationRequests = 0
    private(set) var silentChecks = 0
    private(set) var posted: [MovementReminder] = []
    private(set) var withdrawn: [MovementReminderKind] = []

    var postedKinds: [MovementReminderKind] { posted.map(\.kind) }

    func authorize() async -> Bool {
        authorizationRequests += 1
        guard holdsThePrompt else { return isAuthorized }
        holdsThePrompt = false
        return await withCheckedContinuation { pendingPrompt = $0 }
    }

    /// Answers a prompt ``holdsThePrompt`` left on screen. The answer belongs
    /// to that prompt alone, so a later one is unaffected by it.
    func answerPrompt(allowing allowed: Bool) {
        let continuation = pendingPrompt
        pendingPrompt = nil
        continuation?.resume(returning: allowed)
    }

    /// Waits until the held prompt is actually on screen.
    ///
    /// The controller *schedules* the ask rather than running it, so a test
    /// that answered straight after `recordingDidPause` would be answering a
    /// prompt that had not been put up yet. Bounded rather than a bare loop:
    /// a stub that never asks should fail an expectation, not hang a suite.
    func awaitPrompt() async {
        for _ in 0..<Self.promptPolls {
            if pendingPrompt != nil { return }
            await Task.yield()
        }
    }

    private static let promptPolls = 64

    /// The same answer with no prompt, counted separately so a suite can tell
    /// a foreground re-check apart from a question put to the walker.
    func canPost() -> Bool {
        silentChecks += 1
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
    ///
    /// `takenAt` is the fix's own timestamp, which is not the moment it is
    /// handed over: a cached significant-change event and a batched delivery
    /// both arrive long after they were taken, and the controller is required
    /// to tell the two apart.
    nonisolated static func fix(
        northOfAnchorBy meters: Double,
        accuracy: CLLocationAccuracy = 20,
        takenAt timestamp: Date = start
    ) -> CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(
                latitude: anchor.latitude + meters / metresPerDegreeLatitude,
                longitude: anchor.longitude
            ),
            altitude: anchorElevation,
            horizontalAccuracy: accuracy,
            verticalAccuracy: 5,
            timestamp: timestamp
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
