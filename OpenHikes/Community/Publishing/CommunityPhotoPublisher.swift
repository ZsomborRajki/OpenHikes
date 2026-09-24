//
//  CommunityPhotoPublisher.swift
//  OpenHikes
//
//  Turning the photographs a hiker took on a trail that is already public into
//  a submission somebody may one day review.
//
//  ``CommunityPublisher`` with the route, the title and the prose taken out —
//  and that subtraction is the entire feature. What a hiker brings back from a
//  trail somebody else published is not a route that list needs a second copy
//  of; it is the pictures, which a curated OpenStreetMap route has *none* of
//  and a published hike has only its author's.
//
//  Everything that made the hike publisher careful applies here unchanged, so
//  it is worth saying which things rather than restating why:
//
//  - the staging directory is created here, owned here, and deleted here on
//    every exit, so a failed upload leaves nothing on disk;
//  - the `@Model` is read once, on the main actor, before any suspension;
//  - ``Hike/communityPhotoSubmissionID`` is written **after** CloudKit has
//    accepted, because writing it first would make a failed send look like a
//    successful one for good;
//  - the re-encode, the cap and the ordering are ``CommunityPublisher``'s own
//    constants rather than a second opinion about them.
//
//  ## The one rule that is new
//
//  **A contribution with no photographs is not a contribution.** A hike share
//  refuses a hike with no route; this refuses a set with no pictures, and it
//  is the same kind of floor. It matters more here because the empty case is
//  *ordinary*: a hiker who saved a trail and has not photographed it yet
//  reaches the same button, and the honest answer is that there is nothing to
//  send rather than an upload carrying a credit and two empty fields.
//
//  Photo *rows* mirror between a hiker's devices and photo *files* do not —
//  see *Photo pixels stay on the device the photo was added on* in the
//  repository instructions — so "no photographs" here means none this device
//  can actually send, which is asked of the disk and not of the rows.
//

import Foundation
import OpenHikesData
import os
import SwiftData

/// Everything read off the `@Model` before any suspension, in one value that
/// can cross to the encoding executor.
///
/// ``SharedHikeDetails``'s opposite number, and deliberately a different type
/// for the reason that one is deliberately not ``GPXExport/Track``: these are
/// two different subsets of a hike that would drift the moment either grew a
/// field.
nonisolated struct ContributedPhotoDetails: Sendable {
    var hikeID: UUID
    var target: CommunityPhotoTarget
    var authorName: String
    var takenOn: Date
}

/// A contribution draft, and which of the hike's photographs went into it.
///
/// ``StagedSubmission``'s counterpart, kept apart from it for the reason the
/// two details types are kept apart: they wrap different drafts, and one type
/// carrying either would be a field that is sometimes there.
nonisolated struct StagedContribution: Sendable {
    var draft: CommunityPhotoDraft
    /// In upload order, and only the pictures a file was written for.
    var photoIDs: [UUID]
}

