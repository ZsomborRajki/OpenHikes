//
//  HikeDeletionPrompt.swift
//  OpenHikes
//
//  What a hiker is told before a hike is deleted, and why it is a value type.
//
//  A left swipe used to delete a hike outright. What it took was the route,
//  the title, the statistics, the `HikeLocalState` sidecar, every photo file
//  under `HikePhotoStore`, the `HikeWalk` history by cascade, and the offline
//  tiles no surviving hike claimed — and because `Hike` is mirrored, it took
//  them from the hiker's other devices too. `HikeDeletion`'s own header calls
//  the photo files "the unrecoverable side of the same invariant": pixels stay
//  on the device the photo was added on, so for a recorded hike the device
//  doing the deleting is the only place they ever were.
//
//  The app already confirms five actions that cost less — *Discard Recording*,
//  *End Walk*, *Delete All* saved tiles, blocking an author, and unblocking
//  everyone. *Discard Recording* is the sharp comparison: the app already
//  holds that a walk's track is worth asking about before it is thrown away,
//  but only while it is still a draft.
//
//  A value type rather than a string built in a `body`, for the reason
//  `CommunityReport` is one: what the hiker is told is the substance of the
//  fix, and a suite should be able to assert it without driving a screen.
//

import Foundation

/// The wording of the confirmation shown before a hike is deleted.
struct HikeDeletionPrompt: Equatable {
    /// The dialog's title. Names the hike, because a swipe on the wrong row is
    /// the mistake this is here to catch and a generic "Delete this hike?"
    /// cannot catch it.
    let title: String
    /// The body. Says what actually goes, in the order of what cannot come
    /// back.
    let message: String
    /// The destructive button.
    let confirmTitle: String

    /// - Parameters:
    ///   - title: ``Hike/displayTitle``.
    ///   - photoCount: How many photographs the hike carries.
    ///   - walkCount: How many walks are attached, which cascade with it.
    ///   - publication: Whether a copy of this hike is already public.
    init(
        title: String,
        photoCount: Int,
        walkCount: Int,
        publication: CommunityPublicationState
    ) {
        self.title = String(localized: "Delete “\(title)”?")
        confirmTitle = String(localized: "Delete Hike")
        message = Self.message(
            photoCount: photoCount,
            walkCount: walkCount,
            publication: publication
        )
    }

    init(hike: Hike) {
        self.init(
            title: hike.displayTitle,
            photoCount: hike.photos.count,
            walkCount: hike.walks?.count ?? 0,
            publication: CommunityPublicationState(
                submissionID: hike.communitySubmissionID,
                listingID: hike.communityListingID
            )
        )
    }

    /// Three sentences at most, and each one earns its place.
    ///
    /// The route is always named, because it is always what goes. The
    /// photographs and the walks are named only when there are some — a hike
    /// with neither should not be described as though the hiker were about to
    /// lose them. The other-devices sentence is unconditional: it is the half
    /// of this that no amount of care on *this* phone can undo.
    private static func message(
        photoCount: Int,
        walkCount: Int,
        publication: CommunityPublicationState
    ) -> String {
        var sentences = [loss(photoCount: photoCount, walkCount: walkCount)]
        sentences.append(
            String(localized: "This also removes it from your other devices.")
        )
        // Said only when there is a copy the deletion cannot reach, and
        // phrased the way the share sheet and the report sheet already
        // distinguish *sent* from *published*: nothing here claims a takedown
        // happened, because nothing here can make one happen.
        switch publication {
        case .notShared:
            break
        case .awaitingReview:
            sentences.append(
                String(
                    localized: """
                        The copy you sent to the community stays where it is; \
                        deleting this hike does not withdraw it.
                        """
                )
            )
        case .published:
            sentences.append(
                String(
                    localized: """
                        The published copy stays in the community; \
                        deleting this hike does not take it down.
                        """
                )
            )
        }
        return sentences.joined(separator: " ")
    }

    /// The first sentence: what is gone for good.
    ///
    /// Photographs are named before walks because they are the only part with
    /// no second copy anywhere — the route came from a file or can be walked
    /// again, and a walk is a record of one; the pixels are not. A hike with
    /// neither is not described as though the hiker were about to lose them.
    ///
    /// Four whole sentences rather than one assembled from clauses, and the
    /// counts spelled out by hand: that is how the rest of the app pluralises
    /// (`MapSubscriptionTerms`, `CommunityHikeRow`, `HikeIntentReports`),
    /// there is no String Catalog to resolve inflection markup against yet
    /// (#32), and a translator handed a whole sentence can move its parts.
    private static func loss(photoCount: Int, walkCount: Int) -> String {
        switch (photoCount > 0, walkCount > 0) {
        case (false, false):
            String(localized: "Its route and statistics are deleted for good.")
        case (true, false):
            String(
                localized: """
                    Its route, statistics and \(photographs(photoCount)) \
                    are deleted for good.
                    """
            )
        case (false, true):
            String(
                localized: """
                    Its route, statistics and \(walks(walkCount)) \
                    are deleted for good.
                    """
            )
        case (true, true):
            String(
                localized: """
                    Its route, statistics, \(photographs(photoCount)) \
                    and \(walks(walkCount)) are deleted for good.
                    """
            )
        }
    }

    private static func photographs(_ count: Int) -> String {
        count == 1
            ? String(localized: "1 photograph")
            : String(localized: "\(count) photographs")
    }

    private static func walks(_ count: Int) -> String {
        count == 1
            ? String(localized: "1 hike")
            : String(localized: "\(count) hikes")
    }
}
