//
//  MergedCommunityTransportTests.swift
//  OpenHikesTests
//
//  The three rules that let two sources look like one list.
//
//  ``MergedCommunityTransport`` is the only place in the app that knows the
//  community list has two halves, and that is exactly why it is worth a suite
//  of its own: everything above it — the browser, the map, the rows, the
//  import — is written as though there were one source, so a mistake here does
//  not surface as a wrong answer from this type. It surfaces as somebody's
//  published hike quietly missing from a list of village loops, or as a
//  *These are the hikes from the last search that worked* banner drawn over a
//  perfectly good CloudKit answer because Overpass returned a `429`.
//
//  Neither half is real here, and neither may be. The published half writes to
//  a **public** database with no sandbox behind it, and the curated half reads
//  a volunteer-run API on a quota shared by everybody using this app. So the
//  seams both protocols exist for are the ones these tests use — see
//  *Deliberate test seams* in the repository instructions — and each stub
//  records what it was asked, because half of what is asserted here is about
//  the request rather than the answer. "CloudKit was never asked" is not
//  observable in a return value.
//
//  The fixtures are placed by **metres from the search centre** rather than by
//  coordinates, because the thing being asserted is an order, and an order
//  written as four latitudes is a claim the next reader has to re-derive.
//
//  Values throughout are the measured ones: seven-digit Alpine relation ids,
//  an `osmc:symbol` in its real five-component form, and boxes small enough to
//  be day hikes by the same filter that rejected the five long-distance paths.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Synchronization
import Testing

// The body holds only fixtures; every test is in one of the extensions below,
// grouped by the rule it pins. A caseless enum is what `convenience_type`
// normally asks for and is not available here — Swift Testing attaches a suite
// to a type it can instantiate.
// swiftlint:disable convenience_type
@Suite("Merged community transport")
struct MergedCommunityTransportTests {
    /// The centre every search in this file is about — the Berchtesgaden box
    /// the whole feature was measured against.
    private static let centre = CLLocationCoordinate2D(latitude: 47.6300, longitude: 12.9900)

    /// Half of ``CuratedTrailQuery/maximumRadiusMeters``, so nothing here is
    /// accidentally testing the too-wide-to-ask refusal instead of the merge.
    private static let radiusMeters: Double = 20_000

    /// The page both halves are budgeted from. ``CuratedTrailQuery/geometryBatchLimit``
    /// and ``CommunityBrowser``'s own page are deliberately the same number,
    /// and this is it — a limit split that used two different figures would
    /// pass every test in this file and still be wrong in the app.
    private static let page = 25

    /// What a degree of latitude is worth on the ground, so a fixture can be
    /// placed in metres and asserted on as an order.
    private static let metresPerDegreeLatitude: Double = 111_320

    /// Four distances from ``centre``, handed out alternately to the two
    /// halves so that a correct interleave is one the expected array states
    /// outright rather than one the reader has to compute.
    private enum Offset {
        static let nearest: Double = 1000
        static let near: Double = 2000
        static let far: Double = 3000
        static let farthest: Double = 4000
    }

    /// Relation ids with the shape real ones have here: seven digits. Short
    /// ids would make ``CommunityIdentity/curated(relationID:)`` produce
    /// something too small to be convincing as the thing
    /// ``Hike/importedFromListingID`` has to hold beside a CloudKit record
    /// name.
    private enum Relation {
        static let wimbach: Int64 = 4_811_001
        static let almbach: Int64 = 4_811_002
        static let soleleitung: Int64 = 4_811_003
        /// What a bulk fixture counts up from, kept clear of the three above.
        static let base: Int64 = 4_812_000
    }

    /// Where a detail would download to, if either half of this were real.
    /// Both are stubs, nothing is written, and this is only ever passed on.
    private static let downloads = FileManager.default.temporaryDirectory
}
// swiftlint:enable convenience_type

// MARK: - Fixtures

private extension MergedCommunityTransportTests {
    /// The tags a well-mapped Alpine route carries, spelled as Overpass
    /// returns them.
    ///
    /// `osmc:symbol` is here whole rather than reduced to its colour, because
    /// what the merge is handed is what the decoder hands it — the first
    /// colon-separated component is the route colour and the rest describes a
    /// painted shape; see ``TrailWaymark``. `name` is absent on purpose: it is
    /// filled in per route below so no fixture can carry a name in its tags
    /// that disagrees with the name on its row.
    static let waymarkedTags: [String: String] = [
        "route": "hiking",
        "network": "lwn",
        "ref": "411",
        "osmc:symbol": "red:red:white_bar:411:black",
        "from": "Wimbachbrücke",
        "to": "Wimbachgrieshütte",
        "description": "Wimbachbrücke - Wimbachgries - Wimbachgrieshütte",
    ]

