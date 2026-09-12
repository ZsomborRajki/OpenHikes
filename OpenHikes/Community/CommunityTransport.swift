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
/// Deliberately short. Each case is a different thing to *say* to the walker,
/// not a different thing that went wrong underneath — CloudKit distinguishes
/// dozens of conditions and almost none of them is a sentence anyone can act
/// on. Anything without its own case is ``unavailable``, which is logged with
/// the real diagnostic and shown as the one honest generality.
nonisolated enum CommunityFailure: LocalizedError, Equatable, Sendable {
    /// A published hike could not be found any more. A listing the walker is
    /// looking at can outlive the submission behind it: a reviewer can take
    /// one down, and the walker's own copy of the list is a snapshot.
    case noLongerAvailable
    /// The hike has nothing worth publishing — no route.
    case nothingToShare
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
            "Sign in to iCloud in Settings, then try again. Browsing shared hikes works without one."
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
nonisolated protocol CommunityTransporting: Sendable {
    /// Uploads `draft` and returns the submission's record name.
    ///
    /// The returned name is what a walker's own device remembers so the share
    /// button can say the hike has already been sent — it is not a claim that
    /// anybody else can see it, and nothing in the app should read it as one.
    @concurrent
    func submit(_ draft: CommunitySubmissionDraft) async throws -> String

    /// Published hikes whose start point is within `radiusMeters` of
    /// `coordinate`, nearest first.
    @concurrent
    func listings(
        near coordinate: CLLocationCoordinate2D,
        radiusMeters: Double,
        limit: Int
    ) async throws -> [CommunityListing]

    /// Published hikes whose title matches `query`, newest first.
    @concurrent
    func listings(matching query: String, limit: Int) async throws -> [CommunityListing]

    /// The route and photographs behind a listing, downloaded into
    /// `directory`.
    ///
    /// Needs no account, like every other read here: a walker who never signs
    /// in can open a published hike as well as find one — see
    /// ``CommunityFailure/notSignedIn``.
    ///
    /// The caller owns `directory` and is what eventually deletes it: these
    /// are somebody else's photographs held only for as long as the screen
    /// showing them, unless the walker imports the hike and makes copies of
    /// their own.
    @concurrent
    func detail(
        for listing: CommunityListing,
        downloadingInto directory: URL
    ) async throws -> CommunityHikeDetail
}
