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
    /// Five, because the list has three states worth looking at and only one
    /// of them is the happy one — and because two screens depend not on what
    /// the list holds but on what a *reviewer* has done, or has yet to do. A
    /// screen that has never been seen empty or broken is a screen whose empty
    /// and broken states were written blind.
    enum Scenario: String, CaseIterable {
        /// ``seeded``, plus curated routes from OpenStreetMap.
        ///
        /// The only way to reach a *mixed* list from automation, which is the
        /// one the shipping app draws: a published hike and a curated route in
        /// one list, where the second has no author to block, no record to
        /// report and no photographs. Everything those two rows differ in is
        /// invisible unless both are on screen at once — the row glyph, the
        /// subtitle's parts, and the three menu items that are absent rather
        /// than disabled.
        case curated = "curated"
        /// Nothing published anywhere near here, which is the ordinary answer
        /// for most of the world and the one the empty row is for.
        case empty = "empty"
        /// Every read fails, so the failure row, the retry and the preview's
        /// own error state can be driven.
        case failing = "failing"
        /// ``seeded``, and a reviewer who has said yes.
        ///
        /// The only way to reach the *published* state from automation.
        /// `publication(of:)` is what promotes a hike from *awaiting review*
        /// to *published* — ``CommunityPublicationCheck`` writes
        /// ``Hike/communityListingID`` from its answer and nothing else does
        /// — so a scenario that always answers `nil` leaves two screens
        /// undriveable: the *published* share-button menu, and
        /// ``CommunityWithdrawalSheet``'s published footer, which is a
        /// different sentence from its awaiting-review one.
        case published = "published"
        /// ``seeded``, plus a queue with something in it.
        ///
        /// The only way to reach the review section from automation, and the
        /// reason it needs a scenario of its own is the same reason the
        /// section is safe: an ordinary launch gets an empty queue because the
        /// *server* refuses one, so nothing a UI test can tap would ever fill
        /// it. This scenario is the stand-in for being in the role.
        case reviewing = "reviewing"
        /// Three published hikes, one of them with photographs.
        case seeded = "seeded"

        /// Whether this scenario has a database behind it at all, as opposed
        /// to being empty or broken. The two that do differ only in what
        /// ``publication(of:)`` says.
        var servesListings: Bool {
            self == .seeded || self == .published || self == .reviewing
                || self == .curated
        }

        /// Whether OpenStreetMap's half of the list has anything in it.
        ///
        /// One scenario, and behind the same door as the rest: a launch that
        /// does not name this gets no curated source at all, so no suite
        /// reaches Overpass by default any more than it reaches CloudKit. See
        /// ``OpenHikesModel/makeCommunityTransport()``.
        var servesCuratedTrails: Bool { self == .curated }

        /// Whether a reviewer's queue has anything in it. One scenario, for
        /// the reason ``reviewing`` gives.
        var servesQueue: Bool { self == .reviewing }

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

    /// The scope is ignored here for the reason the coordinate is, and for one
    /// of its own: this transport has a single source, and the curated half a
    /// `curated` launch gets is ``SeededCuratedTrailSource`` behind the real
    /// ``MergedCommunityTransport``, which is what the scope decides anything
    /// in.
    @concurrent
    func listings(
        near coordinate: CLLocationCoordinate2D,
        radiusMeters: Double,
        limit: Int,
        excluding: Set<String>,
        scope _: CommunityNearbyScope
    ) async throws -> CommunityNearbyAnswer {
        // The coordinate and the radius are deliberately ignored. What a
        // scenario is asking is "what does the list do with these rows", and
        // making that depend on where the simulator's map happened to settle
        // would turn a UI assertion into a geography assertion — the failure
        // being an empty list with nothing to say about why.
        CommunityNearbyAnswer(
            listings: try answer(
                Self.seededListings.filter { listing in
                    listing.blockableAuthorID.map { !excluding.contains($0) } ?? true
                }
            )
        )
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
                (listing.blockableAuthorID.map { !excluding.contains($0) } ?? true)
                    && listing.title.localizedCaseInsensitiveContains(trimmed)
            }
        )
    }

    @concurrent
    func outlines(for listings: [CommunityListing]) async throws -> [String: [RouteCoordinate]] {
        guard scenario != .failing else { throw CommunityFailure.unreachable }
        guard scenario.servesListings else { return [:] }
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
        guard scenario.servesListings else { throw CommunityFailure.noLongerAvailable }
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
                CommunityPhotoPin(
                    // Every seeded listing carries a date; the fallback is
                    // here because the field is optional for a curated route,
                    // and this stand-in serves only published ones.
                    capturedAt: listing.hikeDate ?? Self.hikeDate,
                    coordinate: route.first?.clCoordinate
                )
            },
            photoFileURLs: photos,
            // Every one of them arrived, because this stand-in drew them a
            // moment ago. A scenario for the partial case would be a scenario
            // for a download failure, which is not a thing a seeded database
            // can imitate honestly.
            photosOnRecord: photos.count
        )
    }

    // MARK: - Writing

    @concurrent
    func submit(_ draft: CommunitySubmissionDraft) async throws -> String {
        guard !draft.route.isEmpty else { throw CommunityFailure.nothingToShare }
        guard scenario != .failing else { throw CommunityFailure.notSignedIn }
        return "seeded-submission-\(draft.hikeID.uuidString)"
    }

    // MARK: - Reviewing

    @concurrent
    func pendingSubmissions() async throws -> [CommunityPendingSubmission] {
        guard scenario != .failing else { throw CommunityFailure.unreachable }
        // A refusal rather than an empty list, because that is what the
        // server gives an account outside the role — and the two are no longer
        // the same answer: an *allowed* empty queue still means reviewer, and
        // would put *Take Down* on every published hike in these scenarios.
        // See ``CommunityReviewQueue/isReviewer``.
        guard scenario.servesQueue else { throw CommunityFailure.notPermitted }
        return Self.queuedSubmissions
    }

    @concurrent
    func detail(
        ofPending pending: CommunityPendingSubmission,
        downloadingInto directory: URL
    ) async throws -> CommunityHikeDetail {
        guard scenario != .failing else { throw CommunityFailure.unreachable }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        // Built here rather than handed to ``detail(for:downloadingInto:)``,
        // because the two differ in the two things review is *about*. The
        // description is the hiker's own words, not a sentence synthesised
        // from the title — judging it is most of the job. And the photographs
        // are decided here because a queue entry does not know how many it
        // has: the count arrives with the assets, which is the production
        // shape this scenario exists to imitate.
        let route = Self.route(of: pending.prospectiveListing)
        let photoCount = pending.title == Self.queuedPhotographedTitle
            ? Self.photographedCount
            : 0
        let photos = await Self.writePhotos(count: photoCount, into: directory)
        return CommunityHikeDetail(
            listing: pending.prospectiveListing,
            route: route,
            trackDescription: pending.trackDescription.isEmpty ? nil : pending.trackDescription,
            photoPins: photos.map { _ in
                CommunityPhotoPin(capturedAt: pending.hikeDate, coordinate: route.first?.clCoordinate)
            },
            photoFileURLs: photos,
            photosOnRecord: photos.count
        )
    }

    // `.unreachable` rather than `.notPermitted`, like every other method
    // here: ``Scenario/failing`` is a database that cannot be reached, and a
    // stand-in that answered a broken network with *this account can't review
    // submissions* would put the one sentence in front of a reviewer that
    // sends them to the CloudKit Console over a lost signal.
    @concurrent
    func keepOnlyPhotos(
        _ kept: [CommunityKeptPhoto],
        of pending: CommunityPendingSubmission,
        staging: URL
    ) async throws {
        guard scenario != .failing else { throw CommunityFailure.unreachable }
        // Nothing is rewritten, because there is no record to rewrite: the
        // photographs this stand-in hands out are drawn into files by
        // ``writePhotos(count:into:)`` on the way out of `detail`. What a UI
        // test can see is the strip and the count the screen carries into
        // publishing, and both of those are the review screen's own state.
    }

    @concurrent
    func publish(_ pending: CommunityPendingSubmission) async throws -> CommunityListing {
        guard scenario != .failing else { throw CommunityFailure.unreachable }
        return Self.publishedListing(of: pending.submissionID)
    }

    @concurrent
    func decline(_ pending: CommunityPendingSubmission) async throws {
        guard scenario != .failing else { throw CommunityFailure.unreachable }
    }

    @concurrent
    func takeDown(_ listing: CommunityListing) async throws {
        guard scenario != .failing else { throw CommunityFailure.unreachable }
    }

    @concurrent
    func publication(of submissionID: String) async throws -> CommunityListing? {
        guard scenario != .failing else { throw CommunityFailure.unreachable }
        // Never published, which is the honest answer for a submission this
        // process invented a moment ago and the state the share screen has to
        // be able to draw: a hike waiting for a reviewer looks the same as one
        // a reviewer declined, deliberately — see ``CommunityTransporting``.
        guard scenario == .published else { return nil }
        // A listing derived from the submission rather than one of the three
        // seeded rows, because what the caller does with it is read its `id`
        // onto the hike — and an id borrowed from another hike's listing would
        // make a withdrawal request name a record that has nothing to do with
        // it. The record name is the whole content of that request.
        return Self.publishedListing(of: submissionID)
    }

    /// The listing a reviewer would have created from `submissionID`.
    ///
    /// Only the id is load-bearing — it is what ``CommunityPublicationCheck``
    /// writes to ``Hike/communityListingID``, and what
    /// ``CommunityWithdrawal`` then names. The rest is filled in so the value
    /// is a listing rather than a shape.
    private static func publishedListing(of submissionID: String) -> CommunityListing {
        CommunityListing(
            id: "seeded-listing-\(submissionID)",
            submissionID: submissionID,
            title: "Published by a reviewer",
            authorName: "",
            authorID: "seeded-reviewer",
            hikeDate: Self.hikeDate,
            distanceMeters: 0,
            photoCount: 0,
            latitude: Self.startLatitude,
            longitude: Self.startLongitude,
            publishedAt: Self.publishedDate
        )
    }

    /// One read's worth of answer, or the failure the scenario promises.
    ///
    /// `unreachable` rather than `unavailable`: it is the failure a hiker in a
    /// valley actually gets, it is the one whose recovery sentence tells them
    /// to try again, and *Try Again* is the control these scenarios exist to
    /// put under a test.
    private func answer(_ listings: [CommunityListing]) throws -> [CommunityListing] {
        switch scenario {
        case .seeded, .published, .reviewing, .curated: listings
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

    /// Titles for the queue, sharing no word with the published three so a
    /// scenario asserting that the review section is separate from the browse
    /// list cannot be fooled by a match across both.
    static let queuedTitle = "Karwendel Hut Approach"
    static let queuedPhotographedTitle = "Steinerne Rinne"

    /// What a reviewer's queue holds under ``Scenario/reviewing``.
    ///
    /// Two, and deliberately not alike: one carries a description and
    /// photographs — the case a reviewer actually has to read and look at —
    /// and one carries neither, which is the case where the screen has nothing
    /// to show but a title, a credit and a line on the map.
    ///
    /// ``CommunityPendingSubmission/photoCount`` is zero on both, because that
    /// is what the real transport returns: the count arrives with the
    /// photographs, from the screen that fetches them. A scenario that wants
    /// to see a count has to open the preview, which is the same thing a
    /// reviewer has to do.
    static let queuedSubmissions: [CommunityPendingSubmission] = [
        queued(
            id: "seeded-notice-hut",
            title: queuedTitle,
            authorName: "Chris",
            trackDescription: "",
            distanceMeters: queuedDistanceMeters
        ),
        queued(
            id: "seeded-notice-rinne",
            title: queuedPhotographedTitle,
            authorName: blockableAuthorName,
            trackDescription: """
                A long approach on forest road, then the gully proper. \
                Wet rock after rain and the chains are old.
                """,
            distanceMeters: queuedPhotographedDistanceMeters
        ),
    ]

    private static let queuedDistanceMeters = 6700.0
    private static let queuedPhotographedDistanceMeters = 9300.0

    private static func queued(
        id: String,
        title: String,
        authorName: String,
        trackDescription: String,
        distanceMeters: Double
    ) -> CommunityPendingSubmission {
        CommunityPendingSubmission(
            id: id,
            submissionID: "\(id)-submission",
            title: title,
            authorName: authorName,
            // An opaque string, as the real one is: this is what CloudKit
            // stamps on the upload, not anything the hiker chose.
            authorID: "seeded-author-\(id)",
            trackDescription: trackDescription,
            hikeDate: hikeDate,
            distanceMeters: distanceMeters,
            photoCount: 0,
            latitude: startLatitude,
            longitude: startLongitude,
            noticedAt: hikeDate
        )
    }

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
    static let hikeDate = Date(timeIntervalSince1970: hikeInterval)
    static let publishedDate = Date(timeIntervalSince1970: publishedInterval)
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
        // Hoisted out of the closure below rather than written inline: with
        // the optional unwrap in place the whole `RouteCoordinate` expression
        // stopped type-checking in reasonable time. Every seeded listing is a
        // published one and carries a date; the fallback is here because the
        // field is optional for a curated route.
        let start: Date = listing.hikeDate ?? hikeDate
        return (0..<pointCount).map { step in
            let elapsed = Double(step)
            return RouteCoordinate(
                latitude: startLatitude + offset + elapsed * stepLatitude,
                longitude: startLongitude + elapsed * stepLongitude,
                elevation: baseElevation + elapsed * elevationStep,
                timestamp: start.addingTimeInterval(elapsed * secondsPerPoint)
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