    static func tags(named name: String) -> [String: String] {
        var tags = waymarkedTags
        tags["name"] = name
        return tags
    }

    /// A curated route whose pin stands `metresNorth` of ``centre``.
    ///
    /// Placed by its **box** and not by its line, because that is where a
    /// curated pin actually stands — see ``CuratedTrailQuery/centre(of:)`` for
    /// why a relation's first member point is not a trailhead and must not be
    /// used as one. A fixture placed by its coordinates would make every
    /// ordering assertion here agree with a rule the feature does not follow.
    ///
    /// The box is a few hundred metres across, which is a day hike by
    /// ``CuratedTrailQuery/isDayHike(box:)`` with a wide margin — nowhere near
    /// the 20 km diagonal that rejected the five long-distance paths.
    static func trail(
        _ relationID: Int64,
        named name: String,
        metresNorth: Double
    ) -> CuratedTrail {
        let halfSpan = 0.004
        let latitude = centre.latitude + metresNorth / metresPerDegreeLatitude
        let box = CuratedTrailQuery.BoundingBox(
            south: latitude - halfSpan,
            west: centre.longitude - halfSpan,
            north: latitude + halfSpan,
            east: centre.longitude + halfSpan
        )
        return CuratedTrail(
            relationID: relationID,
            name: name,
            tags: tags(named: name),
            box: box,
            // Four points rather than two, so the line survives
            // ``CommunityRouteOutline/simplified(_:maximumPoints:)`` unchanged
            // and an outline assertion can compare counts.
            route: [
                RouteCoordinate(latitude: box.south, longitude: box.west),
                RouteCoordinate(latitude: latitude, longitude: box.west),
                RouteCoordinate(latitude: box.north, longitude: centre.longitude),
                RouteCoordinate(latitude: box.north, longitude: box.east),
            ]
        )
    }

    /// A published listing `metresNorth` of ``centre``, on the same meridian
    /// as every curated fixture, so distance is a function of one number.
    static func published(_ id: String, metresNorth: Double) -> CommunityListing {
        .stub(
            id: id,
            submissionID: "submission-\(id)",
            latitude: centre.latitude + metresNorth / metresPerDegreeLatitude,
            longitude: centre.longitude
        )
    }

    /// A detail for a published hike, for the forwarding paths that need one
    /// to come back rather than needing anything to be true of it.
    static func detail(of listing: CommunityListing) -> CommunityHikeDetail {
        let step = 0.001
        return CommunityHikeDetail(
            listing: listing,
            route: [
                RouteCoordinate(latitude: centre.latitude, longitude: centre.longitude),
                RouteCoordinate(latitude: centre.latitude + step, longitude: centre.longitude),
            ],
            trackDescription: nil,
            photoPins: [],
            photoFileURLs: [],
            photosOnRecord: 0
        )
    }

    /// The composite and both stubs behind it.
    ///
    /// All three together because every rule in this file is half about what
    /// came back and half about what was asked, and the stubs are the only
    /// place the second half is readable.
    struct Merged {
        let transport: MergedCommunityTransport
        let cloudKit: StubCommunityTransport
        let overpass: StubCuratedTrailSource
    }

    static func merged(
        published rows: [CommunityListing] = [],
        curated trails: [CuratedTrail] = []
    ) -> Merged {
        let cloudKit = StubCommunityTransport()
        cloudKit.listingsResult = .success(rows)
        let overpass = StubCuratedTrailSource(trails: trails)
        return Merged(
            transport: MergedCommunityTransport(published: cloudKit, curated: overpass),
            cloudKit: cloudKit,
            overpass: overpass
        )
    }

    /// One nearby question, answered. Defaults to the scope a tap on *Search
    /// this area* asks with, because that is the one both halves take part in
    /// and every rule in this file is about the merge.
    static func answer(
        _ merged: Merged,
        limit: Int = page,
        scope: CommunityNearbyScope = .withCuratedTrails
    ) async throws -> CommunityNearbyAnswer {
        try await merged.transport.listings(
            near: centre,
            radiusMeters: radiusMeters,
            limit: limit,
            excluding: [],
            scope: scope
        )
    }

    static func nearby(_ merged: Merged, limit: Int = page) async throws -> [CommunityListing] {
        try await answer(merged, limit: limit).listings
    }
}

// MARK: - A published hike never loses its place

