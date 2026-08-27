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
}
