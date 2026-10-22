//
//  SeededCommunityTransport+Queueing.swift
//  OpenHikes
//
//  The queueing half of an upload, for the stand-in database.
//
//  Split out of `SeededCommunityTransport.swift`, which is at the length
//  SwiftLint's `file_length` allows.
//

#if DEBUG

import Foundation

nonisolated extension SeededCommunityTransport {

    // A submission this stand-in invents is "in the queue" the moment it is
    // made, because there is no second record for it to fail to write. So the
    // repair has nothing to repair and answers the way the real one does for a
    // submission that is already queued — by succeeding — and is here only so
    // the stand-in is a complete conformance. The failure between the two
    // saves is exercised where it can be done honestly, a level down, by
    // ``CommunityRecordWriting`` in the transport's own suite.

    @concurrent
    func queueForReview(submissionID: String) async throws {
        guard scenario != .failing else { throw CommunityFailure.notSignedIn }
    }

    @concurrent
    func queuePhotosForReview(submissionID: String) async throws {
        guard scenario != .failing else { throw CommunityFailure.notSignedIn }
    }
}

#endif
