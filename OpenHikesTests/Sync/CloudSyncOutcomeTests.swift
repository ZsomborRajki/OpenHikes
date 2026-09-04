//
//  CloudSyncOutcomeTests.swift
//  OpenHikesTests
//
//  Which iCloud failures are worth telling a person about.
//
//  The filter matters more than it looks. Mirroring reports every attempt,
//  including the ones it is about to retry, and the retry that succeeds is
//  silent — so a transient error promoted to a headline puts "Sync Problem" on
//  the settings screen and leaves it there until something unrelated happens
//  to sync. These cases pin the two lists apart.
//

import CloudKit
import Foundation
@testable import OpenHikes
import Testing

@Suite("Cloud sync outcome")
struct CloudSyncOutcomeTests {
    /// CloudKit's own retry vocabulary. Every one of these describes the
    /// network or the service, not the account, and every one of them is gone
    /// the moment a signal comes back.
    @Test(
        "the errors mirroring retries itself are not the user's problem",
        arguments: [
            CKError.Code.networkUnavailable,
            .networkFailure,
            .serviceUnavailable,
            .requestRateLimited,
            .zoneBusy,
            .operationCancelled,
        ]
    )
    func transientErrorsAreNotReported(code: CKError.Code) {
        #expect(CloudSyncOutcome.isTransient(CKError(code)))
    }

    /// The ones waiting will not fix. A full account and a rejected schema are
    /// both things the person can act on, and neither improves on its own.
    @Test(
        "the errors that need the user are reported",
        arguments: [
            CKError.Code.quotaExceeded,
            .notAuthenticated,
            .permissionFailure,
            .managedAccountRestricted,
            .invalidArguments,
        ]
    )
    func actionableErrorsAreReported(code: CKError.Code) {
        #expect(!CloudSyncOutcome.isTransient(CKError(code)))
    }

    /// An error CloudKit did not raise says nothing about being retried, so it
    /// is reported. Guessing the other way would hide a genuine failure behind
    /// a category it never claimed to be in.
    @Test("a non-CloudKit error is reported rather than assumed transient")
    func unknownErrorsAreReported() {
        struct SomethingElse: Error {}
        #expect(!CloudSyncOutcome.isTransient(SomethingElse()))
    }

    /// The zone going missing under the store. Core Data answers all three by
    /// resetting its mirroring metadata and re-uploading, which is the
    /// recovery working — so reporting them puts "Sync Problem" on a device
    /// that is busy fixing itself.
    @Test(
        "a zone mirroring will rebuild is not the user's problem",
        arguments: [
            CKError.Code.zoneNotFound,
            .userDeletedZone,
            .changeTokenExpired,
        ]
    )
    func zoneResetsAreNotReported(code: CKError.Code) {
        #expect(CloudSyncOutcome.isTransient(CKError(code)))
    }

    /// The shape the console actually shows: a `Partial Failure` whose own
    /// code says nothing, wrapping the one error that does. Judging the
    /// wrapper alone reported every zone reset as a failure the user had to
    /// act on.
    @Test("a partial failure is judged by what is inside it, not by its wrapper")
    func partialFailureFollowsItsContents() {
        let inner = CKError(.zoneNotFound)
        #expect(CloudSyncOutcome.isTransient(CKError(.partialFailure, partial: [inner])))
    }

    /// The other direction, so the unwrapping cannot be written as "a partial
    /// failure is always fine".
    @Test("a partial failure wrapping something actionable is still reported")
    func partialFailureWithAnActionableErrorIsReported() {
        let inner = CKError(.quotaExceeded)
        #expect(!CloudSyncOutcome.isTransient(CKError(.partialFailure, partial: [inner])))
    }

    /// One item the user has to act on is enough. A pass that half-recovers
    /// has still left something standing.
    @Test("a partial failure is only self-healing if every item in it is")
    func partialFailureNeedsEveryItemToBeSelfHealing() {
        let errors: [any Error] = [CKError(.zoneBusy), CKError(.notAuthenticated)]
        #expect(!CloudSyncOutcome.isTransient(CKError(.partialFailure, partial: errors)))
    }

    /// A partial failure carrying no items says nothing about being retried,
    /// so it is reported for the same reason an unknown error is.
    @Test("a partial failure with nothing inside it is reported")
    func emptyPartialFailureIsReported() {
        #expect(!CloudSyncOutcome.isTransient(CKError(.partialFailure, partial: [])))
    }

    /// A notification carrying no event is the shape `NotificationCenter`
    /// hands over when something else posts on the same name. It must not be
    /// read as a pass.
    @Test("a notification with no event in it produces no outcome")
    func notificationWithoutEventIsIgnored() {
        let notification = Notification(name: .init("test"), object: nil, userInfo: [:])
        #expect(CloudSyncOutcome(notification: notification) == nil)
    }
}

private extension CKError {
    init(_ code: Code) {
        self.init(_nsError: NSError(domain: CKErrorDomain, code: code.rawValue))
    }

    /// A partial failure carrying `partial` under the key CloudKit files its
    /// per-item errors on. Keyed by position, because nothing here reads the
    /// item IDs — only the errors behind them.
    init(_ code: Code, partial: [any Error]) {
        let byItemID = Dictionary(
            uniqueKeysWithValues: partial.enumerated().map { ($0.offset as AnyHashable, $0.element) }
        )
        self.init(
            _nsError: NSError(
                domain: CKErrorDomain,
                code: code.rawValue,
                userInfo: [CKPartialErrorsByItemIDKey: byItemID]
            )
        )
    }
}