extension MergedCommunityTransportTests {
    /// The failure this rule exists against, at its worst: an area with a full
    /// page of published hikes *and* waymarked routes closer to the centre
    /// than any of them. In the Alps that is most areas, and a merge that
    /// ordered before it spent the limit would push every real person's hike
    /// off the bottom of the list. Nearness is not a claim on the page.
    @Test("a full page of published hikes leaves no room for a curated one")
    func publishedRowsSpendTheWholeLimit() async throws {
        let step = 50.0
        let merged = Self.merged(
            published: (0..<Self.page).map { index in
                Self.published("listing-\(index)", metresNorth: Double(index) * step)
            },
            curated: (0..<Self.page).map { index in
                Self.trail(
                    Relation.base + Int64(index),
                    named: "Weg \(index)",
                    metresNorth: Offset.nearest / Double(Self.page)
                )
            }
        )

        let rows = try await Self.nearby(merged)

        #expect(rows.count == Self.page)
        #expect(
            !rows.contains { CommunityIdentity.isCurated($0.id) },
            "the nearest curated route is still behind the farthest published hike"
        )
    }

    /// The other half of the same rule, and the reason the feature was built:
    /// three hikes near a village is a list that looks broken, and the
    /// remainder of the page is what the curated half is for.
    @Test("three published hikes leave the rest of the page to the curated half")
    func curatedRowsTakeOnlyTheRemainder() async throws {
        let publishedCount = 3
        let offered = Self.page + 5
        let merged = Self.merged(
            published: (0..<publishedCount).map { index in
                Self.published("listing-\(index)", metresNorth: Offset.farthest)
            },
            curated: (0..<offered).map { index in
                Self.trail(Relation.base + Int64(index), named: "Weg \(index)", metresNorth: Offset.nearest)
            }
        )

        let rows = try await Self.nearby(merged)

        #expect(rows.count == Self.page)
        #expect(rows.filter(\.isCurated).count == Self.page - publishedCount)
        #expect(rows.filter { !$0.isCurated }.count == publishedCount)
    }

    /// The cost of the rule, and the reason the source's two passes are two.
    /// A full page of published hikes leaves the curated half no room at all —
    /// and the geometry it would have been asked for is 420 KB to 1.4 MB, per
    /// search, thrown away by the limit before a row is drawn.
    @Test("a full page of published hikes buys no geometry at all")
    func afullPageSkipsTheGeometryPass() async throws {
        let step = 50.0
        let merged = Self.merged(
            published: (0..<Self.page).map { index in
                Self.published("listing-\(index)", metresNorth: Double(index) * step)
            },
            curated: (0..<Self.page).map { index in
                Self.trail(Relation.base + Int64(index), named: "Weg \(index)", metresNorth: 10)
            }
        )

        _ = try await Self.nearby(merged)

        #expect(
            merged.overpass.recording.areaRequests.count == 1,
            "the cheap pass still runs, beside CloudKit"
        )
        #expect(merged.overpass.recording.completionSizes.isEmpty)
    }

    /// The general case: geometry is bought for the rows there is room to
    /// draw, and not one more. Asking for the full page and truncating
    /// afterwards is the version this replaces, and it is invisible in the
    /// rows — every assertion about the answer passes either way.
    @Test("geometry is fetched for the rows that fit, not for the page")
    func geometryIsFetchedOnlyForTheRoomLeft() async throws {
        let publishedCount = 20
        let offered = Self.page + 5
        let merged = Self.merged(
            published: (0..<publishedCount).map { index in
                Self.published("listing-\(index)", metresNorth: Offset.farthest)
            },
            curated: (0..<offered).map { index in
                Self.trail(Relation.base + Int64(index), named: "Weg \(index)", metresNorth: Offset.nearest)
            }
        )

        _ = try await Self.nearby(merged)

        #expect(
            merged.overpass.recording.completionSizes == [Self.page - publishedCount],
            "five rows of room, five lines fetched"
        )
    }

    /// A typed search is where the split is legible, because there is no
    /// centre to sort by and nothing re-orders the answer afterwards: what
    /// comes back *is* the order the limit was spent in.
    @Test("a typed search spends its limit on the published half first, in order")
    func titleSearchKeepsPublishedRowsInFront() async throws {
        let limit = 4
        let merged = Self.merged(
            published: [
                Self.published("listing-a", metresNorth: Offset.farthest),
                Self.published("listing-b", metresNorth: Offset.far),
            ],
            curated: [
                Self.trail(Relation.wimbach, named: "Wimbachweg", metresNorth: Offset.nearest),
                Self.trail(Relation.almbach, named: "Almbachweg", metresNorth: Offset.near),
                Self.trail(Relation.soleleitung, named: "Soleleitungsweg", metresNorth: Offset.near),
            ]
        )

        let rows = try await merged.transport.listings(matching: "weg", limit: limit, excluding: [])

        #expect(
            rows.map(\.id) == [
                "listing-a",
                "listing-b",
                CommunityIdentity.curated(relationID: Relation.wimbach),
                CommunityIdentity.curated(relationID: Relation.almbach),
            ]
        )
        #expect(merged.overpass.recording.titleQueries == ["weg"])
    }
}

