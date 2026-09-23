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
//  interruption level is not this file's to choose: `.timeSensitive` is the
//  level that breaks through a Focus, which two of the five kinds are worth
//  and three are not, and that answer lives on
//  ``MovementReminderKind/interruptionLevel`` beside the category and the
//  button — the same split the rest of this file keeps. What it costs the
//  app is an entitlement, which is in `OpenHikes.entitlements`; what a build
//  missing it costs a hiker is a silent downgrade back to `.active`.
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
        // Both from the kind, for the reason the category is: what a given
        // reminder is worth is policy, and none of it is decided here.
        content.interruptionLevel = reminder.kind.interruptionLevel
        content.relevanceScore = reminder.kind.relevanceScore
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
                // A kind with no verb registers a category with no actions,
                // which is a banner and nothing else — see
                // ``MovementReminderKind/action``. Still a category of its
                // own rather than none, because the identifier is what
                // ``withdraw(_:)`` takes a delivered banner back down by.
                actions: kind.action.map { action in
                    [
                        UNNotificationAction(
                            identifier: action.rawValue,
                            title: action.title,
                            // No `.foreground`, deliberately. The system runs
                            // the action in this process without bringing the
                            // app to the front, which is the difference
                            // between a hiker tapping Resume with gloves on
                            // and one unlocking a phone to find the recording
                            // screen.
                            options: []
                        ),
                    ]
                } ?? [],
                intentIdentifiers: [],
                options: []
            )
        }
        center.setNotificationCategories(Set(categories))
    }
    #endif
}
