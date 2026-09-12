//
//  SystemMovementReminderNotifier.swift
//  OpenHikes
//
//  The `UserNotifications` half of the reminders: permission, the categories
//  that carry the buttons, posting and taking back down.
//
//  Nothing here decides anything. Every "should this be sent" question is
//  answered in ``MovementReminderController``; this file is the framework
//  call that follows, which is exactly the split
//  ``SystemHikeActivityPresenter`` keeps with its controller.
//
//  Two things about the framework are worth knowing before changing it. The
//  categories have to be registered before a notification carrying one is
//  posted, or it is delivered with no buttons on it and the hiker has to
//  unlock the phone to do the thing the banner just offered — so registration
//  is folded into ``authorize()``, which every path runs first. And the
//  interruption level is deliberately left at its default: `.timeSensitive`
//  is the level that breaks through a Focus, and it needs an entitlement
//  Apple grants per app rather than a property this file can set. Asking for
//  it is a separate, deliberate change to what the app ships with — see the
//  issue tracker, not this comment, for whether it has been made.
//

import Foundation
import os
#if canImport(UserNotifications)
import UserNotifications
#endif

@MainActor
final class SystemMovementReminderNotifier: MovementReminderNotifying {
    private static let logger = Logger(
        subsystem: "OpenHikes",
        category: "MovementReminders"
    )

    /// Registered once per launch. Re-registering is harmless — the set
    /// replaces whatever was there — but it is a cross-process call on a path
    /// that runs at every pause.
    private var hasRegisteredCategories = false

    func authorize() async -> Bool {
        #if canImport(UserNotifications)
        let center = UNUserNotificationCenter.current()
        registerCategoriesIfNeeded(with: center)
        let status = await center.notificationSettings().authorizationStatus
        switch status {
        case .authorized, .ephemeral, .provisional: return true
        case .denied: return false
        case .notDetermined:
            do {
                return try await center.requestAuthorization(options: [.alert, .sound])
            } catch {
                Self.logger.error(
                    "Notification authorization failed: \(error.localizedDescription, privacy: .public)"
                )
                return false
            }
        @unknown default: return false
        }
        #else
        return false
        #endif
    }

    /// The same question ``authorize()`` asks, with nothing put on screen.
    ///
    /// No category registration either: this runs on every return to the
    /// foreground, and there is nothing to register categories *for* until a
    /// reminder is posted — every path that posts one has run ``authorize()``
    /// first.
    func canPost() async -> Bool {
        #if canImport(UserNotifications)
        let center = UNUserNotificationCenter.current()
        return await center.notificationSettings().authorizationStatus != .denied
        #else
        return false
        #endif
    }

    func post(_ reminder: MovementReminder) async {
        #if canImport(UserNotifications)
        let content = UNMutableNotificationContent()
        content.title = reminder.title
        content.body = reminder.body
        content.categoryIdentifier = reminder.categoryIdentifier
        content.sound = .default
        // `nil`, not a one-second time interval: the reminder is about what
        // the hiker is doing right now, and a trigger would let it arrive
        // after they have already resumed.
        let request = UNNotificationRequest(
            identifier: reminder.notificationIdentifier,
            content: content,
            trigger: nil
        )
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            let kind = reminder.kind.rawValue
            Self.logger.error(
                "Could not post \(kind, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
        #endif
    }

    func withdraw(_ kind: MovementReminderKind) {
        #if canImport(UserNotifications)
        let center = UNUserNotificationCenter.current()
        let identifiers = [kind.notificationIdentifier]
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
        #endif
    }

    #if canImport(UserNotifications)
    private func registerCategoriesIfNeeded(with center: UNUserNotificationCenter) {
        guard !hasRegisteredCategories else { return }
        hasRegisteredCategories = true
        let categories = MovementReminderKind.allCases.map { kind in
            UNNotificationCategory(
                identifier: kind.categoryIdentifier,
                actions: [
                    UNNotificationAction(
                        identifier: kind.action.rawValue,
                        title: kind.action.title,
                        // No `.foreground`, deliberately. The system runs the
                        // action in this process without bringing the app to
                        // the front, which is the difference between a hiker
                        // tapping Resume with gloves on and one unlocking a
                        // phone to find the recording screen.
                        options: []
                    ),
                ],
                intentIdentifiers: [],
                options: []
            )
        }
        center.setNotificationCategories(Set(categories))
    }
    #endif
}
