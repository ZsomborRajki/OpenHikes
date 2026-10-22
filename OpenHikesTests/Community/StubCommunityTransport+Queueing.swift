//
//  StubCommunityTransport+Queueing.swift
//  OpenHikesTests
//
//  The half of the stub that answers for the write which puts an upload in
//  front of a reviewer.
//
//  One type with `StubCommunityTransport.swift`, split for length alone —
//  which is why `state` and `queueingCursor` are internal there rather than
//  private, and why this says `nonisolated` where the type does not need to:
//  the test bundle is main-actor isolated by default, and an unannotated
//  extension would make these requirements main-actor members of a type the
//  rest of the stub reaches from off the main actor.
//

import Foundation
@testable import OpenHikes
import Synchronization

nonisolated extension StubCommunityTransport {

    @concurrent
    func queueForReview(submissionID: String) async throws {
        state.withLock { $0.queueAttempts.append(submissionID) }
        if let failure = nextQueueingFailure() { throw failure }
    }

    @concurrent
    func queuePhotosForReview(submissionID: String) async throws {
        state.withLock { $0.photoQueueAttempts.append(submissionID) }
        if let failure = nextQueueingFailure() { throw failure }
    }

    /// The answer for the next queue write, whichever call it is made by.
    ///
    /// Shared by ``submit(_:)`` and ``submitPhotos(_:)``, which write the
    /// notice straight after an upload, and by the two repairs above, so one
    /// ``queueingScript`` reads as a single history of the notice writes a
    /// suite provoked.
    func nextQueueingFailure() -> CommunityFailure? {
        let index = queueingCursor.withLock { cursor in
            defer { cursor += 1 }
            return cursor
        }
        return queueingScript.indices.contains(index) ? queueingScript[index] : nil
    }
}
