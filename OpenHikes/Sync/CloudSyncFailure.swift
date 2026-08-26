//
//  CloudSyncFailure.swift
//  OpenHikes
//
//  What to do about a record the server refused, for the failures that carry
//  no app-specific meaning.
//
//  Kept out of the delegate's `switch` and expressed as a value because the
//  distinction it draws is the difference between a walk out of signal and a
//  "Sync Problem" alert — and because a `switch` inside a `CKSyncEngineDelegate`
//  callback is not something a test can reach. `CKError.Code` is a plain enum,
//  so this is.
//

import CloudKit

nonisolated enum CloudSyncFailure {
    /// What the delegate should do with a failure it has no name for.
    enum Response: Equatable, Sendable {
        /// ``CKSyncEngine`` is already retrying this one on its own schedule
        /// and delivered it, in Apple's words, "for your awareness". Log it
        /// and say nothing else: the change stays pending, and a user walking
        /// out of signal has no problem to be told about.
        case ignore

        /// Nothing about waiting or asking again fixes this. Say so.
        case report

        /// Queue the change again, quietly. The engine consumes a pending
        /// change on send whatever the outcome, so one not re-queued here is
        /// not attempted again until the next launch replays
        /// ``CloudSyncStateStore/pendingSaveNames()``.
        case retry
    }

    /// Failures ``CKSyncEngine`` retries itself.
    ///
    /// Taken from Apple's own sync-engine sample, which handles exactly these
    /// by logging and moving on. The list matters because the alternative is
    /// what shipped: every one of them fell through to a `default:` arm that
    /// raised "Sync Problem" with a raw `localizedDescription`, so a walk
    /// through a valley told the user their hikes had stopped syncing.
    private static let transient: Set<CKError.Code> = [
        .networkFailure,
        .networkUnavailable,
        .zoneBusy,
        .serviceUnavailable,
        .notAuthenticated,
        .operationCancelled,
        .requestRateLimited,
        .accountTemporarilyUnavailable,
    ]

    /// Failures that say "this record didn't go, through no fault of its own".
    ///
    /// A custom zone is atomic, so one `serverRecordChanged` in a 250-record
    /// batch rolls the other 249 back and each of those arrives as
    /// `batchRequestFailed`. The two asset codes are the same shape: staged
    /// route archives live in Caches (``CloudAssetStaging``), which iOS may
    /// reclaim between the moment a batch is built and the moment it is sent.
    /// None of the three is worth an alert, and all three are worth another
    /// attempt.
    private static let recoverable: Set<CKError.Code> = [
        .batchRequestFailed,
        .assetFileNotFound,
        .assetFileModified,
    ]

    static func response(to code: CKError.Code) -> Response {
        if transient.contains(code) { return .ignore }
        if recoverable.contains(code) { return .retry }
        return .report
    }

    static func response(to error: any Error) -> Response {
        guard let code = (error as? CKError)?.code else { return .report }
        return response(to: code)
    }
}