// MARK: - One source failing is not the answer failing

extension MergedCommunityTransportTests {
    /// Overpass is a volunteer-run service that rate-limits, and answers an
    /// overloaded server with an HTML page carrying HTTP 200. None of that is
    /// something the hiker asked about or can act on, and none of it may cost
    /// them the list they did ask for.
    @Test("Overpass failing costs the curated rows and nothing else")
    func aCuratedFailureIsNotTheAnswerFailing() async throws {
        let merged = Self.merged(
            published: [Self.published("listing-a", metresNorth: Offset.near)],
            curated: [Self.trail(Relation.wimbach, named: "Wimbachweg", metresNorth: Offset.nearest)]
        )
        merged.overpass.nearbyResult = .failure(.rateLimited(retryAfter: 60))

        let rows = try await Self.nearby(merged)

        #expect(rows.map(\.id) == ["listing-a"])
    }

    /// The mirror case, which matters for a different reason: a hiker with no
    /// Apple Account or no reachable iCloud still gets a browse list, because
    /// the curated half needs neither.
    @Test("CloudKit failing still answers with the curated rows")
    func aPublishedFailureIsNotTheAnswerFailing() async throws {
        let merged = Self.merged(
            curated: [Self.trail(Relation.wimbach, named: "Wimbachweg", metresNorth: Offset.nearest)]
        )
        merged.cloudKit.listingsResult = .failure(.unreachable)

        let rows = try await Self.nearby(merged)

        #expect(rows.map(\.id) == [CommunityIdentity.curated(relationID: Relation.wimbach)])
    }

    /// Which failure is reported is a decision and not an accident. Both
    /// halves are down, the hiker is told one sentence, and the one worth
    /// telling them is about the database their own published hike lives in —
    /// not about a tag server they have never heard of.
    @Test("both halves failing throws, and reports CloudKit's failure")
    func bothHalvesFailingReportsThePublishedOne() async {
        let merged = Self.merged()
        merged.cloudKit.listingsResult = .failure(.unreachable)
        merged.overpass.nearbyResult = .failure(.rateLimited(retryAfter: 60))

        await #expect(throws: CommunityFailure.unreachable) {
            try await Self.nearby(merged)
        }
    }

    /// The case an over-eager version of the rule above would break: two
    /// halves that both succeeded and both had nothing is a real answer
    /// meaning *nowhere near there*, and drawing a failure over it would tell
    /// the hiker to check their connection about a working one.
    @Test("nothing near there is an answer rather than a failure")
    func twoEmptyHalvesDoNotThrow() async throws {
        let rows = try await Self.nearby(Self.merged())

        #expect(rows.isEmpty)
    }

    /// The question each half is asked has to be the same question, or a
    /// failure in one half would be indistinguishable from the two halves
    /// having searched different places.
    @Test("both halves are asked about the same area")
    func bothHalvesAreAskedTheSameQuestion() async throws {
        let merged = Self.merged()

        _ = try await Self.nearby(merged)

        let asked = try #require(merged.overpass.recording.areaRequests.first)
        #expect(asked.area.latitude == Self.centre.latitude)
        #expect(asked.area.longitude == Self.centre.longitude)
        #expect(asked.area.radiusMeters == Self.radiusMeters)
        #expect(asked.limit == Self.page)
        #expect(merged.cloudKit.recording.nearbyRequests.count == 1)
    }
}

// MARK: - Nearest first across both halves

extension MergedCommunityTransportTests {
    /// The list has to read as one answer to one question. Two answers
    /// stacked — every published hike, then every curated route — would be a
    /// list whose second half is nearer than its first, which is the one thing
    /// a *nearby* list may not be.
    ///
    /// Both sources already sort this way internally; what this pins is the
    /// interleave *between* them, which nothing but the merge decides.
    @Test("the merged list is nearest first across both halves")
    func theTwoHalvesInterleaveByDistance() async throws {
        let merged = Self.merged(
            published: [
                Self.published("nearest-published", metresNorth: Offset.nearest),
                Self.published("far-published", metresNorth: Offset.far),
            ],
            curated: [
                Self.trail(Relation.wimbach, named: "Wimbachweg", metresNorth: Offset.near),
                Self.trail(Relation.almbach, named: "Almbachweg", metresNorth: Offset.farthest),
            ]
        )

        let rows = try await Self.nearby(merged)

        #expect(
            rows.map(\.id) == [
                "nearest-published",
                CommunityIdentity.curated(relationID: Relation.wimbach),
                "far-published",
                CommunityIdentity.curated(relationID: Relation.almbach),
            ]
        )
    }
}

// MARK: - A curated id must never reach CloudKit

