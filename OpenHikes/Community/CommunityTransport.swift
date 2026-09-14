//
//  CommunityTransport.swift
//  OpenHikes
//
//  The seam between the community feature and CloudKit, and the handful of
//  sentences a failure is allowed to say.
//
//  A protocol for the same reason ``TrailGraphProviding``,
//  ``TileTransporting`` and the injectable containers elsewhere are — see
//  *Deliberate test seams* in the repository instructions. The whole bundle
//  runs in one process, so a suite that reached a real `CKDatabase` would
//  reach the developer's own container, need an account, need a network, and
//  leak whatever it wrote into the next suite. Everything worth asserting
//  here is above this line: what is uploaded, what a query is allowed to ask
//  for, how results are ordered, and what happens to a hike when an upload
//  fails.
//
//  Every requirement is `@concurrent`, and that is part of the contract
//  rather than an implementation detail. `SWIFT_APPROACHABLE_CONCURRENCY`
//  makes a plain `nonisolated async` requirement `nonisolated(nonsending)`,
//  so it runs on its *caller's* executor — and every caller here is the main
//  actor. Without the annotation a conformance that blocks on a file write or
//  a synchronous framework call would block the UI while looking exactly like
//  offloaded work, which is the failure `CloudSyncCoordinator.offMainThread`
//  exists to document.
//

import CoreLocation
import Foundation

/// Why a community request did not do what was asked.
///
/// Deliberately short. Each case is a different thing to *say* to the hiker,
/// not a different thing that went wrong underneath — CloudKit distinguishes
/// dozens of conditions and almost none of them is a sentence anyone can act
/// on. Anything without its own case is ``unavailable``, which is logged with
/// the real diagnostic and shown as the one honest generality.
nonisolated enum CommunityFailure: LocalizedError, Equatable, Sendable {
    /// A published hike could not be found any more. A listing the hiker is
    /// looking at can outlive the submission behind it: a reviewer can take
    /// one down, and the hiker's own copy of the list is a snapshot.
    case noLongerAvailable
    /// The hike is not this hiker's to publish, is too short to be worth
    /// publishing, or retraces one they have already sent.
    ///
    /// Not a transport failure at all, which is why it carries the reason
    /// rather than a message: nothing was attempted, and the screen that asks
    /// for a share is the screen that has to explain. It lives here so that
    /// ``CommunityPublisher/share(_:authorName:transport:store:save:)`` can
    /// refuse for the same reason the form does, in the same way it re-checks
    /// the two-point floor the form's button already holds.
    case notEligible(CommunityPublishingEligibility.Reason)
    /// The hike has nothing worth publishing — no route.
    case nothingToShare
    /// The server refused a reviewer's action because this account is not in
    /// the `reviewer` role.
    ///
    /// Only reachable from the review screen, and only by somebody who had a
    /// queue to act on in the first place — so in practice it means the role
    /// was taken away between the list arriving and the tap, or that the
    /// account is in the role in one environment and not the other. See
    /// ``CommunityTransporting/pendingSubmissions()``, which turns the same
    /// refusal into an empty queue rather than an error, because there it is
    /// an answer and here it is a failure.
    case notPermitted
    /// No Apple Account on the device, or iCloud is switched off for it.
    ///
    /// Only ever raised by a *write*. Reading the public database needs no
    /// account at all, which is why browsing works on a signed-out phone and
    /// sharing does not.
    case notSignedIn
    /// Everything else, with the diagnostic kept for the log.
    case unavailable(String)
    /// The request could not reach iCloud. Retrying later is the answer.
    case unreachable

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            "Sharing a hike needs an Apple Account."
        case .unreachable:
            "Couldn't reach iCloud."
        case .notEligible(let reason):
            reason.title
        case .nothingToShare:
            "This hike has no route to share."
        case .notPermitted:
            "This account can't review submissions."
        case .noLongerAvailable:
            "This hike isn't available any more."
        case .unavailable:
            "Something went wrong."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .notSignedIn:
            "Sign in to iCloud in Settings, then try again. Browsing community hikes works without one."
        case .unreachable:
            "Check your connection and try again."
        case .notEligible(let reason):
            reason.explanation()
        case .nothingToShare:
            "Record or import a route first."
        case .notPermitted:
            "Its reviewer role may have been changed. Check the CloudKit Console for this environment."
        case .noLongerAvailable:
            "It may have been taken down. Pull the list again to refresh it."
        case .unavailable:
            "Try again in a moment."
        }
    }
}

