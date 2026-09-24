//
//  CommunityPublishedPhotos.swift
//  OpenHikes
//
//  What publishing a submission does to its photographs, and what the listing
//  is then allowed to claim about them.
//
//  Two answers rather than one, because they are the same answer: the record
//  is rewritten to hold a set, and the count on the listing is the size of
//  what the record ends up holding. Computed apart from ``CommunityReviewView``
//  for the reason ``CommunityShareDisclosure`` is — a promise and the payload
//  behind it belong in one place, and this is the promise a row makes about a
//  gallery nobody has opened yet.
//
//  The case that made this its own type is the incomplete download. The
//  rewrite is built out of the copies on this device, so it may only happen
//  when every photograph arrived — otherwise it would delete the missing one
//  too, permanently, with nobody having decided anything about it (see
//  ``CommunityHikeDetail/photosOnRecord``). The review screen already refuses
//  to *offer* removal in that state. What it did not do was stop counting as
//  if the removal had happened: it wrote the survivors' number onto a listing
//  whose record still served every asset, so the row promised fewer
//  photographs than the hike opens with, and the uncounted one stayed
//  fetchable by anybody who opened it.
//
//  So the rule is: **the count describes the record, and a rewrite is what
//  makes a smaller count true.** Where no rewrite happens, the count is what
//  the record already has.
//

import Foundation
import OpenHikesData

nonisolated struct CommunityPublishedPhotos: Equatable, Sendable {
    /// What publishing does to the assets already on the record.
    enum Rewrite: Equatable, Sendable {
        /// Leave them exactly as they are. Both cases that must not touch the
        /// record — nothing was struck off, and not everything arrived — say
        /// this, so the call site has one branch rather than two.
        case leaveTheRecordAlone
        /// Rebuild the record's photographs out of these downloaded ones.
        case keepOnly(Set<Int>)
    }

    let rewrite: Rewrite
    /// How many photographs the published listing may say it has.
    ///
    /// Always what the record will hold once ``rewrite`` has been applied,
    /// which is what makes it true for a reader who opens the hike rather
    /// than only for the reviewer who was looking at it.
    let count: Int

    /// - Parameters:
    ///   - photosOnRecord: what the submission actually carries.
    ///   - downloaded: how many of those reached this device.
    ///   - removing: the indexes into the downloaded set the reviewer struck
    ///     off. Indexes outside it are ignored, which is why the count is
    ///     taken from the kept set rather than by subtraction.
    init(photosOnRecord: Int, downloaded: Int, removing: Set<Int>) {
        let hasEveryPhoto = downloaded == photosOnRecord
        guard hasEveryPhoto, !removing.isEmpty else {
            rewrite = .leaveTheRecordAlone
            count = photosOnRecord
            return
        }
        let kept = Set(0..<downloaded).subtracting(removing)
        rewrite = .keepOnly(kept)
        count = kept.count
    }
}

// MARK: - What the reviewer is told

/// The two sentences a review screen puts under the strip.
///
/// Here rather than on either screen because both of them draw both, and they
/// are about this type's subject: what a rewrite is built from, and therefore
/// what it can and cannot be asked to do. The hike's reviewer and the
/// contribution's reviewer are making the same decision about the same kind of
/// record, and two wordings of it would be two accounts of one risk.
///
/// Both are number-neutral after the count, the rule
/// ``CommunityShareDisclosure`` already follows: one photograph reads as
/// written English rather than as a template with a 1 in it. The singular is
/// each string's plural variation in the catalog.
nonisolated extension CommunityPublishedPhotos {
    /// Why nothing can be left out, when a download came back short.
    static func incompleteDownload(missing: Int) -> String {
        String(
            localized: """
            \(missing) of this submission's photos didn't download, so none \
            can be left out here — leaving one out rewrites the whole set \
            from the copies on this device. Publish it as it is, decline it, \
            or open it again.
            """
        )
    }

    /// What publishing will do to the struck-off photographs.
    ///
    /// Said plainly because it is the only irreversible thing on either review
    /// screen short of declining, and because the strip above it is still
    /// showing the pictures it is about.
    static func removalWarning(count: Int) -> String {
        String(
            localized: """
            Publishing deletes the \(count) faded photos from the submission \
            for good. The rest still go.
            """
        )
    }
}
