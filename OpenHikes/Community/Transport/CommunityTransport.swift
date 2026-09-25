//
//  CommunityTransport.swift
//  OpenHikes
//
//  The seam between the community feature and CloudKit, and the handful of
//  sentences a failure is allowed to say.
//
//  A protocol for the same reason ``TrailGraphProviding``, the tile
//  downloader's injected fetch and the injectable containers elsewhere are — see
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
import OpenHikesData

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
    /// The contribution has nothing worth publishing — no photograph this
    /// device can actually send.
    ///
    /// Its own case rather than ``nothingToShare`` with different wording,
    /// because the two are different facts with different answers. A hike with
    /// no route is a recording that went wrong; a hike with no photograph is
    /// the ordinary state of a trail somebody saved and has not yet walked
    /// with a camera. It also covers the case only this app has — every
    /// picture being a row whose file lives on the device it was added on, so
    /// a full strip on the iPad can send nothing. See *Photo pixels stay on
    /// the device the photo was added on* in the repository instructions.
    case noPhotosToShare
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
    /// ``CommunityTransporting/reviewQueue()``, which turns the same refusal
    /// into an empty queue rather than an error, because there it is an answer
    /// and here it is a failure.
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
        case .noPhotosToShare:
            "There are no photos to add."
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
        case .noPhotosToShare:
            """
            Add photos to this hike first, or check that they aren't on the device \
            they were taken on — a photo's file stays where it was added.
            """
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

