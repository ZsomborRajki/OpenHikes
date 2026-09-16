//
//  StubCommunityTransport.swift
//  OpenHikesTests
//
//  What the community suites talk to instead of CloudKit.
//
//  The seam exists for the reason every other injected transport in this
//  repository does — see *Deliberate test seams* in the instructions — and
//  more sharply here than most: the real transport writes to a **public**
//  database. There is no sandbox for one. A suite that reached it would put a
//  record in front of every other user of this app, from a machine running
//  tests, and could not take it back.
//
//  It records what it was handed as well as answering, because half of what
//  these suites assert is about the request rather than the response: which
//  photographs went, whether the pins still line up with them, and how many
//  requests a gesture produced.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Synchronization

/// A transport that answers from a script and remembers what it was asked.
///
/// `final class` behind a `Mutex` rather than an actor: the protocol is
/// `Sendable` and its requirements are `@concurrent`, so calls genuinely
/// arrive off the main actor, and an actor would make every recording read in
/// a test `await` — which turns an assertion into a suspension point and lets
/// the next request overtake it.
final class StubCommunityTransport: CommunityTransporting, @unchecked Sendable {
    struct Recording: Sendable {
        var submissions: [CommunitySubmissionDraft] = []
        var nearbyRequests: [(coordinate: CLLocationCoordinate2D, radiusMeters: Double)] = []
        var titleQueries: [String] = []
        var detailRequests: [String] = []
        /// The submission ids a publication check asked about, in order. What
        /// proves the check is asked once and not once per body.
        var publicationChecks: [String] = []
        /// The exclusion set each listing request carried, in order. What
        /// proves the browser spends its budget on rows the hiker can see —
        /// see `CommunityTransporting`'s note on why the set is a parameter.
        var exclusions: [Set<String>] = []
        /// The scope each nearby request carried, in order. What proves the
        /// *Search this area* tap is the only one that reaches Overpass — see
        /// `CommunityNearbyScope`, and note that a wrong answer here is
        /// invisible in a return value, since the rows are the same either
        /// way.
        var nearbyScopes: [CommunityNearbyScope] = []
        /// The listings each outline request covered, in order. What proves
        /// the map's lines cost one request per answer rather than one per
        /// row.
        var outlineRequests: [[String]] = []
        /// How many times the review queue was asked for. What proves an
        /// ordinary browse does not ask, and that a reviewer's does not ask
        /// twice for one appearance.
        var queueRequests = 0
        /// The submissions a preview was opened for, in order.
        var pendingDetailRequests: [String] = []
        /// What was published, in order. Held whole rather than by id: what
        /// these suites assert is that the *values the reviewer saw* are the
        /// ones that went, ``CommunityPendingSubmission/photoCount`` included.
        var published: [CommunityPendingSubmission] = []
        /// What was declined, in order.
        var declined: [CommunityPendingSubmission] = []
        /// The listings taken down, in order.
        var takenDown: [String] = []
        /// Each photo edit a reviewer made, in order: the submission it was
        /// about and the photographs they kept. What proves the removal
        /// reaches the record rather than only the screen, and that it
        /// happens before the listing exists.
        var photoEdits: [(submissionID: String, kept: [CommunityKeptPhoto])] = []
        /// The contributions uploaded, in order. Held whole for the reason
        /// ``submissions`` is: what these suites assert is what the draft
        /// carried, pins and all.
        var photoDrafts: [CommunityPhotoDraft] = []
        /// The photo submissions a publication check asked about, in order.
        var contributionChecks: [String] = []
        /// The listings a hike's contributed photographs were asked for, with
        /// the exclusion set each request carried. What proves a blocked
        /// contributor's pictures are never downloaded rather than merely not
        /// drawn.
        var contributionRequests: [(listingID: String, excluding: Set<String>)] = []
        /// Contributed sets published, declined and taken down, in order.
        var publishedPhotos: [CommunityPendingPhotos] = []
        var declinedPhotos: [CommunityPendingPhotos] = []
        var takenDownPhotos: [String] = []
        /// Each photo edit a reviewer made to a *contribution*, in order.
        var contributionPhotoEdits: [(submissionID: String, kept: [CommunityKeptPhoto])] = []
    }

