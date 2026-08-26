//
//  CloudSyncFailureTests.swift
//  OpenHikesTests
//
//  The classification that decides whether a refused record is a shrug, a
//  retry, or a "Sync Problem" alert.
//
//  Worth its own suite because the alternative to getting this right is what
//  shipped: every unnamed failure raised an alert, so walking out of signal
//  told the user their hikes had stopped syncing — while a `batchRequestFailed`
//  in an atomic zone dropped 249 perfectly good records on the floor without
//  re-queueing any of them.
//

import CloudKit
@testable import OpenHikes
import Testing

@Suite("Cloud sync failure classification")
struct CloudSyncFailureTests {
    /// `CKSyncEngine` retries these itself and keeps the change pending. The
    /// delegate hears about them, in Apple's words, "for your awareness".
    @Test(
        "A failure the engine retries itself is not the user's problem",
        arguments: [
            CKError.Code.networkFailure,
            .networkUnavailable,
            .zoneBusy,
            .serviceUnavailable,
            .notAuthenticated,
            .operationCancelled,
            .requestRateLimited,
            .accountTemporarilyUnavailable,
        ]
    )
    func transientFailuresAreIgnored(code: CKError.Code) {
        #expect(CloudSyncFailure.response(to: code) == .ignore)
    }

    /// A custom zone is atomic: one rejected record rolls the whole batch
    /// back, and the other records arrive as `batchRequestFailed`. The engine
    /// has already consumed each of them as sent, so anything not re-queued
    /// here waits until the next launch replays the pending names.
    @Test(
        "A record that failed through no fault of its own is queued again",
        arguments: [
            CKError.Code.batchRequestFailed,
            .assetFileNotFound,
            .assetFileModified,
        ]
    )
    func recoverableFailuresAreRetried(code: CKError.Code) {
        #expect(CloudSyncFailure.response(to: code) == .retry)
    }

    /// Retrying a quota failure or a permission failure produces the same
    /// answer forever, so these are the ones actually worth interrupting for.
    @Test(
        "A failure that will not fix itself is reported",
        arguments: [
            CKError.Code.quotaExceeded,
            .permissionFailure,
            .managedAccountRestricted,
            .invalidArguments,
        ]
    )
    func permanentFailuresAreReported(code: CKError.Code) {
        #expect(CloudSyncFailure.response(to: code) == .report)
    }

    /// The delegate is handed `any Error`, not a `CKError`, and something that
    /// isn't CloudKit's at all has no retry story worth guessing at.
    @Test("An error that isn't CloudKit's is reported")
    func nonCloudKitErrorsAreReported() {
        let error = NSError(domain: "OpenHikesTests", code: 1)
        #expect(CloudSyncFailure.response(to: error) == .report)
    }

    /// The same walk-out-of-signal failure, arriving through the erased path
    /// the delegate actually uses.
    @Test("A CloudKit error keeps its classification once erased")
    func erasedCloudKitErrorsKeepTheirResponse() {
        let error: any Error = CKError(.networkUnavailable)
        #expect(CloudSyncFailure.response(to: error) == .ignore)
    }
}