nonisolated extension CommunityFailure {
    /// `error` as something a screen can say: itself when it is already a
    /// community failure, which everything a transport throws is, and
    /// ``unavailable(_:)`` carrying its own description when it is not — a
    /// file error while staging photographs, say.
    ///
    /// The one spelling of a conversion nine call sites made for themselves.
    init(_ error: any Error) {
        self = error as? CommunityFailure ?? .unavailable(error.localizedDescription)
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
    /// `coordinate`, nearest first, and — when `scope` asks for them — the
    /// curated OpenStreetMap routes beside them.
    ///
    /// The only requirement here that takes a scope, because it is the only
    /// one with a second source behind it. A conformance with one source
    /// ignores it and says so; see ``MergedCommunityTransport``, which is
    /// where it decides anything, and ``CommunityNearbyScope`` for why the
    /// question carries it rather than the transport.
    ///
    /// It answers a ``CommunityNearbyAnswer`` rather than an array for the
    /// same reason: a curated half that could not be reached is reported
    /// beside the rows instead of thrown, so a busy Overpass costs the trails
    /// and nothing else.
    @concurrent
    func listings(
        near coordinate: CLLocationCoordinate2D,
        radiusMeters: Double,
        limit: Int,
        excluding: Set<String>,
        scope: CommunityNearbyScope
    ) async throws -> CommunityNearbyAnswer

    /// The same question, with the published hikes handed to `publishedFirst`
    /// as soon as they land when a slower source is still being asked.
    ///
    /// CloudKit answers in well under a second; an Overpass listing pass and
    /// the geometry pass after it can take ten. Holding the hiker's own
    /// published hikes back for the whole of that is waiting on the half they
    /// are least likely to be looking for, so the rows go up the moment they
    /// exist and the trails join them when they arrive. The returned answer is
    /// still the whole one — the early rows included — and it is the only
    /// thing that ends the request, which is what keeps *Search this area*
    /// spinning until OpenStreetMap has had its say.
    ///
    /// **Called at most once, and never with nothing.** An empty published
    /// half is not handed over: replacing the last area's rows with an empty
    /// list mid-search would draw *No community hikes here* over an area whose
    /// trails are still on their way. Nor is it called when there is no
    /// slower half to wait for — a ``CommunityNearbyScope/publishedOnly``
    /// question, or a conformance with one source, whose answer *is* the
    /// published half. That second case is the default below, so only
    /// ``MergedCommunityTransport`` has anything to say here.
    ///
    /// A published half that arrived is never followed by a thrown answer
    /// other than a cancellation: the merge throws only when CloudKit failed.
    @concurrent
    func listings(
        near coordinate: CLLocationCoordinate2D,
        radiusMeters: Double,
        limit: Int,
        excluding: Set<String>,
        scope: CommunityNearbyScope,
        publishedFirst: @Sendable ([CommunityListing]) async -> Void
    ) async throws -> CommunityNearbyAnswer

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

    /// Everything nobody has published or declined yet, oldest first —
    /// hikes and contributed photographs both, from the one query.
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
    ///
    /// The two kinds arrive together and are separated on the way out; see
    /// ``CommunityReviewBatch`` for why that is one request and two arrays.
    /// A notice pointing at neither kind is dropped for the reason one
    /// pointing at a missing record is: there is nothing behind it to judge.
    @concurrent
    func reviewQueue() async throws -> CommunityReviewBatch

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

    /// Rewrites `pending`'s submission so it carries only `kept`, deleting
    /// every other photograph on it.
    ///
    /// What *remove this one* has to mean for a moderation control, and the
    /// reason it costs an upload. A listing carries only
    /// ``CommunitySchema/Listing/photoCount``; the pictures themselves live on
    /// the submission, which a published listing names through a QUERYABLE
    /// reference. So a photograph merely hidden from the listing is still
    /// fetchable by anybody who reads the hike it belongs to — which is not a
    /// photograph that has been removed. It has to come off the record.
    ///
    /// CloudKit has no way to drop one element of an asset field, so the kept
    /// photographs are sent again, from the copies the review screen already
    /// downloaded. That is the whole of the expense and it is bounded:
    /// ``CommunityPublisher/maximumPhotos`` of them, re-encoded before they
    /// were ever uploaded.
    ///
    /// **Call this before ``publish(_:)``, never after.** Until a listing
    /// exists nothing can reach the submission but the reviewer holding its
    /// record name, so an edit here is invisible and a failure costs nothing
    /// but the decision. The other order would edit a record the browse path
    /// is already serving.
    ///
    /// A conformance writes the two photo fields and leaves every other one
    /// alone. The route, the outline, the title and the description are not a
    /// reviewer's to change, and a save that rewrote the whole record would
    /// have to carry them — see ``CommunitySchema``, whose case for a
    /// write-once submission this method is the single documented exception
    /// to.
    ///
    /// Gated by `GRANT WRITE TO reviewer` on
    /// ``CommunitySchema/submissionType`` — the same grant declining needs,
    /// and the same one a caller outside the role is refused by.
    ///
    /// - Parameters:
    ///   - kept: The photographs to keep, in the order they should end up in.
    ///     Empty takes both fields off the record.
    ///   - staging: A directory the caller owns and deletes, for the rewritten
    ///     pins file. The same rule ``submit(_:)`` follows: a `CKAsset` is a
    ///     file, and a failed edit must not leave one behind.
    @concurrent
    func keepOnlyPhotos(
        _ kept: [CommunityKeptPhoto],
        of pending: CommunityPendingSubmission,
        staging: URL
    ) async throws

    /// Publishes `pending`, making it visible to everybody, and takes it out
    /// of the queue.
    ///
    /// Writes the fields carried on `pending` and reads nothing back off the
    /// submission first — see ``CommunityPendingSubmission`` for why what was
    /// reviewed has to be what is published, and why a reviewer's own
    /// corrections reach the listing by being written onto `pending` rather
    /// than applied here.
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

    // MARK: - Photographs offered to a hike that already exists

    /// Uploads `draft` and returns the photo submission's record name.
    ///
    /// Everything ``submit(_:)``'s documentation says holds here: the name is
    /// what the hiker's own device remembers so the button can say the
    /// pictures have already gone, it is not a claim that anybody else can see
    /// them, and **a contribution is not submitted until it is in the queue**
    /// — a conformance writes the notice too and throws if it cannot, because
    /// an upload no reviewer will be shown is worse than a failed one.
    ///
    /// Needs an Apple Account, like every write here and unlike every read.
    @concurrent
    func submitPhotos(_ draft: CommunityPhotoDraft) async throws -> String

    /// The record name of the contribution published from `photoSubmissionID`,
    /// or `nil` if there is not one.
    ///
    /// ``publication(of:)``'s opposite number, and narrow for the same reason:
    /// *is there a published record pointing at this?* A `nil` is not
    /// "declined" — it covers a reviewer who has not looked and one who said
    /// no, which leave the same absence.
    ///
    /// A `String` rather than a value, because a record name is the whole of
    /// what the caller does anything with — see
    /// ``CommunityContributionCheck``. Needs
    /// ``CommunitySchema/Contribution/photoSubmission`` QUERYABLE, which is
    /// the predicate this runs and the second of that type's two indexes —
    /// not the record-name index the Console adds by default, which is about
    /// a different field. Without it every contributed set reads as *waiting
    /// for review* for good; see ``CommunitySchema``.
    @concurrent
    func contribution(of photoSubmissionID: String) async throws -> String?

    /// Every published set of photographs somebody has put on the hike
    /// `listingID` names, downloaded into `directory`, oldest set first.
    ///
    /// Asked on **open** and never for a list, which is the rule
    /// ``HikeTrailAnalysis`` and ``CuratedElevationSourcing`` already follow on
    /// that screen and the reason a hike's row says nothing about contributed
    /// pictures: a page offers twenty-five trails and a hiker opens one.
    ///
    /// Its own request rather than part of ``detail(for:downloadingInto:)``,
    /// and three things follow from that which are each worth having. The
    /// route and the author's photographs are not held up behind a second
    /// query. The blocked set reaches the *download* rather than only the
    /// draw, which is where it has to reach for a block to mean anything about
    /// a stranger's pictures. And the two sources need no routing at all: a
    /// curated hike's contributions come from CloudKit exactly as a published
    /// one's do, because the target is an identity rather than a reference.
    ///
    /// `listingID` is a ``CommunityIdentity`` — a published listing's record
    /// name, or a curated route's `osm:r/<relation>`. Both are asked of
    /// CloudKit, and that is the whole point: an OpenStreetMap trail has no
    /// record in this database and can still have photographs on it.
    ///
    /// - Parameter excluding: Blocked authors, by
    ///   ``CommunitySchema/Contribution/authorID``. Applied here as well as on
    ///   the way out for the reason the two list queries take one: a set from
    ///   a blocked contributor must not be downloaded, because downloading it
    ///   is the cost. It cannot go into the predicate — that field carries no
    ///   index, deliberately — so a conformance that pages owes the same debt
    ///   the browse queries do: a page spent entirely on blocked sets must buy
    ///   another. See ``CommunityPageBudget``.
    ///
    /// Needs no account, like every other read here. The caller owns
    /// `directory` and is what eventually deletes it.
    @concurrent
    func contributedPhotos(
        for listingID: String,
        excluding: Set<String>,
        downloadingInto directory: URL
    ) async throws -> [CommunityPhotoContribution]

    /// The photographs behind a pending contribution, downloaded into
    /// `directory`, so a reviewer can look at what they are deciding about.
    ///
    /// A fetch by record name, never a query — the same read
    /// ``detail(ofPending:downloadingInto:)`` makes, and needing the same
    /// nothing in the way of permission: a photo submission is `_world` read,
    /// so this would work for anybody holding the record name. The queue is
    /// what a reviewer has and other people do not.
    @concurrent
    func photos(
        ofPending pending: CommunityPendingPhotos,
        downloadingInto directory: URL
    ) async throws -> CommunityPhotoContribution

    /// Rewrites `pending`'s submission so it carries only `kept`, deleting
    /// every other photograph on it.
    ///
    /// ``keepOnlyPhotos(_:of:staging:)`` for the other record type, and every
    /// word of that method's documentation applies: CloudKit cannot drop one
    /// element of an asset field, so the kept photographs go back up from the
    /// copies the review screen downloaded; the two photo fields are rewritten
    /// together because they describe each other by index; and it must be
    /// called **before** ``publishPhotos(_:)``, never after, because until a
    /// contribution record exists nothing can reach the submission but the
    /// reviewer holding its name.
    ///
    /// It is a sharper instrument here than there. On a hike, leaving every
    /// photograph out still publishes the walk; on a contribution the
    /// photographs *are* the submission, so a reviewer who strikes them all
    /// off is declining — and the screen says so rather than offering an
    /// empty publish.
    ///
    /// Gated by `GRANT WRITE TO reviewer` on
    /// ``CommunitySchema/photoSubmissionType``.
    @concurrent
    func keepOnlyPhotos(
        _ kept: [CommunityKeptPhoto],
        ofPending pending: CommunityPendingPhotos,
        staging: URL
    ) async throws

    /// Publishes `pending`, putting its photographs on the hike it names, and
    /// takes it out of the queue.
    ///
    /// Writes the fields carried on `pending` and reads nothing back off the
    /// submission first, for the reason ``publish(_:)`` does not: what the
    /// reviewer saw has to be what gets published.
    ///
    /// It deliberately does **not** touch the listing it is about, even though
    /// the role could write one: ``CommunitySchema/Listing/photoCount`` goes
    /// on meaning the photographs the hike's own author published. See *The
    /// other pair* in ``CommunitySchema`` for what that costs and why it is
    /// still the right side to be wrong on.
    ///
    /// Gated by `GRANT CREATE, WRITE TO reviewer` on
    /// ``CommunitySchema/contributionType``.
    @concurrent
    func publishPhotos(_ pending: CommunityPendingPhotos) async throws -> CommunityPhotoContribution

    /// Deletes `pending`'s submission and its notice, publishing nothing.
    ///
    /// The photographs go with the record, for the reason ``decline(_:)``
    /// deletes rather than keeps: nothing enumerates this type, so a declined
    /// submission left behind would be a stranger's photographs held in a
    /// public database for good with no way to reach them.
    @concurrent
    func declinePhotos(_ pending: CommunityPendingPhotos) async throws

    /// Unlists a published set of photographs and deletes the submission
    /// behind it.
    ///
    /// Both records, and in that order, for the reason ``takeDown(_:)`` does
    /// it in that order: a failure partway leaves photographs nobody can find
    /// rather than a published record pointing at a submission that is gone.
    ///
    /// The hike it was on is untouched. A contribution is a record of its own
    /// with an author of its own, which is what makes taking one down a thing
    /// that can be done at all — and the reason the hike's own photographs are
    /// never at risk from it.
    @concurrent
    func takeDownPhotos(_ contribution: CommunityPhotoContribution) async throws
}

// `nonisolated` for the reason ``MergedCommunityTransport``'s extensions spell
// it: under default main-actor isolation an unannotated extension is a
// main-actor context.
nonisolated extension CommunityTransporting {
    /// One source, so nothing arrives before the answer does. See the
    /// requirement.
    @concurrent
    func listings(
        near coordinate: CLLocationCoordinate2D,
        radiusMeters: Double,
        limit: Int,
        excluding: Set<String>,
        scope: CommunityNearbyScope,
        publishedFirst _: @Sendable ([CommunityListing]) async -> Void
    ) async throws -> CommunityNearbyAnswer {
        try await listings(
            near: coordinate,
            radiusMeters: radiusMeters,
            limit: limit,
            excluding: excluding,
            scope: scope
        )
    }
}
