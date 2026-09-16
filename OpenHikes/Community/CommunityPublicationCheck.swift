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
        // And it may be asking about a different submission than the one this
        // answer is about. A re-share landing inside the await replaces
        // ``Hike/communitySubmissionID`` and clears the listing beside it —
        // both deliberately, because the two columns are one answer about one
        // submission — and writing this listing back would undo exactly that:
        // the pair would read new-submission/old-listing, which reports
        // *published* about a copy no reviewer has seen and, because the guard
        // above skips a hike that already has a listing, stops the new
        // submission ever being asked about. That is the state #256 fixed,
        // reached from the other side.
        //
        // It does not take a second tap to get here. Both columns are mirrored
        // so a second device does not offer to send a trail that is already
        // sent, so a share from the iPad can rewrite this one while the
        // iPhone's check is waiting on the network.
        //
        // Silent, like every other way this gives up: nothing asked for it,
        // and the answer for the current submission is *waiting for review*,
        // which is what the screen already says.
        guard hike.communitySubmissionID == submissionID else { return false }
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

    /// Whether a listing still exists for `hike`'s submission.
    ///
    /// The same question ``refresh(_:transport:save:)`` asks, pointed the
    /// other way and — the difference that matters — asked because the hiker
    /// tapped rather than because a screen appeared. That is the answer to the
    /// argument in ``Hike/communityListingID`` against re-checking: the cost
    /// that argument refuses is *a request per detail-open forever*, and this
    /// is one request when somebody asks for it. The one-way rule is untouched.
    ///
    /// **A `nil` means taken down here, and does not in `refresh`.** There the
    /// absence of a listing covers a reviewer who has not looked yet and one
    /// who declined, which is why the screen never says *rejected*. Here a
    /// listing was seen at least once — that is what ``Hike/communityListingID``
    /// records — so the only thing its absence can mean is that it went away.
    ///
    /// **Throws where `refresh` stays silent**, and for the reason `refresh`
    /// is silent: nothing asked that one, so a failure was an interruption of
    /// a screen opened to look at a walk. This one was asked, so a failure is
    /// an answer the hiker is owed.
    ///
    /// Writes nothing, deliberately. What comes back is evidence, and
    /// ``forgetPublication(_:save:)`` is the decision that acts on it — split
    /// in two so the screen can confirm before forgetting a listing that a
    /// transient `nil` would otherwise erase on its own.
    static func liveness(
        of hike: Hike,
        transport: any CommunityTransporting
    ) async throws -> Liveness {
        guard let submissionID = hike.communitySubmissionID,
              hike.communityListingID != nil
        else { return .notPublished }

        let listing = try await transport.publication(of: submissionID)

        // The same two races ``refresh`` guards, from the other side. The hike
        // may have been deleted while the request was in flight, or re-shared
        // from another device — and ``Liveness/notPublished`` is the literal
        // truth of both, because a detached hike has no columns left to be
        // about and a re-share cleared the listing itself.
        guard hike.isAttached,
              hike.communitySubmissionID == submissionID,
              hike.communityListingID != nil
        else { return .notPublished }

        return listing == nil ? .takenDown : .live
    }

    /// Forgets that `hike` was ever shared, so a corrected walk can be sent.
    ///
    /// **Both columns, never one.** They are one answer about one submission —
    /// see ``Hike/communityListingID`` — and clearing only the listing would
    /// leave the hike reading *waiting for review* about a submission that is
    /// gone, which is a worse lie than the stale *published* it replaced. It
    /// would also go on blocking a re-record:
    /// ``CommunityPublishingCheck/alreadyShared(in:excluding:)`` fetches
    /// on ``Hike/communitySubmissionID`` alone, so a hike that keeps that
    /// column is still somebody else's retread however dead its listing is.
    ///
    /// What this costs is the two record names a removal request quotes, and
    /// that is the right trade only because of where it is called from: the
    /// listing has just been observed to be gone, so there is nothing left to
    /// ask back and ``CommunityWithdrawal`` needs a record that still exists.
    ///
    /// The photograph columns are left alone. They describe a different pair
    /// of records with their own review, and a contribution outliving the
    /// trail it was aimed at is already a defined state rather than a dangling
    /// reference — see ``CommunityPhotoTarget``.
    ///
    /// - Returns: Whether anything was written, which is what a suite asserts
    ///   on.
    @discardableResult static func forgetPublication(
        _ hike: Hike,
        save: (ModelContext) throws -> Void = { try $0.save() }
    ) -> Bool {
        guard hike.isAttached,
              hike.communitySubmissionID != nil || hike.communityListingID != nil,
              let context = hike.modelContext
        else { return false }

        hike.communitySubmissionID = nil
        hike.communityListingID = nil
        do {
            try save(context)
        } catch {
            // Unlike the cache above, this does not come right on the next
            // launch: nothing re-asks a hike that has no submission id, so a
            // failed save leaves the hike reading *published* until the hiker
            // taps again. Logged rather than swallowed for that reason.
            logger.error(
                """
                Could not forget a hike's publication locally: \
                \(error.localizedDescription, privacy: .public)
                """
            )
            return false
        }
        return true
    }
}

extension CommunityPublicationCheck {
    /// What asking after a published hike's listing came back with.
    ///
    /// Three cases rather than a `Bool`, because *there was nothing to ask* is
    /// a real outcome here: the hike may have been deleted or re-shared while
    /// the request was in flight, and reporting either of those as *taken
    /// down* would invite the screen to clear columns that describe a live
    /// submission.
    nonisolated enum Liveness: Equatable, Sendable {
        /// A listing still points at the submission.
        case live
        /// None does any more, and one did once — see
        /// ``CommunityPublicationCheck/liveness(of:transport:)`` for why that
        /// is unambiguous where the same absence is not in `refresh`.
        case takenDown
        /// This hike is not published, so the question did not apply.
        case notPublished
    }
}
