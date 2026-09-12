//
//  CommunityPublicationCheck.swift
//  OpenHikes
//
//  Where a hike is on the one-way trip from private to published, and the
//  single question this app is able to ask about it.
//
//  Both halves are here rather than on ``Hike`` because both are rules rather
//  than storage: the state is two optional columns read together, and the
//  check is the only thing in the app allowed to write the second one. A suite
//  can exercise either without a `@Model` or a container.
//
//  ## What the app can and cannot know
//
//  It can know that a listing exists for its submission, because a listing is
//  `_world` read and carries a reference to the submission it was published
//  from. It cannot know anything else — and in particular it cannot tell a
//  reviewer who has not looked yet from one who looked and declined, because
//  a decline leaves no record at all. See ``CommunitySchema``.
//
//  So there are three states and not four. *Refused* is not one of them, and
//  adding it would mean inventing an observation nothing supports.
//

import Foundation
import os
import SwiftData

/// How far along a hike is towards being visible to other people.
///
/// Derived from two columns rather than stored as a third, so it cannot
/// disagree with them — the failure a stored status field invites is a hike
/// whose ``Hike/communityListingID`` says published while its status says
/// pending, and no amount of care at the call sites prevents that.
nonisolated enum CommunityPublicationState: Equatable, Sendable {
    /// Sent and accepted, with no listing seen for it yet. Covers a reviewer
    /// who has not looked and one who declined, which are the same absence —
    /// see this file's header for why there is no fourth case.
    case awaitingReview
    /// Never sent from this account, so the share button is an offer.
    case notShared
    /// A listing exists. Other people can find this hike.
    case published

    /// - Parameters:
    ///   - submissionID: ``Hike/communitySubmissionID``.
    ///   - listingID: ``Hike/communityListingID``.
    init(submissionID: String?, listingID: String?) {
        // Listing first: a hike can only have one if it was submitted, and
        // reading them the other way round would make a published hike with a
        // cleared submission id look unshared.
        if listingID != nil {
            self = .published
        } else if submissionID != nil {
            self = .awaitingReview
        } else {
            self = .notShared
        }
    }

    /// Whether sharing this hike now would make a *second* submission.
    ///
    /// True in both states that have already sent one, which is the whole
    /// point: the app cannot replace or withdraw a submission — see
    /// ``CommunityTransporting``, which has no method for either — so a second
    /// share is a second hike in the list rather than an edit of the first.
    /// The share form says so before it will send one.
    var wouldDuplicate: Bool { self != .notShared }
}

/// Asks whether a submission has been published, and remembers a yes.
@MainActor
enum CommunityPublicationCheck {
    private static let logger = Logger(subsystem: "OpenHikes", category: "Community")

    /// Brings `hike`'s ``Hike/communityListingID`` up to date, asking at most
    /// one question and only when there is one worth asking.
    ///
    /// Silent about every failure, and that is deliberate rather than lazy.
    /// This runs because a screen appeared, not because the hiker asked for
    /// anything, so there is no request for a failure to be the answer to — an
    /// offline phone opening a hike it shared last week should show *waiting
    /// for review*, which is what it showed before and is still the most
    /// accurate thing anybody can say. An alert here would interrupt a screen
    /// the hiker opened to look at their own walk.
    ///
    /// - Parameter save: The commit seam, the same shape ``CommunityPublisher``
    ///   and ``HikeImport`` take theirs in.
    /// - Returns: Whether anything was written, which is what a suite asserts
    ///   on and what the caller uses to avoid asking twice in one launch.
    @discardableResult static func refresh(
        _ hike: Hike,
        transport: any CommunityTransporting,
        save: (ModelContext) throws -> Void = { try $0.save() }
    ) async -> Bool {
        // Nothing to ask about, and — for an already-published hike — nothing
        // that could change the answer. Publication is one-way here; see
        // ``Hike/communityListingID`` for why a takedown is allowed to leave
        // this stale rather than cost a request per screen forever.
        guard let submissionID = hike.communitySubmissionID,
              hike.communityListingID == nil
        else { return false }

        let listing: CommunityListing?
        do {
            listing = try await transport.publication(of: submissionID)
        } catch {
            logger.debug(
                """
                Could not check whether a hike is published: \
                \(error.localizedDescription, privacy: .public)
                """
            )
            return false
        }
        guard let listing else { return false }

        // The hike may have been deleted while the request was in flight — a
        // detail screen is one back-swipe and one delete away — in which case
        // there is simply nothing left to record it on. The same guard, and
        // the same reasoning, as the end of ``CommunityPublisher/share``.
        guard hike.isAttached else { return false }
        hike.communityListingID = listing.id
        guard let context = hike.modelContext else { return false }
        do {
            try save(context)
        } catch {
            // Costs a repeated check on the next launch and nothing else: the
            // listing is real either way, and this column is a cache of a
            // public fact rather than the fact itself.
            logger.error(
                """
                Saw a hike go live but could not record it locally: \
                \(error.localizedDescription, privacy: .public)
                """
            )
        }
        return true
    }
}