extension MergedCommunityTransportTests {
    /// Routing is on the id's prefix, and the assertion that matters is the
    /// negative one: CloudKit was not asked. A curated id handed to
    /// ``CloudKitCommunityTransport`` becomes a `CKRecord.ID` built out of a
    /// name nobody chose, so "it happened to fail" is not good enough — it has
    /// to not be attempted.
    @Test("opening a curated route never asks CloudKit about it")
    func curatedDetailNeverReachesCloudKit() async throws {
        let trail = Self.trail(Relation.wimbach, named: "Wimbachweg", metresNorth: Offset.nearest)
        let merged = Self.merged(curated: [trail])
        let listing = CommunityListing(curated: trail, editedAt: .now)

        let detail = try await merged.transport.detail(for: listing, downloadingInto: Self.downloads)

        #expect(merged.cloudKit.recording.detailRequests.isEmpty)
        #expect(merged.overpass.recording.trailRequests == [Relation.wimbach])
        #expect(detail.listing.id == listing.id)
        #expect(detail.route.count == trail.route.count)
        // OSM's `description` on a route relation is the list of places it
        // passes, which is what the hike screen's *Details* row is for — and
        // nothing was downloaded to get it.
        #expect(detail.trackDescription == Self.waymarkedTags["description"])
        #expect(detail.photoFileURLs.isEmpty)
        #expect(detail.photosOnRecord == 0)
    }

    /// The same guard read the other way. A record name that reached Overpass
    /// would be a query for a relation id that is somebody's UUID, which is
    /// not a failure anybody could diagnose from the screen it happened on.
    @Test("opening a published hike never asks Overpass about it")
    func publishedDetailNeverReachesOverpass() async throws {
        let listing = Self.published("listing-a", metresNorth: Offset.nearest)
        let merged = Self.merged(published: [listing])
        merged.cloudKit.detailResult = .success(Self.detail(of: listing))

        _ = try await merged.transport.detail(for: listing, downloadingInto: Self.downloads)

        #expect(merged.cloudKit.recording.detailRequests == ["listing-a"])
        #expect(merged.overpass.recording.trailRequests.isEmpty)
    }

    /// An OSM relation id is stable but not permanent — routes are split,
    /// merged and deleted — so a hike opened from a list fetched minutes ago
    /// can simply not be there. That is the same sentence a taken-down
    /// published hike gets, which is the point: the hiker is told the hike is
    /// gone, not that something went wrong.
    @Test("a curated route OSM no longer has is gone rather than empty")
    func aMissingRelationIsNoLongerAvailable() async {
        let trail = Self.trail(Relation.wimbach, named: "Wimbachweg", metresNorth: Offset.nearest)
        // Seeded with nothing, so the source knows no relation at all.
        let merged = Self.merged()
        let listing = CommunityListing(curated: trail, editedAt: .now)

        await #expect(throws: CommunityFailure.noLongerAvailable) {
            try await merged.transport.detail(for: listing, downloadingInto: Self.downloads)
        }
        #expect(merged.cloudKit.recording.detailRequests.isEmpty)
    }

    /// The write path this rule was written for. ``CloudKitCommunityTransport``
    /// builds record ids out of a listing's two names and deletes them, so
    /// forwarding a curated listing is at best a failure and at worst a
    /// deletion of whatever was named alike. The refusal is asserted together
    /// with the silence: a throw that had already sent the delete would look
    /// identical from the caller's side.
    @Test("a curated route cannot be taken down, and no delete is attempted")
    func takingDownACuratedRouteIsRefused() async {
        let trail = Self.trail(Relation.wimbach, named: "Wimbachweg", metresNorth: Offset.nearest)
        let merged = Self.merged(curated: [trail])
        let listing = CommunityListing(curated: trail, editedAt: .now)

        await #expect(throws: CommunityFailure.notPermitted) {
            try await merged.transport.takeDown(listing)
        }
        #expect(merged.cloudKit.recording.takenDown.isEmpty)
    }

    /// The guard must not have cost the reviewer the action it is a guard on.
    @Test("a published hike is still taken down")
    func takingDownAPublishedHikeForwards() async throws {
        let merged = Self.merged()

        try await merged.transport.takeDown(Self.published("listing-a", metresNorth: Offset.nearest))

        #expect(merged.cloudKit.recording.takenDown == ["listing-a"])
    }
}

// MARK: - Lines for both kinds, in one answer

