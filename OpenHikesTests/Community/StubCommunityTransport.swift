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
    }

    /// What each call should do. Set before the call, read inside it.
    var submissionResult: Result<String, CommunityFailure> = .success("submission-1")
    var listingsResult: Result<[CommunityListing], CommunityFailure> = .success([])
    var detailResult: Result<CommunityHikeDetail, CommunityFailure>?
    /// Held open so a suite can watch two requests overlap — see
    /// `CommunityBrowserTests`.
    var beforeListingsReturn: (@Sendable () async -> Void)?

    private let state = Mutex(Recording())

    var recording: Recording { state.withLock { $0 } }

    @concurrent
    func submit(_ draft: CommunitySubmissionDraft) async throws -> String {
        state.withLock { $0.submissions.append(draft) }
        return try submissionResult.get()
    }

    @concurrent
    func listings(
        near coordinate: CLLocationCoordinate2D,
        radiusMeters: Double,
        limit: Int
    ) async throws -> [CommunityListing] {
        state.withLock { recording in
            recording.nearbyRequests.append((coordinate: coordinate, radiusMeters: radiusMeters))
        }
        await beforeListingsReturn?()
        return try listingsResult.get()
    }

    @concurrent
    func listings(matching query: String, limit: Int) async throws -> [CommunityListing] {
        state.withLock { $0.titleQueries.append(query) }
        await beforeListingsReturn?()
        return try listingsResult.get()
    }

    @concurrent
    func detail(
        for listing: CommunityListing,
        downloadingInto directory: URL
    ) async throws -> CommunityHikeDetail {
        state.withLock { $0.detailRequests.append(listing.id) }
        guard let detailResult else { throw CommunityFailure.noLongerAvailable }
        return try detailResult.get()
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
            hikeDate: StubDate.walked,
            distanceMeters: distanceMeters,
            photoCount: photoCount,
            latitude: latitude,
            longitude: longitude,
            publishedAt: StubDate.published
        )
    }
}
