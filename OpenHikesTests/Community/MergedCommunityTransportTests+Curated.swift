//
//  MergedCommunityTransportTests+Curated.swift
//  OpenHikesTests
//
//  What the curated half costs, and what it says when OpenStreetMap will not
//  answer.
//
//  An extension of `MergedCommunityTransportTests` in a file of its own rather
//  than a suite of its own, for the reason `CloudKitCommunityTransport+Reviewing`
//  is split from its sibling: this is the same type under test with the same
//  two stubs behind it, and the file it came from is at the length limit. What
//  separates the two halves is the question being asked — that one is about the
//  merge, this one is about the *cost* of asking and the sentence a refusal
//  turns into, neither of which is visible in the rows.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import Synchronization
import Testing

// MARK: - Overpass is asked only when the question asks for it

extension MergedCommunityTransportTests {
    /// The rule this scope exists for, asserted where it is decided. It cannot
    /// be seen in the rows — a published-only answer and a curated one with
    /// nothing near the centre are the same list — so the claim is that the
    /// source was never spoken to at all.
    @Test("a published-only question never reaches Overpass")
    func publishedOnlyLeavesTheCuratedSourceQuiet() async throws {
        let merged = Self.merged(
            published: [Self.published("listing-a", metersNorth: Offset.near)],
            curated: [Self.trail(Relation.wimbach, named: "Wimbachgries", metersNorth: Offset.nearest)]
        )

        let answer = try await Self.answer(merged, scope: .publishedOnly)

        #expect(answer.listings.map(\.id) == ["listing-a"])
        #expect(answer.curated == .notAsked, "nothing was asked, so there is nothing to report")
        #expect(merged.overpass.recording.isQuiet)
        #expect(merged.cloudKit.recording.nearbyRequests.count == 1)
    }

