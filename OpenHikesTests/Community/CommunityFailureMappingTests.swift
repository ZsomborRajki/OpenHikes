//
//  CommunityFailureMappingTests.swift
//  OpenHikesTests
//
//  Which CloudKit error becomes which of the five things the app may say.
//
//  Every community request funnels its `catch` through
//  ``CloudKitCommunityTransport/failure(from:while:)``, so this one function
//  decides what a hiker reads when sharing, browsing or reviewing goes wrong.
//  It is also the only part of that transport a suite can reach: the methods
//  around it open a `CKContainer` and wait on the public database, and this
//  takes an error and returns an answer.
//
//  What is worth pinning is the *grouping*, not the vocabulary. A tunnel, a
//  rate limit and a busy service are one sentence to a hiker — try again —
//  and the five retryable codes folding into a single `unreachable` is a
//  deliberate decision that a sixth code, added later to the wrong branch,
//  would quietly undo. The same goes the other way: `notAuthenticated` telling
//  a signed-out hiker to sign in is the difference between a fixable problem
//  and a shrug.
//
//  `CKRecord`-free and container-free on purpose — see the note in
//  ``CommunityPhotoPairingTests``.
//

import CloudKit
import Foundation
@testable import OpenHikes
import Testing

@Suite("Community failure mapping")
struct CommunityFailureMappingTests {
    /// A failure the app raised itself, handed back unchanged.
    ///
    /// The transport throws `CommunityFailure` before it ever reaches
    /// CloudKit — an empty route, a signed-out account — and those pass
    /// through the same `catch`. Re-wrapping one would turn a sentence the
    /// screen knows how to explain into `unavailable` plus whatever
    /// `localizedDescription` happened to say.
    @Test(
        "a failure the app raised is not translated again",
        arguments: [
            CommunityFailure.nothingToShare,
            .notSignedIn,
            .noLongerAvailable,
            .notPermitted,
            .unreachable,
            .unavailable("already said"),
        ]
    )
    func ownFailuresPassThrough(failure: CommunityFailure) {
        #expect(
            CloudKitCommunityTransport.failure(from: failure, while: "submitting") == failure
        )
    }

    /// CloudKit's own retry vocabulary, folded into one sentence.
    ///
    /// These five are the conditions that mean *try again later*. Telling them
    /// apart would only let the UI offer three wordings of the same advice,
    /// and the set is what keeps them together.
    @Test(
        "the retryable conditions all become one unreachable",
        arguments: [
            CKError.Code.networkFailure,
            .networkUnavailable,
            .requestRateLimited,
            .serviceUnavailable,
            .zoneBusy,
        ]
    )
    func retryableConditionsAreUnreachable(code: CKError.Code) {
        #expect(
            CloudKitCommunityTransport.failure(from: CKError(code), while: "browsing")
                == .unreachable
        )
    }

    /// The two ways an account can be missing, which are one thing to say.
    ///
    /// A managed account with iCloud restricted is not signed out, but nothing
    /// the app can offer tells the two apart usefully — both mean this phone
    /// cannot write to the public database.
    @Test(
        "an absent or restricted account asks the hiker to sign in",
        arguments: [CKError.Code.notAuthenticated, .managedAccountRestricted]
    )
    func missingAccountIsNotSignedIn(code: CKError.Code) {
        #expect(
            CloudKitCommunityTransport.failure(from: CKError(code), while: "submitting")
                == .notSignedIn
        )
    }

    /// A record that is not there any more.
    ///
    /// The hiker's list is a snapshot, so a listing can outlive the submission
    /// behind it — a reviewer took it down between the page arriving and the
    /// tap. That is an ordinary thing to have happened, and saying so is what
    /// stops it reading as a fault.
    @Test("a record that has gone reads as no longer available")
    func unknownItemIsNoLongerAvailable() {
        #expect(
            CloudKitCommunityTransport.failure(from: CKError(.unknownItem), while: "opening")
                == .noLongerAvailable
        )
    }

    /// The server refusing a reviewer, which only the review path can see.
    ///
    /// Every other method here reads a type `_world` may read or writes one
    /// `_icloud` may create, so a permission failure anywhere else is a schema
    /// mistake rather than a role that was taken away.
    @Test("the server refusing a reviewer reads as not permitted")
    func permissionFailureIsNotPermitted() {
        #expect(
            CloudKitCommunityTransport.failure(from: CKError(.permissionFailure), while: "publishing")
                == .notPermitted
        )
    }

    /// Everything CloudKit says that the app has no sentence for.
    ///
    /// A full account is the honest example: it is nobody's transient problem
    /// and waiting will not fix it, but it is also not something this app can
    /// offer to do anything about, so the diagnostic is what survives.
    @Test(
        "an unclassified CloudKit error keeps its diagnostic",
        arguments: [CKError.Code.quotaExceeded, .badContainer, .incompatibleVersion]
    )
    func unclassifiedCloudKitErrorsCarryTheirDescription(code: CKError.Code) {
        let error = CKError(code)
        #expect(
            CloudKitCommunityTransport.failure(from: error, while: "submitting")
                == .unavailable(error.localizedDescription)
        )
    }

    /// An error from somewhere that is not CloudKit at all.
    ///
    /// Staging writes files before anything is uploaded, so a full disk or a
    /// protected directory reaches the same `catch` as a network timeout. It
    /// is not a `CKError`, and reading its code as one would classify it by
    /// whatever `NSError` domain it happened to carry.
    @Test("an error from outside CloudKit keeps its own description")
    func nonCloudKitErrorsCarryTheirDescription() {
        let error = NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileWriteOutOfSpaceError,
            userInfo: [NSLocalizedDescriptionKey: "The disk is full."]
        )

        #expect(
            CloudKitCommunityTransport.failure(from: error, while: "staging")
                == .unavailable(error.localizedDescription)
        )
    }

    /// A CloudKit code whose number matches nothing CloudKit defines.
    ///
    /// `CKError.Code` is an enum over a fixed list, and a payload carrying a
    /// number outside it is what a newer OS filing an error this build has
    /// never heard of looks like. It has to land on the diagnostic rather than
    /// crash or be read as the nearest neighbour.
    @Test("a code this build does not know is not mistaken for one it does")
    func unrecognisedCodeIsNotGuessedAt() {
        let error = CKError(_nsError: NSError(domain: CKErrorDomain, code: 999_999))

        guard case .unavailable = CloudKitCommunityTransport.failure(from: error, while: "browsing")
        else {
            Issue.record("An unknown CloudKit code should keep its diagnostic.")
            return
        }
    }
}

private extension CKError {
    /// The same shape ``CloudSyncOutcomeTests`` builds, for the same reason:
    /// `CKError` has no public initializer, and a real one needs the service.
    init(_ code: Code) {
        self.init(_nsError: NSError(domain: CKErrorDomain, code: code.rawValue))
    }
}
