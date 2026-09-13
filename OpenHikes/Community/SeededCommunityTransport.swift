//
//  SeededCommunityTransport.swift
//  OpenHikes
//
//  A public database with three hikes in it that nobody published.
//
//  Community is the newest feature in the app and the only one no test drives
//  end to end. ``OpenHikesModel/makeCommunityTransport()`` hands back `nil` for
//  every launch that is running tests, which removes the picker, the list and
//  the share button outright — so the UI and accessibility suites could be
//  entirely green while the whole feature was untouched, and they were.
//
//  The `nil` is right and stays. There is no sandbox for the public database
//  the way `StoreKitTest` is one for purchases: a submission made from a test
//  is a submission, visible to every other user of this app and sitting in a
//  reviewer's queue. What was missing was a third answer between "the real
//  database" and "nothing at all".
//
//  This is it, and the important word is *explicit*. A launch gets one only by
//  asking for it by name — `--ui-test-community=<scenario>` — so nothing about
//  the rule above changes: a hosted unit suite, a performance run and every UI
//  scenario that does not name this still get `nil`, and no build of the app
//  that a person could install can reach this file at all, because the whole
//  of it is `#if DEBUG`.
//
//  ## What is faked, and what is not
//
//  Only the database. Everything downstream of these methods is the shipping
//  code: ``CommunityBrowser`` spends its real page budget on these rows,
//  ``CommunityRoutePayload`` validates this route the way it validates a
//  stranger's, the photographs are real JPEGs written to disk and read back
//  through the real ImageIO decode, ``CommunityImport`` saves into the real
//  store, and the block list, the report sheet and the share flow are
//  untouched. A test that opens one of these hikes is testing the app.
//
//  The photographs are the part worth being careful about. They are generated
//  rather than bundled — ``SeededPhotoFixture`` already draws incompressible
//  ones for the performance suite — but at a fraction of that fixture's
//  resolution, because these are encoded on every preview open rather than
//  once per scenario, and what a functional test needs from a photograph is
//  that it is a real file a real decode can read.
//
//  ## What the seeded hikes are shaped for
//
//  Three listings, two authors. Anna published the first and the third, which
//  is what makes blocking observable: blocking her takes two rows and leaves
//  one, where a list of three strangers would leave the difference between
//  "blocked" and "the list failed" unreadable. Only the first carries
//  photographs, so the gallery and an import *with* pictures have somewhere to
//  happen and an import without them still gets covered.
//
//  Every route starts within a few hundred metres of ``UITestFixture``'s
//  trailhead, which is where the scenarios put the simulated fix, so a nearby
//  search from there answers with all three.
//

import CoreLocation
import Foundation

#if DEBUG

