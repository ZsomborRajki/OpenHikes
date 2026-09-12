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
    /// The hike has nothing worth publishing — no route.
    case nothingToShare
    /// No Apple Account on the device, or iCloud is switched off for it.
    ///
    /// Only ever raised by a *write*. Reading the public database needs no
    /// account at all, which is why browsing works on a signed-out phone and
    /// sharing does not.
    case notSignedIn
    /// The Pro subscription is not current on this device.
    ///
    /// Raised by ``CommunityPublisher/share(_:authorName:entitlement:transport:store:save:)``
    /// and by nothing else, because publishing is the only paid thing the
    /// community feature does: browsing, opening and saving somebody else's
    /// hike are free and stay free, which is what keeps the list worth reading
    /// for everybody. Ordinarily unreachable from the UI — the share button
    /// opens the paywall instead of the form — so what raises it in practice
    /// is a subscription that lapsed while the form was open.
    case requiresSubscription
    /// Everything else, with the diagnostic kept for the log.
    case unavailable(String)
    /// The request could not reach iCloud. Retrying later is the answer.
    case unreachable

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            "Sharing a hike needs an Apple Account."
        case .requiresSubscription:
            "Sharing a hike needs OpenHikes Pro."
        case .unreachable:
            "Couldn't reach iCloud."
        case .nothingToShare:
            "This hike has no route to share."
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
        case .requiresSubscription:
            "Subscribe in Settings, then try again. Browsing and saving other people's hikes stays free."
        case .unreachable:
            "Check your connection and try again."
        case .nothingToShare:
            "Record or import a route first."
        case .noLongerAvailable:
            "It may have been taken down. Pull the list again to refresh it."
        case .unavailable:
            "Try again in a moment."
        }
    }
}

/// What the community feature needs from a backend.
///
/// Note what is absent: there is no way to publish. Submitting and publishing
/// are different record types with different permissions precisely so that no
/// build of this app can do the second one — see ``CommunitySchema``.
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
}
