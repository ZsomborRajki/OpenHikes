//
//  CommunityQueueingMarkerTests.swift
//  OpenHikesDataTests
//
//  When the device-local "this upload still has to be queued" note is still
//  worth acting on.
//
//  The note is written once, on one device, and the mirrored columns beside it
//  go on moving — a reviewer publishes, another device finishes the upload
//  first, the hiker sends the hike again. A prompt to finish an upload that
//  somebody else already finished is harmless; one that finishes an *abandoned*
//  upload puts a second entry in front of a reviewer. So the whole rule is in
//  one function that asks nothing of a store, and the answers are pinned here.
//

import Foundation
@testable import OpenHikesData
import Testing

@Suite("Community queueing marker")
struct CommunityQueueingMarkerTests {
    @Test("no marker, nothing to finish")
    func noMarkerMeansNothingOwed() {
        #expect(
            CommunityQueueingMarker.pendingID(
                marker: nil,
                submissionID: "submission-1",
                resultID: nil
            ) == nil
        )
    }

    @Test("a marker for the submission the hike last sent is still owed")
    func matchingMarkerIsOwed() {
        #expect(
            CommunityQueueingMarker.pendingID(
                marker: "submission-1",
                submissionID: "submission-1",
                resultID: nil
            ) == "submission-1"
        )
    }

    /// The half-written state: the upload landed and this device ended between
    /// remembering it in one store and in the other. The marker is written
    /// first and carries the whole answer, so an empty mirrored column must not
    /// make it look stale — it is the only thing left that knows.
    @Test("an empty mirrored column does not make the marker stale")
    func missingSubmissionColumnStillCounts() {
        #expect(
            CommunityQueueingMarker.pendingID(
                marker: "submission-1",
                submissionID: nil,
                resultID: nil
            ) == "submission-1"
        )
    }

    /// A listing or a contribution exists because a reviewer was shown the
    /// submission, which is the thing the marker says has not happened.
    @Test("a result means the submission was queued, however this device last heard")
    func resultMakesTheMarkerStale() {
        #expect(
            CommunityQueueingMarker.pendingID(
                marker: "submission-1",
                submissionID: "submission-1",
                resultID: "listing-1"
            ) == nil
        )
        #expect(
            CommunityQueueingMarker.pendingID(
                marker: "submission-1",
                submissionID: nil,
                resultID: "listing-1"
            ) == nil
        )
    }

    /// A send writes its own name into the mirrored column. Finishing the one
    /// before it would put an abandoned upload in the queue beside the one that
    /// replaced it.
    @Test("a different submission replaces the marker")
    func replacedSubmissionMakesTheMarkerStale() {
        #expect(
            CommunityQueueingMarker.pendingID(
                marker: "submission-1",
                submissionID: "submission-2",
                resultID: nil
            ) == nil
        )
    }
}