/// A stand-in for the public database, seeded from the launch argument that
/// asked for it.
nonisolated struct SeededCommunityTransport: CommunityTransporting {
    /// Which shape of database this launch wants.
    ///
    /// Three, because the list has three states worth looking at and only one
    /// of them is the happy one. A screen that has never been seen empty or
    /// broken is a screen whose empty and broken states were written blind.
    enum Scenario: String, CaseIterable {
        /// Nothing published anywhere near here, which is the ordinary answer
        /// for most of the world and the one the empty row is for.
        case empty = "empty"
        /// Every read fails, so the failure row, the retry and the preview's
        /// own error state can be driven.
        case failing = "failing"
        /// Three published hikes, one of them with photographs.
        case seeded = "seeded"

        /// The scenario a launch argument names, or `nil` for a launch that
        /// did not ask — which is every launch that must get no transport at
        /// all.
        init?(argument: String?) {
            guard let argument, let named = Self(rawValue: argument) else { return nil }
            self = named
        }
    }

    let scenario: Scenario

    // MARK: - Reading

    @concurrent
    func listings(
        near coordinate: CLLocationCoordinate2D,
        radiusMeters: Double,
        limit: Int,
        excluding: Set<String>
    ) async throws -> [CommunityListing] {
        // The coordinate and the radius are deliberately ignored. What a
        // scenario is asking is "what does the list do with these rows", and
        // making that depend on where the simulator's map happened to settle
        // would turn a UI assertion into a geography assertion — the failure
        // being an empty list with nothing to say about why.
        try answer(Self.seededListings.filter { !excluding.contains($0.authorID) })
    }

    @concurrent
    func listings(
        matching query: String,
        limit: Int,
        excluding: Set<String>
    ) async throws -> [CommunityListing] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return try answer(
            Self.seededListings.filter { listing in
                !excluding.contains(listing.authorID)
                    && listing.title.localizedCaseInsensitiveContains(trimmed)
            }
        )
    }

    @concurrent
    func outlines(for listings: [CommunityListing]) async throws -> [String: [RouteCoordinate]] {
        guard scenario != .failing else { throw CommunityFailure.unreachable }
        guard scenario == .seeded else { return [:] }
        // Through the real encoder and back out through the real decoder,
        // rather than handing the route over directly: the map draws whatever
        // survives that round trip in production, and an outline that would
        // not survive it is exactly the bug this could otherwise hide.
        var outlines: [String: [RouteCoordinate]] = [:]
        for listing in listings {
            guard let encoded = CommunityRouteOutline.encoded(Self.route(of: listing)) else {
                continue
            }
            outlines[listing.id] = CommunityRouteOutline.decodedRoute(encoded)
        }
        return outlines
    }

    @concurrent
    func detail(
        for listing: CommunityListing,
        downloadingInto directory: URL
    ) async throws -> CommunityHikeDetail {
        guard scenario == .seeded else { throw CommunityFailure.noLongerAvailable }
        // The same check the real transport makes in the same place and for
        // the same reason: a hiker who backs out mid-download must not have
        // files written into a directory the screen has already deleted.
        try Task.checkCancellation()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let route = Self.route(of: listing)
        let photos = await Self.writePhotos(count: listing.photoCount, into: directory)
        return CommunityHikeDetail(
            listing: listing,
            route: route,
            trackDescription: Self.description(of: listing),
            // Built from the files that were actually written, so the pairing
            // invariant ``CommunityHikeDetail/isConsistent`` asks about holds
            // here for the reason it holds in production rather than by luck.
            photoPins: photos.map { _ in
                CommunityPhotoPin(capturedAt: listing.hikeDate, coordinate: route.first?.clCoordinate)
            },
            photoFileURLs: photos
        )
    }

    // MARK: - Writing

    @concurrent
    func submit(_ draft: CommunitySubmissionDraft) async throws -> String {
        guard !draft.route.isEmpty else { throw CommunityFailure.nothingToShare }
        guard scenario != .failing else { throw CommunityFailure.notSignedIn }
        return "seeded-submission-\(draft.hikeID.uuidString)"
    }

    @concurrent
    func publication(of submissionID: String) async throws -> CommunityListing? {
        guard scenario != .failing else { throw CommunityFailure.unreachable }
        // Never published, which is the honest answer for a submission this
        // process invented a moment ago and the state the share screen has to
        // be able to draw: a hike waiting for a reviewer looks the same as one
        // a reviewer declined, deliberately — see ``CommunityTransporting``.
        return nil
    }

    /// One read's worth of answer, or the failure the scenario promises.
    ///
    /// `unreachable` rather than `unavailable`: it is the failure a hiker in a
    /// valley actually gets, it is the one whose recovery sentence tells them
    /// to try again, and *Try Again* is the control these scenarios exist to
    /// put under a test.
    private func answer(_ listings: [CommunityListing]) throws -> [CommunityListing] {
        switch scenario {
        case .seeded: listings
        case .empty: []
        case .failing: throw CommunityFailure.unreachable
        }
    }
}

// MARK: - The hikes