    /// What each call should do. Set before the call, read inside it.
    var submissionResult: Result<String, CommunityFailure> = .success("submission-1")
    var listingsResult: Result<[CommunityListing], CommunityFailure> = .success([])
    /// What the curated half of a nearby answer reports, for a suite driving
    /// the rate-limit notice. Only ever returned to a
    /// ``CommunityNearbyScope/withCuratedTrails`` question, since that is the
    /// only kind that can be refused by OpenStreetMap.
    var curatedOutage: CuratedTrailOutage?
    var detailResult: Result<CommunityHikeDetail, CommunityFailure>?
    /// What a publication check answers. `nil` — the default — is "no listing
    /// for this submission yet", which is the state a hike spends its whole
    /// time in until a reviewer publishes it.
    var publicationResult: Result<CommunityListing?, CommunityFailure> = .success(nil)
    /// What the map's lines come back as, keyed by listing. Empty by default,
    /// which is the honest state of a database whose hikes were all published
    /// before outlines existed.
    var outlinesResult: Result<[String: [RouteCoordinate]], CommunityFailure> = .success([:])
    /// What the review queue answers. Empty — the default — is what the server
    /// tells everybody who is not a reviewer, so a suite that sets nothing is
    /// testing the ordinary hiker's app.
    var pendingResult: Result<CommunityReviewBatch, CommunityFailure> = .success(
        CommunityReviewBatch()
    )
    /// What a hike's contributed photographs come back as. Empty by default,
    /// which is the honest state of a trail nobody has added to — and what
    /// every suite written before this existed is still asserting against.
    var contributedPhotosResult: Result<[CommunityPhotoContribution], CommunityFailure> =
        .success([])
    /// What a contributed set's own fetch answers, for the review screen.
    var pendingPhotosResult: Result<CommunityPhotoContribution, CommunityFailure>?
    /// Whether a photo submission has been published, by record name. `nil` —
    /// the default — is the state a contribution spends its whole time in
    /// until a reviewer says yes.
    var contributionResult: Result<String?, CommunityFailure> = .success(nil)
    var publishPhotosResult: Result<CommunityPhotoContribution, CommunityFailure>?
    /// The detail a pending preview loads. Falls back to ``detailResult`` when
    /// unset, since most suites want one answer for both paths.
    var pendingDetailResult: Result<CommunityHikeDetail, CommunityFailure>?
    /// What publishing answers. The default succeeds with a listing built from
    /// whatever was handed in, which is what the real transport does.
    var publishResult: Result<CommunityListing, CommunityFailure>?
    var declineResult: Result<Void, CommunityFailure> = .success(())
    /// What editing a submission's photographs answers.
    var keepPhotosResult: Result<Void, CommunityFailure> = .success(())
    var takeDownResult: Result<Void, CommunityFailure> = .success(())
    /// Held open so a suite can watch two requests overlap — see
    /// `CommunityBrowserTests`.
    var beforeListingsReturn: (@Sendable () async -> Void)?
    /// The same for a submission, and handed the draft: the staging directory
    /// exists only while the upload is in flight, so a suite that wants to see
    /// what an upload puts on disk has to look from in here.
    var beforeSubmissionReturns: (@Sendable (CommunitySubmissionDraft) async -> Void)?
    /// The same for a contribution, for the same reason.
    var beforePhotoSubmissionReturns: (@Sendable (CommunityPhotoDraft) async -> Void)?
    /// The same, for the check that asks whether contributed photographs have
    /// been published. Held so a suite can send a second set while the first
    /// question is still waiting — the window in which an answer about a
    /// replaced submission would be written back.
    var beforeContributionReturns: (@Sendable () async -> Void)?
    /// The same, for the outline request — which lands *after* the rows it
    /// belongs to and so is the one a suite has to be able to hold.
    var beforeOutlinesReturn: (@Sendable () async -> Void)?
    /// The same, for the detail. Held so a suite can cancel the load while a
    /// stranger's photographs are still being copied — the window in which the
    /// production transport has already made its last cancellation check and
    /// will return a detail rather than throw.
    var beforeDetailReturns: (@Sendable () async -> Void)?
    /// The same, for a publication check. Held so a suite can re-share the
    /// hike while the check is waiting, which is the window the check has to
    /// notice it is no longer answering about the submission it asked after.
    var beforePublicationReturns: (@Sendable () async -> Void)?
    /// The same, for the review queue. Held so a suite can watch the section
    /// appear and disappear around a request in flight.
    var beforeQueueReturns: (@Sendable () async -> Void)?

    private let state = Mutex(Recording())

    var recording: Recording { state.withLock { $0 } }

    @concurrent
    func submit(_ draft: CommunitySubmissionDraft) async throws -> String {
        state.withLock { $0.submissions.append(draft) }
        await beforeSubmissionReturns?(draft)
        return try submissionResult.get()
    }

