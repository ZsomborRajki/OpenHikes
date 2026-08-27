//
//  CloudSyncOutcome.swift
//  OpenHikes
//
//  One mirroring event, reduced to the only four things the settings row can
//  say about it.
//
//  Its own `Sendable` type for two reasons. `NSPersistentCloudKitContainer`
//  posts a `Event` — a class, carrying an existential `error` — which cannot
//  cross an isolation boundary, so something has to be extracted on the
//  posting thread before the hop to the main actor. And the interesting
//  decision here is not the hop but the *filter*: which CloudKit errors are
//  worth telling a person about. That is a pure function over an error, and
//  keeping it here means it is a test rather than a comment.
//

import CloudKit
import CoreData
import Foundation

nonisolated enum CloudSyncOutcome: Equatable, Sendable {
    /// A setup, import or export started.
    ///
    /// Setup is included deliberately: on a first launch it is the longest of
    /// the three and the only one happening while the list is still empty, so
    /// treating it as idle would show "Synced with iCloud" over nothing.
    case began
    /// Something waiting will not fix.
    case failed(String)
    case succeeded
    /// Something the network will fix on its own — see ``isTransient(_:)``.
    case transientFailure(String)

    /// Reads an event out of the notification `NSPersistentCloudKitContainer`
    /// posts, or answers `nil` for a notification that carries none.
    init?(notification: Notification) {
        let key = NSPersistentCloudKitContainer.eventNotificationUserInfoKey
        guard let event = notification.userInfo?[key]
            as? NSPersistentCloudKitContainer.Event
        else { return nil }
        self.init(event: event)
    }

    init(event: NSPersistentCloudKitContainer.Event) {
        // An event with no end date has only just started; the same event is
        // posted again, with one, when it finishes.
        guard event.endDate != nil else {
            self = .began
            return
        }
        guard let error = event.error else {
            self = .succeeded
            return
        }
        self = Self.isTransient(error)
            ? .transientFailure(error.localizedDescription)
            : .failed(error.localizedDescription)
    }

    /// Whether an error is the network's problem rather than the user's.
    ///
    /// The transient set is CloudKit's own retry vocabulary: no connection, a
    /// busy or rate-limited service, a request that was simply cancelled.
    /// Mirroring retries all of those without being asked, so surfacing them
    /// would put "Sync Problem" on the screen for a condition that fixes
    /// itself the moment a signal comes back — and would leave it there,
    /// because the retry that succeeds is silent.
    ///
    /// Anything else is reported. An unknown error is far more likely to be a
    /// full iCloud account or a schema the container will not accept — both of
    /// which the user can act on and neither of which improves by waiting —
    /// than a transient case Apple forgot to document.
    static func isTransient(_ error: any Error) -> Bool {
        guard let ckError = error as? CKError else { return false }
        switch ckError.code {
        case .networkUnavailable,
            .networkFailure,
            .serviceUnavailable,
            .requestRateLimited,
            .zoneBusy,
            .operationCancelled:
            return true
        default:
            return false
        }
    }
}