nonisolated extension SeededCommunityTransport {
    /// Anna, who published two of the three.
    static let blockableAuthorID = "seeded-author-anna"
    static let blockableAuthorName = "Anna"
    /// The one row that survives blocking Anna, so a scenario can tell an
    /// applied block from an emptied list.
    static let otherAuthorID = "seeded-author-bern"

    /// Titles are constants so a scenario can search for one without spelling
    /// it twice, and share no word with each other: a typed search asserting
    /// that two rows disappeared is worth nothing if the query matched them
    /// all.
    static let ridgeTitle = "Thumsee Ridge Traverse"
    static let lakeTitle = "Lakeside Circuit"
    static let scrambleTitle = "Ostwand Scramble"

    static let seededListings: [CommunityListing] = [
        listing(
            id: "seeded-listing-ridge",
            title: ridgeTitle,
            authorID: blockableAuthorID,
            authorName: blockableAuthorName,
            photoCount: photographedCount,
            distanceMeters: ridgeDistanceMeters
        ),
        listing(
            id: "seeded-listing-lake",
            title: lakeTitle,
            authorID: otherAuthorID,
            authorName: "Bern",
            photoCount: 0,
            distanceMeters: lakeDistanceMeters
        ),
        listing(
            id: "seeded-listing-scramble",
            title: scrambleTitle,
            authorID: blockableAuthorID,
            authorName: blockableAuthorName,
            photoCount: 0,
            distanceMeters: scrambleDistanceMeters
        ),
    ]

    /// Two, which is enough for a gallery to be a gallery and few enough that
    /// opening a preview is not an encode the test has to wait on.
    static let photographedCount = 2

    /// Three different lengths, so a row showing the wrong hike's distance is
    /// something a scenario can see rather than something it reads past.
    private static let ridgeDistanceMeters = 8400.0
    private static let lakeDistanceMeters = 5200.0
    private static let scrambleDistanceMeters = 11_900.0

    private static func listing(
        id: String,
        title: String,
        authorID: String,
        authorName: String,
        photoCount: Int,
        distanceMeters: Double
    ) -> CommunityListing {
        CommunityListing(
            id: id,
            submissionID: "\(id)-submission",
            title: title,
            authorName: authorName,
            authorID: authorID,
            hikeDate: hikeDate,
            distanceMeters: distanceMeters,
            photoCount: photoCount,
            latitude: startLatitude,
            longitude: startLongitude,
            publishedAt: publishedDate
        )
    }

    /// Fixed rather than relative to now, so two runs of one scenario draw the
    /// same row and a screenshot from either is worth comparing.
    private static let hikeInterval: TimeInterval = 1_750_000_000
    private static let publishedInterval: TimeInterval = 1_750_100_000
    private static let hikeDate = Date(timeIntervalSince1970: hikeInterval)
    private static let publishedDate = Date(timeIntervalSince1970: publishedInterval)
    /// `UITestFixture.trailheadCoordinate`, which is where every scenario puts
    /// the simulated fix. Spelled out rather than shared because that fixture
    /// lives in the UI test bundle, which this target cannot import.
    static let startLatitude = 47.718420
    static let startLongitude = 12.831774
}

// MARK: - What is behind one

nonisolated private extension SeededCommunityTransport {
    /// How far apart consecutive points are, in degrees of latitude: about
    /// 22 m, which is a walking pace rather than a sprint and gives the
    /// elevation profile something to draw.
    static let stepLatitude = 0.0002
    static let stepLongitude = 0.00012
    static let pointCount = 24
    static let baseElevation = 535.0
    static let elevationStep = 4.0
    static let secondsPerPoint: TimeInterval = 20

    /// A route per listing, offset so no two draw the same line on the map.
    ///
    /// Timestamps and elevations included, because a preview without them is
    /// a preview of a different screen: the stat tiles, the elevation chart
    /// and the duration all come off these, and leaving them out would mean
    /// asserting on a page the real one never shows.
    static func route(of listing: CommunityListing) -> [RouteCoordinate] {
        let offset = Double(abs(listing.id.hashValue % 5)) * stepLatitude
        return (0..<pointCount).map { step in
            RouteCoordinate(
                latitude: startLatitude + offset + Double(step) * stepLatitude,
                longitude: startLongitude + Double(step) * stepLongitude,
                elevation: baseElevation + Double(step) * elevationStep,
                timestamp: listing.hikeDate.addingTimeInterval(
                    Double(step) * secondsPerPoint
                )
            )
        }
    }

    static func description(of listing: CommunityListing) -> String {
        """
        \(listing.title): a seeded hike for automation. Steady climb out of the \
        valley, then a ridge with the lake on your left the whole way back.
        """
    }

    /// Real JPEGs on disk, in the directory the preview owns and deletes.
    ///
    /// A quarter of ``SeededPhotoFixture``'s twelve megapixels in each
    /// dimension. That fixture is sized against a phone camera because it
    /// exists to be *measured*; these are encoded every time a preview opens
    /// and only have to be photographs, so the smaller frame keeps a scenario
    /// that opens three previews from spending its budget in an encoder.
    static func writePhotos(count: Int, into directory: URL) async -> [URL] {
        var written: [URL] = []
        for index in 0..<count {
            guard let data = await SeededPhotoFixture.encodedImage(
                index: index,
                size: photoPixelSize
            ) else { continue }
            let url = directory.appendingPathComponent("seeded-photo-\(index).jpeg")
            guard (try? data.write(to: url)) != nil else { continue }
            written.append(url)
        }
        return written
    }

    /// A quarter of the fixture's own frame in each dimension.
    static let photoPixelWidth = 1008.0
    static let photoPixelHeight = 756.0
    static let photoPixelSize = CGSize(width: photoPixelWidth, height: photoPixelHeight)
}

#endif