nonisolated enum CommunityPhotoPublisher {
    private static let logger = Logger(subsystem: "OpenHikes", category: "Community")

    /// Offers `hike`'s photographs to the hike `target` names, waiting for
    /// CloudKit to accept them.
    ///
    /// - Parameter target: Where they go. Comes from
    ///   ``CommunityPublishingEligibility/photographsOnly(_:because:)``, which
    ///   is the only thing that produces one — so a contribution can never be
    ///   aimed anywhere except at a trail the app has established is already
    ///   in the list.
    /// - Parameter authorName: What to credit them to. The hiker's own words,
    ///   the same ``SettingsKey/communityAuthorName`` a shared hike uses.
    /// - Parameter excludingPhotos: The pictures struck off on the form, by
    ///   id. Applied *before* the cap, for the reason
    ///   ``CommunityPublisher/selectedPhotos(of:excluding:)`` applies it
    ///   before the cap: taking one out should let the next one in.
    /// - Parameter save: The commit seam, the same shape every other write in
    ///   this feature takes one in.
    @MainActor
    static func contribute(
        _ hike: Hike,
        to target: CommunityPhotoTarget,
        authorName: String,
        transport: any CommunityTransporting,
        excludingPhotos excluded: Set<UUID> = [],
        store: HikePhotoStore = .shared,
        save: (ModelContext) throws -> Void = { try $0.save() }
    ) async -> CommunitySendOutcome {
        let details = ContributedPhotoDetails(
            hikeID: hike.id,
            target: target,
            authorName: authorName,
            takenOn: hike.date
        )
        let photos = CommunityPublisher.selectedPhotos(of: hike, excluding: excluded)
        // Checked against the rows before the directory is made, because the
        // common way to get here with nothing to send is a hike nobody has
        // photographed. The *files* are checked below, after the re-encode,
        // where a row whose picture lives on another device finally shows up
        // as a missing file.
        guard !photos.isEmpty else { return .refused(.noPhotosToShare) }

        let workingDirectory = CommunityStaging.contributionDirectory(of: details.hikeID)
        CommunityStaging.sweep()
        defer { CommunityStaging.discard(workingDirectory) }

        let staged = await prepare(details, photos: photos, in: workingDirectory, store: store)
        // Every row this device holds a file for failed to encode, or held no
        // file at all. Refused rather than sent: an upload of nothing is a
        // record in a public database, a row in a reviewer's queue, and a
        // hiker told their pictures are waiting when none of them left.
        guard !staged.draft.photoFileURLs.isEmpty else { return .refused(.noPhotosToShare) }

        let submissionID: String
        do {
            submissionID = try await transport.submitPhotos(staged.draft)
        } catch {
            let failure = error as? CommunityFailure ?? .unavailable(error.localizedDescription)
            logger.error(
                "Contributing photos failed: \(failure.localizedDescription, privacy: .public)"
            )
            return .refused(failure)
        }

        // The upload landed, and only now is anything written down. The hike
        // may have been deleted while it was in flight, in which case the
        // submission stands and there is nothing here left to remember it.
        guard hike.isAttached else { return .submitted }
        hike.communityPhotoSubmissionID = submissionID
        // Both columns together, because they describe one upload between
        // them — the rule ``CommunityPublisher/share`` follows for the other
        // pair, and the consequence of breaking it is the same: a stale
        // *published* about a set no reviewer has seen, and a check that skips
        // the new submission forever because the old answer is still sitting
        // there.
        hike.communityPhotoContributionID = nil
        // And with them, which pictures are now up there — in this same
        // commit, for the reason the pair above are written in one. A top-up
        // opens on what this leaves behind: the photographs already sent,
        // struck off, and whatever has been added since, ticked.
        CommunityPublisher.markSent(staged.photoIDs, on: hike)
        if let context = hike.modelContext {
            do {
                try save(context)
            } catch {
                // The submission is real either way, so this is not a failed
                // contribution. What is lost is the device's memory of it,
                // which costs the hiker a button offering to send pictures
                // that are already sent.
                logger.error(
                    """
                    Contributed photos but could not record it locally: \
                    \(error.localizedDescription, privacy: .public)
                    """
                )
            }
        }
        return .submitted
    }

    /// Re-encodes the photographs and assembles the draft, entirely off the
    /// main actor.
    ///
    /// `@concurrent` rather than a bare `nonisolated async` for the reason
    /// ``CommunityPublisher/prepare(_:photos:in:store:)`` is: the caller is
    /// the main actor, and a dozen JPEG encodes belong anywhere else.
    @concurrent
    private static func prepare(
        _ details: ContributedPhotoDetails,
        photos: [HikePhoto],
        in directory: URL,
        store: HikePhotoStore
    ) async -> StagedContribution {
        let staged = CommunityStaging.stagePhotos(photos, into: directory, store: store)
        let draft = CommunityPhotoDraft(
            target: details.target,
            hikeID: details.hikeID,
            authorName: details.authorName,
            takenOn: details.takenOn,
            photoPins: staged.pins,
            photoFileURLs: staged.fileURLs,
            stagingDirectory: directory
        )
        return StagedContribution(draft: draft, photoIDs: staged.photoIDs)
    }
}