extension MergedCommunityTransportTests {
    /// The map draws one array of lines, so the two kinds have to arrive in
    /// one dictionary keyed the same way. The second assertion is the load
    /// bearing one: CloudKit is asked about its own ids and *only* its own, so
    /// a page of mixed rows costs exactly one request and it carries nothing
    /// Overpass minted.
    @Test("one dictionary answers for both kinds, and CloudKit sees only its own ids")
    func outlinesAnswerForBothKinds() async throws {
        let trail = Self.trail(Relation.wimbach, named: "Wimbachweg", metresNorth: Offset.near)
        let publishedListing = Self.published("listing-a", metresNorth: Offset.nearest)
        let curatedListing = CommunityListing(curated: trail, editedAt: .now)
        let merged = Self.merged(published: [publishedListing], curated: [trail])
        merged.cloudKit.outlinesResult = .success([
            "listing-a": [
                RouteCoordinate(latitude: Self.centre.latitude, longitude: Self.centre.longitude),
                RouteCoordinate(latitude: Self.centre.latitude, longitude: Self.centre.longitude),
            ],
        ])

        let outlines = try await merged.transport.outlines(for: [publishedListing, curatedListing])

        #expect(Set(outlines.keys) == ["listing-a", curatedListing.id])
        #expect(merged.cloudKit.recording.outlineRequests == [["listing-a"]])
        #expect(outlines[curatedListing.id]?.count == trail.route.count)
    }

    /// A curated listing only exists because its line was already fetched, so
    /// drawing a page of them is a cache read rather than a request. A version
    /// that asked CloudKit for lines it could never hold would spend a public
    /// database round trip per pan for a dictionary that always came back
    /// empty.
    @Test("a page of curated routes costs no CloudKit request at all")
    func curatedOnlyOutlinesAskNothing() async throws {
        let trail = Self.trail(Relation.wimbach, named: "Wimbachweg", metresNorth: Offset.nearest)
        let merged = Self.merged(curated: [trail])
        let listing = CommunityListing(curated: trail, editedAt: .now)

        let outlines = try await merged.transport.outlines(for: [listing])

        #expect(merged.cloudKit.recording.outlineRequests.isEmpty)
        #expect(outlines[listing.id]?.count == trail.route.count)
    }

    /// The comment above used to say the curated half *needs no request at
    /// all*, and a loop of single lookups made that true only while every line
    /// happened to be cached. A long browse evicts entries and a saved link
    /// arrives with no search before it — and then a page of pins was one
    /// Overpass round trip each, at up to thirty seconds of server timeout
    /// apiece, from a path documented as a cache read.
    @Test("a page of curated pins is one question, not one per pin")
    func curatedOutlinesAreAskedInOneGo() async throws {
        let trails = (0..<Self.page).map { index in
            Self.trail(Relation.base + Int64(index), named: "Weg \(index)", metresNorth: Offset.near)
        }
        let merged = Self.merged(curated: trails)
        let listings = trails.map { CommunityListing(curated: $0, editedAt: .now) }

        let outlines = try await merged.transport.outlines(for: listings)

        #expect(outlines.count == Self.page)
        #expect(
            merged.overpass.recording.trailRequests == trails.map(\.relationID),
            "every relation, asked once, in one call"
        )
    }

    /// Partial by contract on both sides, which is what keeps one half's
    /// failure from clearing the other's lines off the map.
    @Test("CloudKit failing costs its own lines and not the curated ones")
    func aFailedPublishedOutlineLeavesTheCuratedLines() async throws {
        let trail = Self.trail(Relation.wimbach, named: "Wimbachweg", metresNorth: Offset.near)
        let publishedListing = Self.published("listing-a", metresNorth: Offset.nearest)
        let curatedListing = CommunityListing(curated: trail, editedAt: .now)
        let merged = Self.merged(published: [publishedListing], curated: [trail])
        merged.cloudKit.outlinesResult = .failure(.unreachable)

        let outlines = try await merged.transport.outlines(for: [publishedListing, curatedListing])

        #expect(outlines["listing-a"] == nil)
        #expect(outlines[curatedListing.id]?.count == trail.route.count)
    }
}

// MARK: - Everything only a published hike has

extension MergedCommunityTransportTests {
    /// The reviewer's whole screen goes through the composite now, so a
    /// forwarding mistake here would not be a wrong answer — it would be a
    /// review queue that had silently stopped working, on the one account that
    /// can publish anything.
    ///
    /// Asserted as one test rather than six because what is being pinned is a
    /// single property of the type — that these pass through untouched — and
    /// six tests that each set up a composite to call one method would say it
    /// six times and check it once each.
    @Test("the reviewer's methods forward unchanged, and ask Overpass nothing")
    func reviewerMethodsForward() async throws {
        let merged = Self.merged()
        let pending = CommunityPendingSubmission.stub()
        merged.cloudKit.pendingResult = .success([pending])
        merged.cloudKit.detailResult = .success(
            Self.detail(of: Self.published("listing-a", metresNorth: Offset.nearest))
        )

        let queue = try await merged.transport.pendingSubmissions()
        _ = try await merged.transport.detail(ofPending: pending, downloadingInto: Self.downloads)
        try await merged.transport.keepOnlyPhotos([], of: pending, staging: Self.downloads)
        _ = try await merged.transport.publish(pending)
        try await merged.transport.decline(pending)

        #expect(queue == [pending])
        #expect(merged.cloudKit.recording.queueRequests == 1)
        #expect(merged.cloudKit.recording.pendingDetailRequests == [pending.submissionID])
        #expect(merged.cloudKit.recording.photoEdits.map(\.submissionID) == [pending.submissionID])
        #expect(merged.cloudKit.recording.published == [pending])
        #expect(merged.cloudKit.recording.declined == [pending])
        #expect(merged.overpass.recording.isQuiet)
    }