    /// The same question with the scope the button asks with, so the test
    /// above is about the scope rather than about a fixture that had nothing
    /// in it.
    @Test("the curated question reaches both halves")
    func curatedScopeAsksBoth() async throws {
        let merged = Self.merged(
            published: [Self.published("listing-a", metersNorth: Offset.near)],
            curated: [Self.trail(Relation.wimbach, named: "Wimbachgries", metersNorth: Offset.nearest)]
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
            published: [Self.published("listing-a", metersNorth: Offset.near)]
        )
        merged.overpass.nearbyResult = .failure(.rateLimited(retryAfter: 60))

        let answer = try await Self.answer(merged)

        #expect(answer.curated == .outage(.rateLimited(retryAfter: 60)))
        #expect(
            answer.listings.map(\.id) == ["listing-a"],
            "one source failing is still not the answer failing"
        )
    }

    /// A gateway refusing in front of a busy Overpass, which is the measured
    /// shape of a public instance under load. Still not a failure of the
    /// request: the published half answered.
    ///
    /// *Busy* rather than *unavailable*, because the two send the hiker to
    /// different places — see ``CuratedTrailOutage/busy``.
    @Test("a gateway refusal is reported as a busy server")
    func aGatewayRefusalIsReported() async throws {
        let merged = Self.merged(
            published: [Self.published("listing-a", metersNorth: Offset.near)]
        )
        merged.overpass.nearbyResult = .failure(.server(statusCode: 504))

        let answer = try await Self.answer(merged)

        #expect(answer.curated == .outage(.busy))
        #expect(answer.listings.map(\.id) == ["listing-a"])
    }

    /// Everything else Overpass can do, which is the state a hiker with no
    /// signal is in. Still not a failure of the request: the published half
    /// answered.
    @Test("any other curated failure is reported as unavailable")
    func anotherCuratedFailureIsReported() async throws {
        let merged = Self.merged(
            published: [Self.published("listing-a", metersNorth: Offset.near)]
        )
        merged.overpass.nearbyResult = .failure(.invalidResponse)

        let answer = try await Self.answer(merged)

        #expect(answer.curated == .outage(.unavailable))
        #expect(answer.listings.map(\.id) == ["listing-a"])
    }

    /// The happy answer reports what it found, and the count is the listing
    /// pass's rather than the page's — see ``CuratedTrailOutcome/trails(_:)``.
    @Test("a curated half that answered reports what it listed")
    func aGoodCuratedHalfReportsItsCount() async throws {
        let merged = Self.merged(
            published: [Self.published("listing-a", metersNorth: Offset.near)],
            curated: [
                Self.trail(Relation.wimbach, named: "Wimbachgries", metersNorth: Offset.nearest),
                Self.trail(Relation.almbach, named: "Almbachklamm", metersNorth: Offset.near),
            ]
        )

        let answer = try await Self.answer(merged)

        #expect(answer.curated == .trails(2))
    }

    /// The answer that used to be indistinguishable from the one above, and
    /// which is most of the world: Overpass answered, and there is nothing
    /// waymarked near there. A count rather than a failure, because nothing
    /// failed — what it buys is the one caption a hiker can act on, and the
    /// button is the way to act on it. See ``CuratedTrailNotice``.
    @Test("an area with no waymarked routes reports none rather than a refusal")
    func anEmptyAreaReportsNoTrails() async throws {
        let merged = Self.merged(
            published: [Self.published("listing-a", metersNorth: Offset.near)]
        )

        let answer = try await Self.answer(merged)

        #expect(answer.curated == .trails(0))
        #expect(answer.listings.map(\.id) == ["listing-a"], "the published half is untouched")
    }

    /// **The page the listing pass paid for, when the geometry pass is
    /// refused.** One search spends two of the handful of slots an address
    /// gets, so this is the ordinary shape of a rate limit rather than an
    /// exotic one — and the rows are real trails the cheap pass already found.
    /// They arrive without their lines and with the refusal beside them; the
    /// caption says so, and opening one fetches its line.
    @Test("a refused geometry pass still answers with the listed rows")
    func aRefusedGeometryPassStillAnswers() async throws {
        let merged = Self.merged(
            published: [Self.published("listing-a", metersNorth: Offset.far)],
            curated: [
                Self.trail(Relation.wimbach, named: "Wimbachgries", metersNorth: Offset.nearest),
                Self.trail(Relation.almbach, named: "Almbachklamm", metersNorth: Offset.near),
            ]
        )
        merged.overpass.geometryResult = .refused(.rateLimited(retryAfter: 60))

        let answer = try await Self.answer(merged)

        #expect(
            answer.listings.count == 3,
            "the published hike and both listed routes, lines or no lines"
        )
        #expect(
            answer.listings.filter(\.isCurated).allSatisfy { $0.drawnDistanceMeters == nil },
            "a row with no line has no length, and says nothing rather than zero"
        )
        #expect(answer.curated == .outage(.rateLimited(retryAfter: 60)))
    }

    /// The geometry pass failing outright — a conformance that throws, or a
    /// search superseded mid-pass — is still the older, emptier answer: there
    /// are no rows to keep, because nothing came back to keep them from.
    @Test("a geometry pass that throws leaves the published half standing")
    func aThrownGeometryPassLeavesThePublishedHalf() async throws {
        let merged = Self.merged(
            published: [Self.published("listing-a", metersNorth: Offset.near)],
            curated: [Self.trail(Relation.wimbach, named: "Wimbachgries", metersNorth: Offset.nearest)]
        )
        merged.overpass.geometryResult = .thrown(TrailGraphProviderError.invalidResponse)

        let answer = try await Self.answer(merged)

        #expect(answer.listings.map(\.id) == ["listing-a"])
        #expect(answer.curated == .outage(.unavailable))
    }

    /// What a refused search draws instead of nothing: the routes this device
    /// downloaded the last time it was asked about somewhere near here.
    @Test("a refused search falls back to the routes already on the device")
    func aRefusedSearchDrawsWhatIsAlreadyHere() async throws {
        let merged = Self.merged(
            published: [Self.published("listing-a", metersNorth: Offset.far)]
        )
        merged.overpass.nearbyResult = .failure(.rateLimited(retryAfter: 60))
        merged.overpass.storedTrails = [
            Self.trail(Relation.wimbach, named: "Wimbachgries", metersNorth: Offset.nearest),
        ]

        let answer = try await Self.answer(merged)

        #expect(answer.listings.count == 2, "the stored route stands beside the published hike")
        #expect(
            merged.overpass.recording.cacheReads.count == 1,
            "the device's own routes are read once, for the area that was refused"
        )
    }

    /// And it is still an outage. The rows are whatever happens to be on the
    /// device — there is no record of whether that is the area's trails or
    /// four of them — so the caption under the button stays up.
    @Test("falling back does not clear the outage")
    func fallingBackKeepsTheOutage() async throws {
        let merged = Self.merged()
        merged.overpass.nearbyResult = .failure(.rateLimited(retryAfter: 60))
        merged.overpass.storedTrails = [
            Self.trail(Relation.wimbach, named: "Wimbachgries", metersNorth: Offset.nearest),
        ]

        let answer = try await Self.answer(merged)

        #expect(answer.curated == .outage(.rateLimited(retryAfter: 60)))
        #expect(!answer.listings.isEmpty)
    }

    /// A search that was never refused does not read the device's own routes,
    /// because Overpass answered — and the answer is the answer.
    @Test("a search that worked never falls back")
    func aGoodSearchDoesNotFallBack() async throws {
        let merged = Self.merged(
            curated: [Self.trail(Relation.almbach, named: "Almbachklamm", metersNorth: Offset.near)]
        )
        merged.overpass.storedTrails = [
            Self.trail(Relation.wimbach, named: "Wimbachgries", metersNorth: Offset.nearest),
        ]

        let answer = try await Self.answer(merged)

        #expect(answer.listings.count == 1)
        #expect(merged.overpass.recording.cacheReads.isEmpty)
    }

    /// A search over ground the hiker downloaded that reaches past the
    /// download, with no signal: the download's routes are the part, and
    /// the routes kept from earlier searches are not drawn in their place.
    @Test("a listing that answered for part of the area draws that part, and says some may be missing")
    func aPartialListingIsDrawnWithItsGap() async throws {
        let merged = Self.merged(
            published: [Self.published("listing-a", metersNorth: Offset.far)],
            curated: [Self.trail(Relation.almbach, named: "Almbachklamm", metersNorth: Offset.near)]
        )
        merged.overpass.listingGap = .unavailable
        merged.overpass.storedTrails = [
            Self.trail(Relation.wimbach, named: "Wimbachgries", metersNorth: Offset.nearest),
        ]

        let answer = try await Self.answer(merged)

        #expect(answer.listings.count == 2, "the part stands beside the published hike")
        #expect(answer.listings.compactMap(\.relationID) == [Relation.almbach], "and not what an earlier search kept")
        #expect(answer.curated == .partial(.unavailable))
        #expect(answer.curated.notice == .incomplete(.unavailable))
        #expect(merged.overpass.recording.cacheReads.isEmpty)
    }

    /// The squares that were read hold no routes, and the one that was not
    /// holds a route an earlier search kept. With CloudKit out too, an
    /// empty part would leave nothing to draw, and the answer would fail.
    @Test("a part with no routes in it draws the routes already on the device, and stays a part")
    func anEmptyPartFallsBack() async throws {
        let merged = Self.merged()
        merged.cloudKit.listingsResult = .failure(.unreachable)
        merged.overpass.listingGap = .unavailable
        merged.overpass.storedTrails = [
            Self.trail(Relation.wimbach, named: "Wimbachgries", metersNorth: Offset.nearest),
        ]

        let answer = try await Self.answer(merged)

        #expect(answer.listings.compactMap(\.relationID) == [Relation.wimbach])
        #expect(answer.curated == .partial(.unavailable), "the stored rows are no whole answer either")
        #expect(merged.overpass.recording.cacheReads.count == 1)
    }

    // MARK: The heights OpenStreetMap does not have

    /// A curated route opens without waiting for its heights: they are
    /// squares off the tile server, and on a poor connection that request can
    /// run for its whole budget. The detail hands over the line as it came,
    /// and asks the source nothing.
    @Test("opening a curated route does not wait for its heights")
    func openingACuratedRouteAsksNoHeights() async throws {
        let trail = Self.trail(Relation.wimbach, named: "Wimbachgries", metersNorth: Offset.nearest)
        let source = StubElevationSource(height: 642)
        let merged = Self.merged(curated: [trail], elevation: source)

        let detail = try await merged.transport.detail(
            for: CommunityListing(curated: trail, editedAt: .now),
            downloadingInto: FileManager.default.temporaryDirectory
        )

        #expect(detail.route == trail.route, "the line itself is the one Overpass assembled")
        #expect(source.requestCount == 0)
    }

    /// And the heights are asked for once it is on screen, on that line, once.
    @Test("a curated route's heights are filled in once it is open")
    func curatedHeightsAreFilledIn() async {
        let trail = Self.trail(Relation.wimbach, named: "Wimbachgries", metersNorth: Offset.nearest)
        let source = StubElevationSource(height: 642)
        let merged = Self.merged(curated: [trail], elevation: source)

        let filled = await merged.transport.filledHeights(
            of: trail.route,
            for: CommunityListing(curated: trail, editedAt: .now)
        )

        #expect(filled.map(\.latitude) == trail.route.map(\.latitude), "the line itself is untouched")
        #expect(filled.allSatisfy { $0.elevation == 642 })
        #expect(source.requestCount == 1)
    }

    /// And a source that will not answer costs the chart and nothing else. The
    /// route, the length, the facts and the surface are all already in hand,
    /// and a hike that opens without a profile is what this screen did before
    /// heights existed.
    @Test("a refused height request leaves the route as it came")
    func refusedHeightsAddNothing() async {
        let trail = Self.trail(Relation.almbach, named: "Almbachklamm", metersNorth: Offset.near)
        let merged = Self.merged(curated: [trail], elevation: StubElevationSource(height: nil))

        let filled = await merged.transport.filledHeights(
            of: trail.route,
            for: CommunityListing(curated: trail, editedAt: .now)
        )

        #expect(filled == trail.route)
    }

    /// The default nobody has to remember: a composite built without an
    /// elevation source reaches no server. Every suite in this file relies on
    /// it.
    @Test("a composite built without an elevation source asks nobody")
    func defaultCompositeAsksNobody() async {
        let trail = Self.trail(Relation.wimbach, named: "Wimbachgries", metersNorth: Offset.nearest)
        let merged = MergedCommunityTransport(
            published: StubCommunityTransport(),
            curated: StubCuratedTrailSource(trails: [trail])
        )

        let filled = await merged.filledHeights(
            of: trail.route,
            for: CommunityListing(curated: trail, editedAt: .now)
        )

        #expect(filled == trail.route)
    }

    /// A published hike's heights are the ones the hiker who walked it
    /// uploaded, and nothing here may go looking for others.
    @Test("a published hike asks no elevation source")
    func publishedHikeAsksNoElevationSource() async {
        let source = StubElevationSource(height: 642)
        let listing = Self.published("listing-a", metersNorth: Offset.near)
        let merged = Self.merged(published: [listing], elevation: source)

        _ = try? await merged.transport.detail(
            for: listing,
            downloadingInto: FileManager.default.temporaryDirectory
        )
        let route = [
            RouteCoordinate(latitude: 47.6, longitude: 12.9),
            RouteCoordinate(latitude: 47.61, longitude: 12.9),
        ]
        let filled = await merged.transport.filledHeights(of: route, for: listing)

        #expect(filled == route)
        #expect(source.requestCount == 0)
    }

    /// A published-only question has nothing to fall back *from*: nothing was
    /// asked of Overpass, so nothing was refused.
    @Test("a published-only question never reads the device's routes either")
    func publishedOnlyDoesNotFallBack() async throws {
        let merged = Self.merged(
            published: [Self.published("listing-a", metersNorth: Offset.near)]
        )
        merged.overpass.storedTrails = [
            Self.trail(Relation.wimbach, named: "Wimbachgries", metersNorth: Offset.nearest),
        ]

        let answer = try await Self.answer(merged, scope: .publishedOnly)

        #expect(answer.listings.map(\.id) == ["listing-a"])
        #expect(merged.overpass.recording.cacheReads.isEmpty)
    }
}

/// Heights that reached no server.
///
/// `height: nil` is the refusal — a square that would not come, a timeout, a
/// launch with no server.
nonisolated final class StubElevationSource: CuratedElevationSourcing, @unchecked Sendable {
    private let height: Double?
    private let requests = Mutex(0)

    var requestCount: Int { requests.withLock { $0 } }

    init(height: Double?) {
        self.height = height
    }

    @concurrent
    func heights(at coordinates: [CLLocationCoordinate2D]) async throws -> [Double] {
        requests.withLock { $0 += 1 }
        guard let height else { throw CuratedElevationFailure.uncovered }
        return coordinates.map { _ in height }
    }
}