    @concurrent
    func publication(of submissionID: String) async throws -> CommunityListing? {
        state.withLock { $0.publicationChecks.append(submissionID) }
        await beforePublicationReturns?()
        return try publicationResult.get()
    }

    @concurrent
    func listings(
        near coordinate: CLLocationCoordinate2D,
        radiusMeters: Double,
        limit: Int,
        excluding: Set<String>,
        scope: CommunityNearbyScope
    ) async throws -> CommunityNearbyAnswer {
        state.withLock { recording in
            recording.nearbyRequests.append((coordinate: coordinate, radiusMeters: radiusMeters))
            recording.exclusions.append(excluding)
            recording.nearbyScopes.append(scope)
        }
        await beforeListingsReturn?()
        return CommunityNearbyAnswer(
            listings: try answer(excluding: excluding),
            // Whatever the case asked for, and reported only to a question
            // that asked about OpenStreetMap — which is what the real
            // ``MergedCommunityTransport`` does, and the rule
            // ``CommunityBrowser`` is held to.
            curatedOutage: scope == .withCuratedTrails ? curatedOutage : nil
        )
    }

    @concurrent
    func listings(
        matching query: String,
        limit: Int,
        excluding: Set<String>
    ) async throws -> [CommunityListing] {
        state.withLock { recording in
            recording.titleQueries.append(query)
            recording.exclusions.append(excluding)
        }
        await beforeListingsReturn?()
        return try answer(excluding: excluding)
    }

    /// Honours the exclusion set rather than merely recording it, because the
    /// real transport does — it is what `limit` is spent on, not a courtesy —
    /// and a suite asserting on a list the stub had not filtered would be
    /// asserting about a transport nobody ships.
    private func answer(excluding: Set<String>) throws -> [CommunityListing] {
        let listings = try listingsResult.get()
        guard !excluding.isEmpty else { return listings }
        return listings.filter { listing in
            listing.blockableAuthorID.map { !excluding.contains($0) } ?? true
        }
    }

    /// Answers from ``outlinesResult`` and records which page was asked
    /// about.
    ///
    /// The real transport answers partially — a listing whose submission has
    /// no outline is simply absent — so the script is a dictionary rather than
    /// a per-listing result, and a suite proves the partial case by leaving
    /// one out.
    @concurrent
    func outlines(
        for listings: [CommunityListing]
    ) async throws -> [String: [RouteCoordinate]] {
        state.withLock { $0.outlineRequests.append(listings.map(\.id)) }
        await beforeOutlinesReturn?()
        return try outlinesResult.get()
    }

    @concurrent
    func detail(
        for listing: CommunityListing,
        downloadingInto directory: URL
    ) async throws -> CommunityHikeDetail {
        state.withLock { $0.detailRequests.append(listing.id) }
        await beforeDetailReturns?()
        guard let detailResult else { throw CommunityFailure.noLongerAvailable }
        return try detailResult.get()
    }

    // MARK: - Reviewing

    @concurrent
    func reviewQueue() async throws -> CommunityReviewBatch {
        state.withLock { $0.queueRequests += 1 }
        await beforeQueueReturns?()
        return try pendingResult.get()
    }

    @concurrent
    func detail(
        ofPending pending: CommunityPendingSubmission,
        downloadingInto directory: URL
    ) async throws -> CommunityHikeDetail {
        state.withLock { $0.pendingDetailRequests.append(pending.submissionID) }
        await beforeDetailReturns?()
        guard let result = pendingDetailResult ?? detailResult else {
            throw CommunityFailure.noLongerAvailable
        }
        return try result.get()
    }

    @concurrent
    func keepOnlyPhotos(
        _ kept: [CommunityKeptPhoto],
        of pending: CommunityPendingSubmission,
        staging: URL
    ) async throws {
        state.withLock { $0.photoEdits.append((pending.submissionID, kept)) }
        try keepPhotosResult.get()
    }

    @concurrent
    func publish(_ pending: CommunityPendingSubmission) async throws -> CommunityListing {
        state.withLock { $0.published.append(pending) }
        if let publishResult { return try publishResult.get() }
        // The real transport reads its answer back off the record it wrote, so
        // the default answer here is built from what went in rather than from
        // a fixture: a suite that does not care what the listing looks like
        // still gets one that agrees with the submission it came from.
        return CommunityListing(
            id: "listing-for-\(pending.submissionID)",
            submissionID: pending.submissionID,
            title: pending.title,
            authorName: pending.authorName,
            authorID: pending.authorID,
            hikeDate: pending.hikeDate,
            distanceMeters: pending.distanceMeters,
            photoCount: pending.photoCount,
            latitude: pending.latitude,
            longitude: pending.longitude,
            publishedAt: pending.noticedAt
        )
    }

