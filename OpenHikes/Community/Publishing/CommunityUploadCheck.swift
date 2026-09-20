//
//  CommunityUploadCheck.swift
//  OpenHikes
//
//  The one question this app can ask about something it has uploaded, and the
//  three states the answer leaves a hike in.
//
//  It gets asked twice over, about two different pairs of columns.
//  ``CommunityPublicationCheck`` asks *is there a listing pointing at my
//  submission*; ``CommunityContributionCheck`` asks *is there a contribution
//  record pointing at my photo submission*. Both are queries on a world-read
//  type keyed on a record name only the author holds, both write a second
//  column beside the first, and both are silent about every failure.
//
//  The two used to be written out separately, with the second saying the
//  parallel was exact on purpose. It was — and an exact parallel maintained by
//  hand is two places for a guard to be dropped from. Both halves now live
//  here: the state machine as ``CommunityUploadState``, and the refresh as
//  ``refreshUploadResult(of:submission:result:asking:reportingFailureAs:)``.
//
//  ## What the app can and cannot know
//
//  It can know that a record exists for its submission. It cannot know
//  anything else — and in particular it cannot tell a reviewer who has not
//  looked yet from one who looked and declined, because a decline leaves no
//  record at all. See ``CommunitySchema``.
//
//  So there are three states and not four. *Refused* is not one of them, and
//  adding it would mean inventing an observation nothing supports.
//

import Foundation
import os
import SwiftData

/// How far along an upload is towards being visible to other people.
///
/// Derived from two columns rather than stored as a third, so it cannot
/// disagree with them — the failure a stored status field invites is a hike
/// whose id column says published while its status says pending, and no amount
/// of care at the call sites prevents that.
///
/// Conformers declare the three cases and their own labelled initialiser
/// naming the two columns they read; everything below is the same for both,
/// because both pairs of columns mean the same thing.
nonisolated protocol CommunityUploadState: Equatable, Sendable {
    /// Sent and accepted, with no published record seen for it yet. Covers a
    /// reviewer who has not looked and one who declined, which are the same
    /// absence — see this file's header for why there is no fourth case.
    static var awaitingReview: Self { get }
    /// Never sent from this account, so the button is an offer.
    static var notShared: Self { get }
    /// A record exists. Other people can see this.
    static var published: Self { get }
}

// `nonisolated` and not decoration: the targets build with
// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so an unannotated extension
// is a main-actor context — and both conformers are `nonisolated` enums
// built from a view's body. Without this the initialiser below cannot be
// called from either of them.
nonisolated extension CommunityUploadState {
    /// - Parameters:
    ///   - submissionID: The record name the upload was accepted under.
    ///   - resultID: The record name a reviewer's *yes* left behind, if one
    ///     has been seen.
    init(submissionID: String?, resultID: String?) {
        // The result first: the second column can only exist because of the
        // first, and reading them the other way round would make a published
        // upload with a cleared submission id look unsent.
        if resultID != nil {
            self = .published
        } else if submissionID != nil {
            self = .awaitingReview
        } else {
            self = .notShared
        }
    }

    /// Whether sending now would make a *second* upload of the same thing.
    ///
    /// True in both states that have already sent one, which is the whole
    /// point: the app cannot replace or withdraw a submission — see
    /// ``CommunityTransporting``, which has no method for either — so a second
    /// send is a second copy beside the first rather than an edit of it. The
    /// form says so before it will send one.
    var wouldDuplicate: Bool { self != .notShared }
}

/// The shared half of both checks: ask once, and write the answer down.
@MainActor
enum CommunityUploadCheck {
    private static let logger = Logger(subsystem: "OpenHikes", category: "Community")

    /// What to say when a check gives up, per caller.
    ///
    /// Two sentences rather than one built from a noun, because these are the
    /// only description either check has and a reader of the log is trying to
    /// tell two features apart.
    struct FailureMessages {
        /// Logged at `debug` when the question could not be asked.
        let couldNotAsk: String
        /// Logged at `error` when the answer could not be written down.
        let couldNotRecord: String
    }

    /// Brings `result` up to date from `submission`, asking at most one
    /// question and only when there is one worth asking.
    ///
    /// Silent about every failure, and that is deliberate rather than lazy.
    /// This runs because a screen appeared, not because the hiker asked for
    /// anything, so there is no request for a failure to be the answer to — an
    /// offline phone opening a hike it shared last week should show *waiting
    /// for review*, which is what it showed before and is still the most
    /// accurate thing anybody can say. An alert here would interrupt a screen
    /// the hiker opened to look at their own walk.
    ///
    /// - Parameters:
    ///   - submission: The column holding the record name the upload was
    ///     accepted under. Nothing to ask about when it is `nil`.
    ///   - result: The column a *yes* is written to. Already having one means
    ///     nothing could change the answer — publication is one-way here; see
    ///     ``Hike/communityListingID`` for why a takedown is allowed to leave
    ///     it stale rather than cost a request per screen forever.
    ///   - asking: The question, which is the only thing that differs between
    ///     the two features.
    ///   - save: The commit seam, the same shape ``CommunityPublisher`` and
    ///     ``HikeImport`` take theirs in.
    /// - Returns: Whether anything was written, which is what a suite asserts
    ///   on and what the caller uses to avoid asking twice in one launch.
    @discardableResult static func refreshUploadResult(
        of hike: Hike,
        submission: ReferenceWritableKeyPath<Hike, String?>,
        result: ReferenceWritableKeyPath<Hike, String?>,
        asking ask: (String) async throws -> String?,
        reportingFailureAs messages: FailureMessages,
        save: (ModelContext) throws -> Void = { try $0.save() }
    ) async -> Bool {
        guard let submissionID = hike[keyPath: submission],
              hike[keyPath: result] == nil
        else { return false }

        let resultID: String?
        do {
            resultID = try await ask(submissionID)
        } catch {
            logger.debug(
                """
                \(messages.couldNotAsk, privacy: .public): \
                \(error.localizedDescription, privacy: .public)
                """
            )
            return false
        }
        guard let resultID else { return false }

        // The hike may have been deleted while the request was in flight — a
        // detail screen is one back-swipe and one delete away — in which case
        // there is simply nothing left to record it on. The same guard, and
        // the same reasoning, as the end of ``CommunityPublisher/share``.
        guard hike.isAttached else { return false }
        // And it may be asking about a different submission than the one this
        // answer is about. A re-send landing inside the await replaces the
        // submission column and clears the result beside it — both
        // deliberately, because the two columns are one answer about one
        // upload — and writing this answer back would undo exactly that: the
        // pair would read new-submission/old-result, which reports *published*
        // about a copy no reviewer has seen and, because the guard above skips
        // a hike that already has a result, stops the new submission ever
        // being asked about. That is the state #256 fixed, reached from the
        // other side.
        //
        // It does not take a second tap to get here. Both columns are mirrored
        // so a second device does not offer to send something already sent, so
        // a send from the iPad can rewrite this one while the iPhone's check
        // is waiting on the network.
        //
        // Silent, like every other way this gives up: nothing asked for it,
        // and the answer for the current submission is *waiting for review*,
        // which is what the screen already says.
        guard hike[keyPath: submission] == submissionID else { return false }
        hike[keyPath: result] = resultID
        guard let context = hike.modelContext else { return false }
        do {
            try save(context)
        } catch {
            // Costs a repeated check on the next launch and nothing else: the
            // record is real either way, and this column is a cache of a
            // public fact rather than the fact itself.
            logger.error(
                """
                \(messages.couldNotRecord, privacy: .public): \
                \(error.localizedDescription, privacy: .public)
                """
            )
        }
        return true
    }
}
