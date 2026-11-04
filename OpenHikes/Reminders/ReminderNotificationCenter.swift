//
//  ReminderNotificationCenter.swift
//  OpenHikes
//
//  The slice of `UNUserNotificationCenter` that
//  ``SystemMovementReminderNotifier`` calls, so that a suite can hand it a
//  centre that answers what the real one only answers on a hiker's phone.
//
//  ``MovementReminderNotifying`` already keeps the framework out of every
//  policy suite, and that is still where nearly everything is tested. This is
//  the narrower seam under it, for the one thing the notifier itself has to
//  get right: which of iOS's answers lets a reminder through. The real centre
//  in a test host is whatever the simulator was told once, and its request
//  for permission cannot be made to fail, so the answer a failed request
//  leaves behind could not be staged at all (see *Deliberate test seams* in
//  AGENTS.md).
//

import Foundation
#if canImport(UserNotifications)
import UserNotifications

/// What ``SystemMovementReminderNotifier`` asks of the notification centre.
///
/// The status rather than the settings object, because
/// `UNNotificationSettings` cannot be built outside the framework, and the
/// status is the only thing the notifier reads from it.
@MainActor
protocol ReminderNotificationCenter: AnyObject {
    func authorizationStatus() async -> UNAuthorizationStatus
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
    func setNotificationCategories(_ categories: Set<UNNotificationCategory>)
    func add(_ request: UNNotificationRequest) async throws
    func removePendingNotificationRequests(withIdentifiers identifiers: [String])
    func removeDeliveredNotifications(withIdentifiers identifiers: [String])
}

extension UNUserNotificationCenter: ReminderNotificationCenter {
    func authorizationStatus() async -> UNAuthorizationStatus {
        await notificationSettings().authorizationStatus
    }
}
#endif
