//
//  SystemMovementReminderNotifierTests.swift
//  OpenHikesTests
//
//  The one thing the notifier has to get right on its own: which of iOS's
//  answers lets a reminder reach the hiker. A reminder held back for permission is posted on the
//  strength of that answer, and its pause counts it as heard, so an answer
//  that lets through a banner iOS will never show spends the reminder on
//  nobody.
//
//  The real notifier over a centre the suite controls, because the answer
//  that matters is the one a failed request leaves behind, and the test host's
//  own centre cannot be made to fail one.
//

import Foundation
@testable import OpenHikes
import Testing
import UserNotifications

@MainActor
@Suite("The system notifier's permission answers")
struct SystemMovementReminderNotifierTests {
    /// A notification centre that remembers what it was asked, and whose
    /// request for permission always fails.
    final class StubCenter: ReminderNotificationCenter {
        struct RequestFailed: Error {}

        var status = UNAuthorizationStatus.notDetermined
        private(set) var authorizationRequests = 0
        private(set) var categoryRegistrations = 0
        private(set) var added: [String] = []

        func authorizationStatus() -> UNAuthorizationStatus { status }

        /// Fails and leaves the question undecided, which is what a request
        /// that throws does to the real centre.
        func requestAuthorization(options: UNAuthorizationOptions) throws -> Bool {
            authorizationRequests += 1
            throw RequestFailed()
        }

        func setNotificationCategories(_ categories: Set<UNNotificationCategory>) {
            categoryRegistrations += 1
        }

        func add(_ request: UNNotificationRequest) {
            added.append(request.identifier)
        }

        func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
            // Nothing here asks what was taken down.
        }

        func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
            // Nothing here asks what was taken down.
        }
    }

    nonisolated static let decided: [UNAuthorizationStatus] = [.denied, .authorized, .provisional, .ephemeral]

    @Test("a failed request leaves nothing a reminder could be posted on")
    func aFailedRequestCannotPost() async {
        let center = StubCenter()
        let notifier = SystemMovementReminderNotifier(center: center)

        #expect(await notifier.authorize() == false)
        #expect(center.status == .notDetermined, "precondition: the question is still open")
        #expect(await notifier.canPost() == false, "iOS shows nothing for a question nobody answered")
    }

    @Test("the silent check agrees with the prompt once the hiker has answered", arguments: decided)
    func theSilentCheckAgreesWithThePrompt(_ status: UNAuthorizationStatus) async {
        let center = StubCenter()
        center.status = status
        let notifier = SystemMovementReminderNotifier(center: center)

        let silent = await notifier.canPost()
        let asked = await notifier.authorize()

        #expect(silent == asked)
        #expect(center.authorizationRequests == 0, "an answered question is not asked again")
    }

    /// Every return to the foreground runs this, so it may not put anything in
    /// front of the hiker or spend a cross-process call it has no use for.
    @Test(
        "the silent check asks nobody and registers nothing",
        arguments: [UNAuthorizationStatus.notDetermined] + decided
    )
    func theSilentCheckIsSilent(_ status: UNAuthorizationStatus) async {
        let center = StubCenter()
        center.status = status
        let notifier = SystemMovementReminderNotifier(center: center)

        _ = await notifier.canPost()

        #expect(center.authorizationRequests == 0)
        #expect(center.categoryRegistrations == 0)
    }

    /// A walk keeps its pause through a refusal, so it is the subject a
    /// reminder can be held back for while the question is still open. The
    /// return to the app must leave that reminder owed, and the one after
    /// permission is given must deliver it.
    @Test("a reminder held back behind a failed request is not spent")
    func aHeldBackReminderIsNotSpent() async {
        let center = StubCenter()
        let suite = UserDefaults(suiteName: "movement-reminders-\(UUID().uuidString)") ?? .standard
        suite.set(true, forKey: SettingsKey.movementRemindersEnabled)
        let controller = MovementReminderController(
            notifier: SystemMovementReminderNotifier(center: center),
            defaults: suite,
            lifecycleCenter: NotificationCenter(),
            clock: TestClock(MovementReminderHarness.start).read
        )
        let start = MovementReminderHarness.start

        controller.walkDidPause(trailTitle: "Ridge Loop", atDistance: 0, on: start)
        controller.walkObserved(
            distanceAlongRoute: MovementReminderPolicy.awayMeters + 100,
            at: start.addingTimeInterval(60)
        )
        await controller.settle()
        #expect(
            center.authorizationRequests == 2,
            "precondition: the pause and its reminder both asked, and both requests failed"
        )

        controller.reconcileWithAuthorization(prompting: false)
        await controller.settle()
        #expect(center.added.isEmpty, "a post iOS would not show")

        center.status = .authorized
        controller.reconcileWithAuthorization(prompting: false)
        await controller.settle()
        #expect(
            center.added == [MovementReminderKind.resumeWalk.notificationIdentifier],
            "the reminder was still owed"
        )
    }
}
