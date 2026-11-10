//
//  CommunityHikeReviewSession.swift
//  OpenHikes
//
//  One review of a queued hike, held where a turn of the phone cannot reach
//  it.
//
//  The review is drawn in the sheet in portrait and in the side panel in
//  landscape, so a turn builds it again in the other host. While what it held
//  was its own `@State`, the screen built there started the review over
//  (#1353): it downloaded the submission again, put back every photograph the
//  reviewer had struck off, set the title back to the one that was sent and
//  forgot a publish or a decline already under way. ``SheetPresentation``
//  keeps one of these for each queued hike on the stack, as it keeps a shared
//  hike's ``CommunityPreviewSession``, and ends it when the route leaves the
//  path — see ``CommunityReviewDecisions/end()``.
//
//  The contributed-photo review keeps a ``CommunityReviewDecisions`` and
//  nothing else, because the title is the one correction only a hike can
//  take — see ``CommunityReviewView``'s header.
//
//  ## What is worked out here rather than on a screen
//
//  What the title will be published as, whether it may be, and where each of
//  the submission's places sits along its route. Each is read by a section of
//  the form rather than by the form itself — see
//  `CommunityReviewSections.swift` — and the first two by the publish as well,
//  so they are said once, here. The places' anchors are kept for the review
//  for the reason the rest is: a turn of the phone measures nothing again.
//

import Foundation
import Observation
import OpenHikesData

@Observable
final class CommunityHikeReviewSession {
    /// Non-isolated so releasing the last reference never requires proving
    /// we're on the main actor — see ``LocationManager``'s deinit for why.
    nonisolated deinit { /* intentionally empty */ }

    /// What has arrived, what is struck off and the decision under way.
    let decisions: CommunityReviewDecisions<CommunityHikeDetail>
    /// The title as it will be published, which starts as the one that was
    /// sent.
    ///
    /// Only ever the *listing's* title. The submission keeps what its author
    /// wrote — see ``CommunityReviewView``'s header for why that is both
    /// possible and deliberate.
    var titleDraft: String
    /// Where the submission's places sit along its route, measured once for
    /// the review and off the main actor past ``HikePlaceRows``'s budget — see
    /// ``orderedPlaces(_:along:)``.
    let placeRows: HikePlaceRows
    /// Who ``placeRows`` keeps the anchors for. It holds one submission's
    /// only.
    private let placeOwner = UUID()

    init(pending: CommunityPendingSubmission, placeRows: HikePlaceRows = HikePlaceRows()) {
        decisions = CommunityReviewDecisions(listing: pending.prospectiveListing)
        titleDraft = pending.title
        self.placeRows = placeRows
    }

    /// The title this would be published under, bounded the way every other
    /// piece of free text reaching the public database is.
    ///
    /// Bounded here rather than on the field, so the reviewer types against no
    /// resistance and the ceiling applies to what is written — the same
    /// division ``HikeTitle`` makes, and the same ``TextBound/title`` the
    /// queue already bounded the submitted title to.
    ///
    /// Empty is possible, by clearing the field, and is refused rather than
    /// falling back to the submitted title: a reviewer who has emptied the box
    /// is mid-edit, and quietly publishing the name they just deleted is the
    /// app deciding something they did not.
    var publishedTitle: String {
        BoundedText.boundedOrEmpty(titleDraft, to: .title)
    }

    /// Whether publishing `pending` would produce a listing anybody can see.
    ///
    /// ``CommunityListing/init(record:)`` drops a listing whose `authorID` is
    /// blank, so publishing without one writes a record that is live, costs
    /// storage, and is invisible to every client including this one — the
    /// exact silent failure that publishing by hand in the Console made easy.
    /// It cannot happen here, because the field is read off the submission's
    /// creator rather than typed. The guard stays because *cannot happen* and
    /// *is not checked* are different things, and this is the one failure
    /// nothing downstream would ever report.
    ///
    /// ``CommunityReviewDecisions/canDecide`` carries the other half: nothing
    /// knows how many photographs there are until the detail arrives — a
    /// queue entry cannot — so a publish before then writes *no photos* onto
    /// a listing that has some. The title is the exception, and deliberately
    /// so: it is editable from the moment the screen opens, because the queue
    /// entry carries it and a reviewer can perfectly well fix a name while
    /// the pictures arrive.
    func canPublish(_ pending: CommunityPendingSubmission) -> Bool {
        decisions.canDecide && !pending.authorID.isEmpty && !publishedTitle.isEmpty
    }

    /// `places` in the order they are met along `route`, from what
    /// ``placeRows`` has measured — the order ``TrailPlaceOrder`` gives, with a
    /// place still being measured listed last and without a distance until
    /// its answer lands.
    func orderedPlaces(_ places: [TrailPlace], along route: [RouteCoordinate]) -> [TrailPlaceRow] {
        placeRows.rows(of: places, along: route, for: placeOwner)
    }
}
