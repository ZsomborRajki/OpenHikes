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

    /// Whether an error is mirroring's own to clear rather than the user's.
    ///
    /// Two kinds qualify, and neither leaves the person anything to do.
    ///
    /// The first is CloudKit's own retry vocabulary: no connection, a busy or
    /// rate-limited service, a request that was simply cancelled. Mirroring
    /// retries all of those without being asked, so surfacing them would put
    /// "Sync Problem" on the screen for a condition that fixes itself the
    /// moment a signal comes back — and would leave it there, because the
    /// retry that succeeds is silent.
    ///
    /// The second is the record zone going out from under the store:
    /// ``CKError/Code/zoneNotFound``, ``CKError/Code/userDeletedZone`` and a
    /// ``CKError/Code/changeTokenExpired`` token that no longer names
    /// anything. These read alarming and are not: Core Data answers them by
    /// posting `NSCloudKitMirroringDelegateWillResetSyncNotificationName`,
    /// dropping its mirroring metadata and re-uploading the store from
    /// scratch, which is the recovery and not a symptom of one failing. A
    /// person reaches this by deleting the app's data from iCloud storage, by
    /// having another device delete it, or — the way this was found — by
    /// installing a debug build over one from TestFlight, since Xcode talks to
    /// the *development* CloudKit environment and TestFlight to *production*,
    /// and the zone the local store remembers exists in only one of them.
    ///
    /// Anything else is reported. An unknown error is far more likely to be a
    /// full iCloud account or a schema the container will not accept — both of
    /// which the user can act on and neither of which improves by waiting —
    /// than a self-healing case Apple forgot to document.
    static func isTransient(_ error: any Error) -> Bool {
        guard let ckError = error as? CKError else { return false }
        // A partial failure carries no verdict of its own. It is the wrapper a
        // batch operation returns, and what actually went wrong is one error
        // per item inside it — so reading the wrapper's own code called every
        // one of these permanent, including a single busy zone inside an
        // otherwise clean fetch. This is the shape the zone errors above
        // arrive in: mirroring fetches every zone in one operation, and a
        // missing one comes back as `Partial Failure (2/1011)` with the real
        // `Zone Not Found` underneath it.
        if ckError.code == .partialFailure {
            guard let partial = ckError.partialErrorsByItemID, !partial.isEmpty else {
                return false
            }
            return partial.values.allSatisfy { isTransient($0) }
        }
        return selfHealingCodes.contains(ckError.code)
    }

    /// The codes ``isTransient(_:)`` answers `true` for, as a set so that the
    /// two lists it documents stay one list to edit.
    private static let selfHealingCodes: Set<CKError.Code> = [
        .networkUnavailable,
        .networkFailure,
        .serviceUnavailable,
        .requestRateLimited,
        .zoneBusy,
        .operationCancelled,
        .zoneNotFound,
        .userDeletedZone,
        .changeTokenExpired,
    ]
}