    @concurrent
    func decline(_ pending: CommunityPendingSubmission) async throws {
        state.withLock { $0.declined.append(pending) }
        try declineResult.get()
    }

    @concurrent
    func takeDown(_ listing: CommunityListing) async throws {
        state.withLock { $0.takenDown.append(listing.id) }
        try takeDownResult.get()
    }

    // MARK: - Contributed photographs

    @concurrent
    func submitPhotos(_ draft: CommunityPhotoDraft) async throws -> String {
        state.withLock { $0.photoDrafts.append(draft) }
        await beforePhotoSubmissionReturns?(draft)
        return try submissionResult.get()
    }

    @concurrent
    func contribution(of photoSubmissionID: String) async throws -> String? {
        state.withLock { $0.contributionChecks.append(photoSubmissionID) }
        await beforeContributionReturns?()
        return try contributionResult.get()
    }

    @concurrent
    func contributedPhotos(
        for listingID: String,
        excluding: Set<String>,
        downloadingInto directory: URL
    ) async throws -> [CommunityPhotoContribution] {
        state.withLock { recording in
            recording.contributionRequests.append(
                (listingID: listingID, excluding: excluding)
            )
        }
        // Honoured rather than merely recorded, for the reason the listing
        // queries honour theirs: the real transport filters before it spends
        // the download, and a suite asserting against a stub that had not
        // filtered would be asserting about a transport nobody ships.
        let contributions = try contributedPhotosResult.get()
        guard !excluding.isEmpty else { return contributions }
        return contributions.filter { !excluding.contains($0.authorID) }
    }

    @concurrent
    func photos(
        ofPending pending: CommunityPendingPhotos,
        downloadingInto directory: URL
    ) async throws -> CommunityPhotoContribution {
        state.withLock { $0.pendingDetailRequests.append(pending.photoSubmissionID) }
        await beforeDetailReturns?()
        guard let pendingPhotosResult else { throw CommunityFailure.noLongerAvailable }
        return try pendingPhotosResult.get()
    }

    @concurrent
    func keepOnlyPhotos(
        _ kept: [CommunityKeptPhoto],
        ofPending pending: CommunityPendingPhotos,
        staging: URL
    ) async throws {
        state.withLock { recording in
            recording.contributionPhotoEdits.append((pending.photoSubmissionID, kept))
        }
        try keepPhotosResult.get()
    }

    @concurrent
    func publishPhotos(
        _ pending: CommunityPendingPhotos
    ) async throws -> CommunityPhotoContribution {
        state.withLock { $0.publishedPhotos.append(pending) }
        if let publishPhotosResult { return try publishPhotosResult.get() }
        // Built from what went in rather than from a fixture, the default the
        // hike's own publish takes and for the same reason.
        return CommunityPhotoContribution(
            id: "contribution-for-\(pending.photoSubmissionID)",
            photoSubmissionID: pending.photoSubmissionID,
            authorName: pending.authorName,
            authorID: pending.authorID,
            publishedAt: pending.noticedAt,
            photoPins: [],
            photoFileURLs: [],
            photosOnRecord: pending.photoCount
        )
    }

    @concurrent
    func declinePhotos(_ pending: CommunityPendingPhotos) async throws {
        state.withLock { $0.declinedPhotos.append(pending) }
        try declineResult.get()
    }

    @concurrent
    func takeDownPhotos(_ contribution: CommunityPhotoContribution) async throws {
        state.withLock { $0.takenDownPhotos.append(contribution.id) }
        try takeDownResult.get()
    }
}

extension CommunityPendingSubmission {
    /// Fixed moments, for the reason ``CommunityListing/stub(id:submissionID:title:authorName:authorID:distanceMeters:photoCount:latitude:longitude:)``
    /// has them: two of these built in different suites have to compare equal.
    private enum StubDate {
        static let walkedInterval: TimeInterval = 1_750_000_000
        static let noticedInterval: TimeInterval = 1_750_050_000
        static let walked = Date(timeIntervalSince1970: walkedInterval)
        static let noticed = Date(timeIntervalSince1970: noticedInterval)
    }