    /// Sharing a hike and asking what became of it are CloudKit's alone and
    /// need no routing: the only id ever passed to a publication check is the
    /// hiker's own ``Hike/communitySubmissionID``, which is a record name by
    /// construction because nothing but a submission of theirs writes it.
    @Test("sharing a hike and checking on it are CloudKit's alone")
    func submissionMethodsForward() async throws {
        let merged = Self.merged()
        let draft = SeededCommunityFixture.draft()

        let submissionID = try await merged.transport.submit(draft)
        let publication = try await merged.transport.publication(of: submissionID)

        #expect(merged.cloudKit.recording.submissions.map(\.title) == [draft.title])
        #expect(merged.cloudKit.recording.publicationChecks == [submissionID])
        #expect(publication == nil, "nothing is published until a reviewer publishes it")
        #expect(merged.overpass.recording.isQuiet)
    }
}

// MARK: - Overpass is asked only when the question asks for it

extension MergedCommunityTransportTests {
    /// The rule this scope exists for, asserted where it is decided. It cannot
    /// be seen in the rows — a published-only answer and a curated one with
    /// nothing near the centre are the same list — so the claim is that the
    /// source was never spoken to at all.
    @Test("a published-only question never reaches Overpass")
    func publishedOnlyLeavesTheCuratedSourceQuiet() async throws {
        let merged = Self.merged(
            published: [Self.published("listing-a", metresNorth: Offset.near)],
            curated: [Self.trail(Relation.wimbach, named: "Wimbachgries", metresNorth: Offset.nearest)]
        )

        let answer = try await Self.answer(merged, scope: .publishedOnly)

        #expect(answer.listings.map(\.id) == ["listing-a"])
        #expect(answer.curatedOutage == nil, "nothing was asked, so there is nothing to report")
        #expect(merged.overpass.recording.isQuiet)
        #expect(merged.cloudKit.recording.nearbyRequests.count == 1)
    }

    /// The same question with the scope the button asks with, so the test
    /// above is about the scope rather than about a fixture that had nothing
    /// in it.
    @Test("the curated question reaches both halves")
    func curatedScopeAsksBoth() async throws {
        let merged = Self.merged(
            published: [Self.published("listing-a", metresNorth: Offset.near)],
            curated: [Self.trail(Relation.wimbach, named: "Wimbachgries", metresNorth: Offset.nearest)]
        )

        let answer = try await Self.answer(merged, scope: .withCuratedTrails)

        #expect(answer.listings.count == 2)
        #expect(!merged.overpass.recording.isQuiet)
    }
}

// MARK: - A refused curated half is reported, not thrown

extension MergedCommunityTransportTests {
    /// The failure this reporting exists against: a `429` used to reach the
    /// log and nowhere else, so a rate-limited hiker saw a list with no trails
    /// in it and nothing to tell that apart from an area with none.
    @Test("a rate-limited listing pass is carried back beside the rows")
    func aRateLimitedListingPassIsReported() async throws {
        let merged = Self.merged(
            published: [Self.published("listing-a", metresNorth: Offset.near)]
        )
        merged.overpass.nearbyResult = .failure(.rateLimited(retryAfter: 60))

        let answer = try await Self.answer(merged)

        #expect(answer.curatedOutage == .rateLimited(retryAfter: 60))
        #expect(
            answer.listings.map(\.id) == ["listing-a"],
            "one source failing is still not the answer failing"
        )
    }

    /// Everything else Overpass can do, which is the state a hiker with no
    /// signal is in. Still not a failure of the request: the published half
    /// answered.
    @Test("any other curated failure is reported as unavailable")
    func anotherCuratedFailureIsReported() async throws {
        let merged = Self.merged(
            published: [Self.published("listing-a", metresNorth: Offset.near)]
        )
        merged.overpass.nearbyResult = .failure(.server(statusCode: 504))

        let answer = try await Self.answer(merged)

        #expect(answer.curatedOutage == .unavailable)
        #expect(answer.listings.map(\.id) == ["listing-a"])
    }

    /// The happy answer says nothing, including for an area that genuinely has
    /// no waymarked routes in it — which is most of the world, and is not
    /// something to caption a button with.
    @Test("a curated half that answered reports no outage")
    func aGoodCuratedHalfReportsNothing() async throws {
        let merged = Self.merged(
            published: [Self.published("listing-a", metresNorth: Offset.near)]
        )

        let answer = try await Self.answer(merged)

        #expect(answer.curatedOutage == nil)
    }
}

