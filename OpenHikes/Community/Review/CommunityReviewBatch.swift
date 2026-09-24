//
//  CommunityReviewBatch.swift
//  OpenHikes
//
//  One look at the reviewer's queue: both kinds of thing waiting, from one
//  request.
//
//  ## Why one request rather than two lists asked for separately
//
//  Because the queue is asked for by **everybody**. It hangs off the
//  *Community* tab being selected, once per launch, and almost every one of
//  those launches is somebody who is not a reviewer and whose answer is a
//  permission refusal. A second record type for contributions would have been
//  the obvious shape and would have doubled that standing cost to list a
//  second kind of row in the same place, for nobody.
//
//  So ``CommunitySchema/noticeType`` carries both, through a second reference
//  field, and this is what comes back: one query, one sort — the server's
//  `___createTime`, so the oldest is looked at first whichever kind it is —
//  one refusal to catch, and one answer to the question
//  ``CommunityReviewQueue/isReviewer`` is really asking.
//
//  ## Why two arrays rather than one of a sum type
//
//  Because everything downstream of the queue is different for the two.
//  They open different screens, publish different record types, and carry
//  different facts — a hike has a route, a distance and a title a reviewer may
//  correct, and a contribution has photographs and a trail that already exists.
//  A single array of an enum would be a switch at every use site, and the
//  first thing every one of those sites does is separate them again.
//
//  What they *do* share is the queue's order, which is why the count and the
//  emptiness are asked of the batch rather than of either half: the section is
//  drawn when there is anything at all to review, and that is one question.
//

import Foundation
import OpenHikesData

/// Everything waiting for a reviewer, in the order the server queued it.
nonisolated struct CommunityReviewBatch: Equatable, Sendable {
    /// Hikes somebody has offered to publish, oldest first.
    var hikes: [CommunityPendingSubmission] = []
    /// Photographs somebody has offered to put on a hike that already exists,
    /// oldest first.
    var photographs: [CommunityPendingPhotos] = []

    /// Nothing to review. For a reviewer this is an empty queue; for everybody
    /// else it is what a refusal was turned into — and the two are told apart
    /// by ``CommunityReviewQueue/isReviewer``, never by this.
    var isEmpty: Bool { hikes.isEmpty && photographs.isEmpty }

    /// How many things are waiting, which is what the section header counts.
    var count: Int { hikes.count + photographs.count }
}