    /// A queue entry with everything filled in.
    ///
    /// ``CommunityPendingSubmission/photoCount`` defaults to zero, which is
    /// not laziness: it is what the transport actually returns, because the
    /// count cannot be known without downloading the photographs. A suite
    /// asserting on a published count has to set it the way the review screen
    /// does — from a loaded detail.
    static func stub(
        id: String = "notice-1",
        submissionID: String = "submission-1",
        title: String = "Pilis Ridge",
        authorName: String = "Anna",
        authorID: String = "author-1",
        trackDescription: String = "",
        distanceMeters: Double = 8000,
        photoCount: Int = 0,
        latitude: Double = 47.63,
        longitude: Double = 12.86
    ) -> Self {
        Self(
            id: id,
            submissionID: submissionID,
            title: title,
            authorName: authorName,
            authorID: authorID,
            trackDescription: trackDescription,
            hikeDate: StubDate.walked,
            distanceMeters: distanceMeters,
            photoCount: photoCount,
            latitude: latitude,
            longitude: longitude,
            noticedAt: StubDate.noticed
        )
    }
}

extension CommunityListing {
    /// Fixed moments so a listing built in two different tests compares equal.
    ///
    /// Declared as intervals first, the way `Fixture.RidgeRoute` declares its
    /// own start: the linter reads a literal inside a `Date(...)` call as a
    /// magic number and a named `TimeInterval` as a constant.
    private enum StubDate {
        static let walkedInterval: TimeInterval = 1_750_000_000
        static let publishedInterval: TimeInterval = 1_750_100_000
        static let walked = Date(timeIntervalSince1970: walkedInterval)
        static let published = Date(timeIntervalSince1970: publishedInterval)
    }

    /// A listing with everything filled in, for the suites that care about one
    /// or two fields of it.
    static func stub(
        id: String = "listing-1",
        submissionID: String = "submission-1",
        title: String = "Pilis Ridge",
        authorName: String = "Anna",
        authorID: String = "author-1",
        distanceMeters: Double = 8000,
        photoCount: Int = 2,
        latitude: Double = 47.63,
        longitude: Double = 12.86
    ) -> Self {
        Self(
            id: id,
            submissionID: submissionID,
            title: title,
            authorName: authorName,
            authorID: authorID,
            hikeDate: StubDate.walked,
            distanceMeters: distanceMeters,
            photoCount: photoCount,
            latitude: latitude,
            longitude: longitude,
            publishedAt: StubDate.published
        )
    }
}

/// A block list backed by its own defaults domain.
///
/// Never `.standard`: a suite that blocked somebody there would hide hikes
/// from the developer's own simulator and from every suite after it, and a
/// block list is the one thing whose whole job is to persist.
extension CommunityBlockList {
    static func scratch() -> CommunityBlockList {
        guard let defaults = UserDefaults(suiteName: "community-blocks-\(UUID().uuidString)") else {
            preconditionFailure("Could not open a scratch defaults domain")
        }
        return CommunityBlockList(defaults: defaults)
    }
}

/// What the browser asks the name of a searched area, instead of MapKit.
///
/// A seam for the same reason the transport above is one, and a sharper one
/// than it looks: `MKReverseGeocodingRequest` reaches the network, so a suite
/// using the real thing would geocode on somebody's rate limit and get a
/// different answer depending on where the machine running it is.
@MainActor
final class StubAreaNames: CommunityAreaNaming {
    /// What to answer. `nil` is the ordinary failure — no network, no result —
    /// which the header treats as "no name" rather than as an error.
    var answer: String?
    /// The areas asked about, in order. What proves the browser names the area
    /// it committed to rather than wherever the map has drifted to since.
    private(set) var asked: [CommunitySearchArea] = []

    init(answer: String? = nil) {
        self.answer = answer
    }

    // `async` because the protocol is, and the stub answers at once: what the
    // browser has to get right is that the name it publishes belongs to the
    // area it committed to, which does not need a suspension to exercise.
    func name(for area: CommunitySearchArea) async -> String? {
        await Task.yield()
        asked.append(area)
        return answer
    }
}

/// A one-shot barrier a stub can block on, so a suite can hold one request
/// open while it starts another.
///
/// An actor rather than a semaphore because the thing being held is an `await`
/// inside a `Task`, and blocking a thread there would deadlock the executor
/// rather than delay the call.
actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

// MARK: - Writing a queue down

extension CommunityReviewBatch {
    /// A queue of hikes and nothing else.
    ///
    /// Which is what every suite written before contributions existed is
    /// describing, and the reason it earns a spelling of its own: those suites
    /// are about *the queue*, not about what is in it, and rewriting each of
    /// them to name an empty second array would have made the half they do not
    /// care about the visible half.
    static func hikes(_ hikes: [CommunityPendingSubmission]) -> Self {
        Self(hikes: hikes)
    }

    /// A queue of contributed photographs and nothing else.
    static func photographs(_ photographs: [CommunityPendingPhotos]) -> Self {
        Self(photographs: photographs)
    }
}