// MARK: - The curated half's stand-in

/// What the curated half answers instead of Overpass.
///
/// A stub for the reason ``StubCommunityTransport`` is one, and a sharper one:
/// the real conformance reaches a **volunteer-run** public API on a quota
/// shared by every copy of this app, over which a test suite has no claim at
/// all. See ``CuratedTrailSourcing``.
///
/// `final class` behind a `Mutex` rather than an actor, for the same reason
/// the published stub is one: the protocol's requirements are `@concurrent`,
/// so calls genuinely arrive off the main actor, and an actor would turn every
/// recording read in a test into a suspension point the next request could
/// overtake.
private final class StubCuratedTrailSource: CuratedTrailSourcing, @unchecked Sendable {
    struct Recording: Sendable {
        /// The areas a nearby search asked about and the limit each carried.
        /// What proves the composite hands this half the same question it
        /// hands CloudKit rather than one of its own devising.
        var areaRequests: [(area: CommunitySearchArea, limit: Int)] = []
        var titleQueries: [String] = []
        /// The relations a per-route request asked about, in order. What
        /// proves a CloudKit record name never arrives here.
        var trailRequests: [Int64] = []
        /// How many routes each geometry pass was asked to complete. The
        /// expensive half of a search, and the one the published rows are
        /// supposed to have already spent the limit on.
        var completionSizes: [Int] = []

        /// Whether this source was asked nothing at all — the assertion every
        /// published-only path in this file ends on.
        var isQuiet: Bool {
            areaRequests.isEmpty && titleQueries.isEmpty && trailRequests.isEmpty
                && completionSizes.isEmpty
        }
    }

    /// What an area search answers. A failure is Overpass refusing — a `429`,
    /// or an overloaded server's HTML page — which is the ordinary condition
    /// the merge is built to survive rather than an exotic one.
    var nearbyResult: Result<[CuratedTrail], TrailGraphProviderError> = .success([])

    /// Every route this source knows, by relation. A relation absent from here
    /// is one OSM no longer has, which is a real and unremarkable state: ids
    /// are stable but not permanent.
    private var known: [Int64: CuratedTrail] = [:]
    private let trails: [CuratedTrail]
    private let state = Mutex(Recording())

    var recording: Recording { state.withLock { $0 } }

    init(trails: [CuratedTrail] = []) {
        self.trails = trails
        nearbyResult = .success(trails)
        known = Dictionary(uniqueKeysWithValues: trails.map { ($0.relationID, $0) })
    }

    /// Honours `limit` rather than merely recording it, because the real
    /// source does — it never asks for geometry beyond
    /// ``CuratedTrailQuery/geometryBatchLimit`` — and the merge's own split has
    /// to be shown doing its work on top of that rather than instead of it.
    @concurrent
    func listings(near area: CommunitySearchArea, limit: Int) async throws -> [CuratedTrail] {
        state.withLock { $0.areaRequests.append((area: area, limit: limit)) }
        await Task.yield()
        let answer = try nearbyResult.get()
        return Array(answer.prefix(max(0, limit)))
    }

    /// Records how many rows the expensive pass was asked about, which is the
    /// whole point of the pass being separate. The rows come back unchanged:
    /// the stub's trails already carry their lines, and what is under test
    /// here is the size of the question rather than the answer to it.
    @concurrent
    func completed(_ listed: [CuratedTrail]) async -> [CuratedTrail] {
        state.withLock { $0.completionSizes.append(listed.count) }
        await Task.yield()
        return listed
    }

    /// Filters by name the way the real source does, so a query written in a
    /// test has to be one that could actually match — a stub that answered
    /// everything would let a merge that never passed the query along look
    /// correct.
    @concurrent
    func trails(matching query: String, limit: Int) async -> [CuratedTrail] {
        state.withLock { $0.titleQueries.append(query) }
        await Task.yield()
        let needle = query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .localizedLowercase
        guard !needle.isEmpty, limit > 0 else { return [] }
        let hits = trails.filter { $0.name.localizedLowercase.contains(needle) }
        return Array(hits.prefix(limit))
    }

    @concurrent
    func trails(of relationIDs: [Int64]) async -> [Int64: CuratedTrail] {
        state.withLock { $0.trailRequests.append(contentsOf: relationIDs) }
        await Task.yield()
        return known.filter { relationIDs.contains($0.key) }
    }
}
