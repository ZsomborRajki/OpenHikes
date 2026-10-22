//
//  CommunityQueueing.swift
//  OpenHikes
//
//  The second half of an upload: the write that tells a reviewer it exists.
//
//  A hike, or a set of contributed photographs, reaches the public database
//  as two saves that CloudKit will not make atomic — the submission, with
//  every asset on it, and then the notice that puts it in the reviewer's
//  queue (see ``CommunitySchema/noticeType`` for why the queue is a record
//  type of its own). The second can fail after the first has landed, and what
//  the caller must be told then is not *the upload failed*. The submission is
//  out there, readable by anybody holding its name and listed by nothing, and
//  it waits for nobody.
//
//  The shape this file gives that case was chosen against the alternatives
//  one at a time:
//
//  - **The failure carries the submission's name** (``CommunityQueueingFailure``),
//    because the name is the one thing the caller cannot get back. Throwing a
//    plain ``CommunityFailure`` there is what made a retry upload everything
//    again under a new random name and leave the first copy stranded for good.
//  - **The repair is the missing write and nothing else**
//    (``CommunityTransporting/queueForReview(submissionID:)``), so a retry —
//    now, or after a relaunch — never touches the route or the photographs
//    again.
//  - **The notice is named after its submission**
//    (``CommunitySchema/Notice/recordName(forSubmission:)``), so saving it
//    twice is saving it once. A save whose answer never arrived is the
//    ordinary case this has to survive, and a random name there would leave a
//    second notice behind on every such retry.
//  - **The server's permissions are untouched.** An author still cannot read
//    or change a notice, and the submission type is still write-once and
//    unindexed. Everything here is a *client* making a second request more
//    carefully, so nothing about what a modified client could do has changed.
//  - **Nothing relies on an atomic multi-record save.** CloudKit offers one
//    for records in a single zone of a private database, and the public
//    database is not that. A durable, retried second step is what this
//    repository can actually count on.
//

import CloudKit
import Foundation

/// A submission that reached the public database and did not reach the
/// reviewer's queue.
///
/// Thrown by ``CommunityTransporting/submit(_:)`` and
/// ``CommunityTransporting/submitPhotos(_:)`` in place of a plain
/// ``CommunityFailure`` when *only the second write* failed. The distinction
/// is the whole reason this type exists: a plain failure says nothing was
/// sent, and the caller's honest response to that is to send it all again.
///
/// ``CommunityFailure/init(_:)`` unwraps it, so a caller that only wants a
/// sentence gets the same one it always did.
nonisolated struct CommunityQueueingFailure: Error, Equatable, Sendable {
    /// The submission's record name — the only handle there is on what was
    /// uploaded.
    let submissionID: String
    /// Why the notice was not saved, as a sentence the hiker can be shown.
    let failure: CommunityFailure
}

nonisolated extension CommunityQueueingFailure: LocalizedError {
    var errorDescription: String? { failure.errorDescription }
    var recoverySuggestion: String? { failure.recoverySuggestion }
}

/// The two things an upload asks CloudKit for, as a seam a suite can script.
///
/// Deliberately narrow — an account check and a save, nothing a query could
/// grow out of. What it exists to make testable is the *boundary between the
/// two saves*, and that boundary is inside ``CloudKitCommunityTransport``:
/// a stub standing in for the whole transport can fail the upload or succeed
/// at it, but it cannot fail the notice after the submission has landed,
/// which is the one case that used to lose an upload. Putting the seam
/// underneath lets a suite run the real `submit` and the real record
/// building, refuse exactly the second save, and assert on both — without a
/// container, an account or a network, and without ever leaving a record in
/// the public database.
///
/// `@concurrent` on both requirements for the reason every requirement on
/// ``CommunityTransporting`` is. The container is built inside each call and
/// not held, for the reason `CloudKitCommunityTransport.swift`'s header gives.
nonisolated protocol CommunityRecordWriting: Sendable {
    @concurrent
    func accountStatus() async throws -> CKAccountStatus

    @concurrent
    func save(_ record: CKRecord) async throws -> CKRecord
}

/// The public database of the app's container, which is the only writer the
/// shipping app has.
nonisolated struct CloudKitRecordWriter: CommunityRecordWriting {
    let containerIdentifier: String

    @concurrent
    func accountStatus() async throws -> CKAccountStatus {
        try await CKContainer(identifier: containerIdentifier).accountStatus()
    }

    @concurrent
    func save(_ record: CKRecord) async throws -> CKRecord {
        try await CKContainer(identifier: containerIdentifier).publicCloudDatabase.save(record)
    }
}