/// What the community feature needs from a backend.
///
/// Submitting and publishing are different record types with different
/// permissions — see ``CommunitySchema`` — and this protocol now has a method
/// for each. It did not always: publishing lived only in the CloudKit Console,
/// on the reasoning that a build of this app should not be able to do it.
///
/// That reasoning was about the wrong layer, and the correction is worth
/// keeping written down because the old shape reads as the safer one. What
/// stops an ordinary hiker publishing is the `GRANT CREATE, WRITE TO reviewer`
/// on ``CommunitySchema/listingType``, which the server enforces against
/// whoever is calling. A modified client can call ``publish(_:)`` all day; it
/// gets a permission failure, exactly as it would have got one for the request
/// it could have hand-rolled anyway. Leaving the method out never protected
/// anything — it only meant the one person allowed to publish had to do it by
/// hand, with ``CommunitySchema/Listing/authorID`` copied across by eye and a
/// hike silently invisible when they got it wrong.
///
/// The reviewer-side methods are therefore *permission-gated, not
/// absent*, and each of them says which grant is doing the gating.
///
/// ## Why the two queries take an exclusion set
///
/// Because `limit` is a budget, and a budget spent on rows the hiker will
/// never be shown is a budget wasted. Blocked authors are filtered on the way
/// out of ``CommunityBrowser`` as well — a block made after results land has
/// to reach rows already on screen — but doing it *only* there would mean a
/// page of twenty-five hikes by one blocked author drew an empty list with an
/// eligible twenty-sixth sitting behind a cursor nobody follows. The
/// conformance is what owns the cursor, so it is the only place that can spend
/// another page; see ``CommunityPageBudget`` for how many it may spend.
///
/// A `Set<String>` of ``CommunityListing/authorID`` rather than the block list
/// itself: this protocol is `Sendable` and every requirement is `@concurrent`,
/// while ``CommunityBlockList`` is a main-actor `@Observable` reference. A
/// snapshot taken at the moment the request is made is also the right value —
/// a block made while one is in flight is applied by the read-time filter, not
/// by rewinding the query.
nonisolated protocol CommunityTransporting: Sendable {
    /// Uploads `draft` and returns the submission's record name.
    ///
    /// The returned name is what a hiker's own device remembers so the share
    /// button can say the hike has already been sent — it is not a claim that
    /// anybody else can see it, and nothing in the app should read it as one.
    ///
    /// **A submission is not submitted until it is in the queue.** A
    /// conformance writes the ``CommunitySchema/noticeType`` record too, and
    /// throws if it cannot: an upload no reviewer will ever be shown is worse
    /// than a failed one, because the hiker is told it was sent and the record
    /// cannot be found again afterwards — nothing enumerates submissions, by
    /// design. Returning a name is therefore a promise that somebody will look
    /// at it, and the share sheet's *Sent for review* is only true because of
    /// this paragraph.
    @concurrent
    func submit(_ draft: CommunitySubmissionDraft) async throws -> String

    /// The listing published from `submissionID`, or `nil` if there is not one.
    ///
    /// The only question this app can ask about its own submission, and it is
    /// deliberately the narrow one: *is there a listing pointing at this?*
    /// A `nil` is not "rejected" — it is "no listing exists yet", which covers
    /// a reviewer who has not looked and a reviewer who declined equally. See
    /// ``Hike/communityListingID``, which is careful about the same thing.
    ///
    /// It reads the listing type, not the submission type, and that is what
    /// makes it safe: a listing is `_world` read and already discoverable by
    /// location and title, so being able to reach one by the submission it
    /// names adds nothing an author could not already find by searching for
    /// their own hike. Asking the submission whether it had been approved
    /// would need a field on a record only the admin role may write, which is
    /// exactly the shape ``CommunitySchema`` exists to avoid.
    ///
    /// Needs ``CommunitySchema/Listing/submission`` QUERYABLE in the Console.
    @concurrent
    func publication(of submissionID: String) async throws -> CommunityListing?

    /// Published hikes whose start point is within `radiusMeters` of
    /// `coordinate`, nearest first.
    @concurrent
    func listings(
        near coordinate: CLLocationCoordinate2D,
        radiusMeters: Double,
        limit: Int,
        excluding: Set<String>
    ) async throws -> [CommunityListing]

    /// Published hikes whose title matches `query`, newest first.
    @concurrent
    func listings(
        matching query: String,
        limit: Int,
        excluding: Set<String>
    ) async throws -> [CommunityListing]

    /// The coarse shape of each listing's route, keyed by
    /// ``CommunityListing/id``, so the map can draw the answer it asked for.
    ///
    /// One request for the whole page rather than one per row, which is the
    /// only reason a browse can afford geometry at all: the outlines are a
    /// *field* on the submission and a field can be asked for by itself, so
    /// this is a fetch of record IDs asking for about a kilobyte each. See
    /// ``CommunityRouteOutline`` for what is in one and
    /// ``CommunitySchema/Submission/routeOutline`` for why it needs no index.
    ///
    /// **Partial by contract.** A listing is absent from the answer whenever
    /// its submission carries no outline — every hike published before the
    /// field existed, and any route too short to draw — and whenever that one
    /// record could not be read. Missing geometry is not a failure: the pin
    /// still stands and the hike still opens, so a caller draws what it got
    /// and says nothing about the rest. Only a failure of the whole request
    /// throws.
    ///
    /// Needs no account, like every other read here.
    @concurrent
    func outlines(
        for listings: [CommunityListing]
    ) async throws -> [String: [RouteCoordinate]]

    /// The route and photographs behind a listing, downloaded into
    /// `directory`.
    ///
    /// Needs no account, like every other read here: a hiker who never signs
    /// in can open a published hike as well as find one — see
    /// ``CommunityFailure/notSignedIn``.
    ///
    /// The caller owns `directory` and is what eventually deletes it: these
    /// are somebody else's photographs held only for as long as the screen
    /// showing them, unless the hiker imports the hike and makes copies of
    /// their own.
    @concurrent
    func detail(
        for listing: CommunityListing,
        downloadingInto directory: URL
    ) async throws -> CommunityHikeDetail

    // MARK: - Reviewing

    /// Submissions nobody has published or declined yet, oldest first.
    ///
    /// **Throws ``CommunityFailure/notPermitted`` for everybody who is not a
    /// reviewer, and that is the whole access control.** The queue is
    /// ``CommunitySchema/noticeType``, which grants read to the `reviewer`
    /// role and to nobody else, so this asks the server a question it answers
    /// differently depending on who is asking.
    ///
    /// The refusal is reported rather than flattened into an empty list,
    /// because *a reviewer with an empty queue* and *not a reviewer* are
    /// different facts and the second one is needed elsewhere: it is the only
    /// thing that can decide whether to offer a takedown on a hike that is
    /// already published, which has no queue row to hang off.
    /// ``CommunityReviewQueue`` is what keeps that quiet for the hikers it
    /// means nothing to.
    ///
    /// Nothing about being a reviewer is stored on the device, asked before
    /// the call, or cached after it. There is no flag to set, so there is no
    /// flag to forge: a build with this method wired to a button still gets
    /// nothing back unless the account behind it is in the role.
    ///
    /// Each entry is a notice plus the submission it points at, read with
    /// `desiredKeys` so a queue of twenty does not download twenty routes. A
    /// notice whose submission is missing is left out — an upload that failed
    /// after its notice was written, or a submission already deleted — since
    /// there is nothing to review.
    @concurrent
    func pendingSubmissions() async throws -> [CommunityPendingSubmission]

    /// The route and photographs behind a pending submission, downloaded into
    /// `directory`, so a reviewer can look at what they are deciding about.
    ///
    /// The same fetch ``detail(for:downloadingInto:)`` makes, reaching the
    /// same record by the same means — a fetch by record name, never a query.
    /// The ``CommunityHikeDetail/listing`` it comes back with is
    /// ``CommunityPendingSubmission/prospectiveListing``, which is not a
    /// listing that exists; see that property for what it is for.
    ///
    /// Needs no special permission. A submission is `_world` read, so this
    /// would work for anybody holding the record name — the queue is what a
    /// reviewer has and other people do not.
    @concurrent
    func detail(
        ofPending pending: CommunityPendingSubmission,
        downloadingInto directory: URL
    ) async throws -> CommunityHikeDetail

    /// Publishes `pending`, making it visible to everybody, and takes it out
    /// of the queue.
    ///
    /// Writes the fields carried on `pending` and reads nothing back off the
    /// submission first — see ``CommunityPendingSubmission`` for why what was
    /// reviewed has to be what is published.
    ///
    /// Gated by `GRANT CREATE, WRITE TO reviewer` on
    /// ``CommunitySchema/listingType``. A caller outside the role gets
    /// ``CommunityFailure/notPermitted``.
    ///
    /// The listing is saved before the notice is deleted. A failure between
    /// the two leaves a published hike still sitting in the queue, which
    /// a reviewer sees and can resolve; the other order would lose the hike
    /// out of both places at once.
    @concurrent
    func publish(_ pending: CommunityPendingSubmission) async throws -> CommunityListing

    /// Deletes `pending`'s submission and its notice, publishing nothing.
    ///
    /// A decline leaves no record anywhere, which is what the published
    /// privacy policy and terms already say happens: the author's app cannot
    /// tell a decline from a reviewer who has not looked yet, and after this
    /// there is nothing left for it to tell them apart with. The route and the
    /// photographs go with the submission record.
    ///
    /// That deletion is the point rather than tidiness. Nothing enumerates
    /// submissions, so a declined one left behind can never be found again by
    /// anybody — it would be a stranger's photographs and GPS trace held in a
    /// public database for good, with no way to reach them. Declining is the
    /// only moment the record name is in a reviewer's hands.
    ///
    /// Gated by `GRANT WRITE TO reviewer` on
    /// ``CommunitySchema/submissionType`` — the one write permission that type
    /// grants outside its own creation.
    @concurrent
    func decline(_ pending: CommunityPendingSubmission) async throws

    /// Unlists a published hike and deletes the submission behind it.
    ///
    /// What a takedown request turns into. `docs/terms/` and `docs/privacy/`
    /// both promise a hike can be removed on request, and
    /// ``CommunityWithdrawal`` composes the mail that asks for it, carrying
    /// both record names precisely because deleting needs them.
    ///
    /// Both records, and in that order: the listing first, so a failure
    /// partway leaves a hike nobody can find rather than a listing pointing at
    /// a submission that is gone. A reader might expect the submission to be
    /// kept as evidence — it is not, for the reason ``decline(_:)`` gives.
    @concurrent
    func takeDown(_ listing: CommunityListing) async throws
}
