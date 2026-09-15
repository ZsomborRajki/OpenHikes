//
//  CuratedTrailSourceTests.swift
//  OpenHikesTests
//
//  What the curated source asks Overpass, and — mostly — what it does not.
//
//  Every assertion here is about a *request*: how many were made, in what
//  order, and carrying what. That is deliberate rather than lazy. The two
//  expensive decisions in this feature are invisible in the result — the
//  listing pass is cheap only because it carries no geometry, and the cache is
//  worth having only if a second search does not re-ask — so a suite that
//  checked the rows alone would pass just as happily against a version that
//  downloaded seven megabytes per pan.
//
//  The transport and the clock are injected for the reason the repository's
//  *Deliberate test seams* section gives: a volunteer-run public API is the
//  last service to reach from a test bundle, and a rate-limit back-off is only
//  observable against a clock somebody else is holding.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Testing

/// Records every request and answers each with the next queued response.
///
/// An actor because ``CuratedTrailSource``'s transport is `@Sendable` and
/// genuinely called off the main actor — the same shape
/// `OverpassTrailGraphProviderTests` uses for its own recorder.
private actor CuratedTransportStub {
    /// What a queue that has run dry answers with: a success carrying nothing,
    /// so an unexpected extra request fails on its empty body rather than on a
    /// status code and says which request was unexpected.
    private static let httpOK = 200

    private(set) var bodies: [String] = []
    private var responses: [OverpassHTTPResponse]

    init(responses: [OverpassHTTPResponse]) {
        self.responses = responses
    }

    var requestCount: Int { bodies.count }

    func answer(_ request: URLRequest) -> OverpassHTTPResponse {
        bodies.append(Self.query(of: request))
        guard !responses.isEmpty else {
            return OverpassHTTPResponse(data: Data(), statusCode: Self.httpOK, headers: [:])
        }
        return responses.removeFirst()
    }

    /// The Overpass query out of a form-encoded body, so an assertion can read
    /// what was actually asked rather than a percent-encoded blob.
    private static func query(of request: URLRequest) -> String {
        guard let body = request.httpBody,
              let encoded = String(data: body, encoding: .utf8)
        else { return "" }
        var components = URLComponents()
        components.percentEncodedQuery = encoded
        return components.queryItems?.first { $0.name == "data" }?.value ?? ""
    }
}

@Suite("Curated trail source")
struct CuratedTrailSourceTests {
    // MARK: - Fixtures

    private static let centre = CLLocationCoordinate2D(latitude: 47.62, longitude: 12.97)
    private static let searchRadius: Double = 10_000

    private static var area: CommunitySearchArea {
        CommunitySearchArea(coordinate: centre, radiusMeters: searchRadius)
    }

    /// Two named day-hike relations and one continental path, which is what
    /// the day-hike filter exists to throw out — see
    /// ``CuratedTrailQuery/maximumSpanMeters``.
    private static let listingBody = """
    {"elements":[
        {"type":"relation","id":11,"tags":{"name":"Near Loop","route":"hiking","roundtrip":"yes"},
        "bounds":{"minlat":47.620,"minlon":12.970,"maxlat":47.628,"maxlon":12.980}},
        {"type":"relation","id":22,"tags":{"name":"Far Path","route":"hiking"},
        "bounds":{"minlat":47.700,"minlon":13.050,"maxlat":47.708,"maxlon":13.060}},
        {"type":"relation","id":33,"tags":{"name":"Continental Way","route":"hiking"},
        "bounds":{"minlat":45.000,"minlon":10.000,"maxlat":49.000,"maxlon":15.000}}
    ]}
    """

    /// Both day hikes, each a single two-point way — enough to assemble and to
    /// have a length, which is all the source reads.
    private static let geometryBody = """
    {"elements":[
        {"type":"relation","id":11,"tags":{"name":"Near Loop","route":"hiking","roundtrip":"yes"},
        "bounds":{"minlat":47.620,"minlon":12.970,"maxlat":47.628,"maxlon":12.980},
        "members":[{"type":"way","role":"","geometry":[
            {"lat":47.620,"lon":12.970},{"lat":47.628,"lon":12.980}]}]},
        {"type":"relation","id":22,"tags":{"name":"Far Path","route":"hiking"},
        "bounds":{"minlat":47.700,"minlon":13.050,"maxlat":47.708,"maxlon":13.060},
        "members":[{"type":"way","role":"","geometry":[
            {"lat":47.700,"lon":13.050},{"lat":47.708,"lon":13.060}]}]}
    ]}
    """

    /// The status code Overpass uses for an answer, including the HTML page
    /// it serves when it is too busy — see ``htmlServedAsSuccessIsTyped``.
    private static let httpOK = 200
    /// What Overpass sends when it wants to be left alone for a while.
    private static let httpRateLimited = 429

    private static func ok(_ json: String) -> OverpassHTTPResponse {
        OverpassHTTPResponse(
            data: Data(json.utf8),
            statusCode: httpOK,
            headers: [:]
        )
    }

    private static func makeSource(
        _ responses: [OverpassHTTPResponse],
        clock: TestClock = TestClock()
    ) -> (CuratedTrailSource, CuratedTransportStub) {
        let stub = CuratedTransportStub(responses: responses)
        let source = CuratedTrailSource(
            endpoint: URL(string: "https://overpass.invalid/api/interpreter")!,
            // ``TestClock/read`` rather than a closure of our own: the whole
            // point of the seam is that no suite waits on wall time, and the
            // bundle already has the clock that makes that true.
            clock: clock.read,
            transport: { await stub.answer($0) }
        )
        return (source, stub)
    }

    // MARK: - The two passes

    /// The shape the whole feature rests on: tags first, geometry second, and
    /// the second naming only what survived the filter. A version that asked
    /// for geometry over the box would pass every assertion about the rows and
    /// cost seven megabytes a pan.
    @Test("a search asks for tags first, then geometry for the survivors only")
    func twoPasses() async throws {
        let (source, stub) = Self.makeSource([
            Self.ok(Self.listingBody),
            Self.ok(Self.geometryBody),
        ])

        let trails = try await source.trails(near: Self.area, limit: 25)

        let bodies = await stub.bodies
        #expect(bodies.count == 2)
        #expect(bodies[0].contains("out tags bb"))
        #expect(bodies[0].contains("\"name\""))
        #expect(!bodies[0].contains("out geom"))
        #expect(bodies[1].contains("out geom"))
        // The continental path is not in the geometry request at all, which is
        // where the saving actually happens.
        #expect(bodies[1].contains("11"))
        #expect(bodies[1].contains("22"))
        #expect(!bodies[1].contains("33"))
        #expect(trails.map(\.relationID) == [11, 22])
    }

    /// Nearest first, because a merged list is ordered by one rule across both
    /// halves and this is the half that has to supply it.
    @Test("results are nearest first from the search centre")
    func nearestFirst() async throws {
        let (source, _) = Self.makeSource([
            Self.ok(Self.listingBody),
            Self.ok(Self.geometryBody),
        ])

        let trails = try await source.trails(near: Self.area, limit: 25)
        let distances = trails.map { trail in
            RouteGeometry.distanceMeters(from: Self.centre, to: trail.coordinate)
        }
        #expect(trails.first?.name == "Near Loop")
        #expect(distances == distances.sorted())
    }

    /// The honest answer for somebody looking at half a continent, and the one
    /// that costs a volunteer-run API nothing at all.
    @Test("an area too wide to ask about answers empty and sends no request")
    func tooWideSendsNothing() async throws {
        let (source, stub) = Self.makeSource([Self.ok(Self.listingBody)])
        let wide = CommunitySearchArea(
            coordinate: Self.centre,
            radiusMeters: CuratedTrailQuery.maximumRadiusMeters * 2
        )

        #expect(try await source.trails(near: wide, limit: 25).isEmpty)
        #expect(await stub.requestCount == 0)
    }

    /// A row whose length *is* its line's length cannot be drawn without one,
    /// so it is left out rather than shown as a name and a blank.
    @Test("a route whose geometry never arrives is dropped, not shown blank")
    func missingGeometryIsDropped() async throws {
        // Geometry for one of the two day hikes only.
        let partial = """
        {"elements":[
            {"type":"relation","id":11,"tags":{"name":"Near Loop","route":"hiking"},
                "bounds":{"minlat":47.620,"minlon":12.970,"maxlat":47.628,"maxlon":12.980},
                "members":[{"type":"way","role":"","geometry":[
                    {"lat":47.620,"lon":12.970},{"lat":47.628,"lon":12.980}]}]}
        ]}
        """
        let (source, _) = Self.makeSource([
            Self.ok(Self.listingBody),
            Self.ok(partial),
        ])

        let trails = try await source.trails(near: Self.area, limit: 25)
        #expect(trails.map(\.relationID) == [11])
    }

    @Test("the limit bounds how many routes geometry is fetched for")
    func limitBoundsTheGeometryPass() async throws {
        let (source, stub) = Self.makeSource([
            Self.ok(Self.listingBody),
            Self.ok(Self.geometryBody),
        ])

        let trails = try await source.trails(near: Self.area, limit: 1)
        #expect(trails.count == 1)
        let bodies = await stub.bodies
        #expect(bodies[1].contains("11"))
        #expect(!bodies[1].contains("22"))
    }

    // MARK: - The cache

    /// The cache is worth having only if it saves the *expensive* pass. The
    /// listing pass is asked again — the area's contents can have changed —
    /// and the geometry is not.
    @Test("a repeated search re-asks for tags but not for geometry")
    func cacheSavesTheGeometryPass() async throws {
        let (source, stub) = Self.makeSource([
            Self.ok(Self.listingBody),
            Self.ok(Self.geometryBody),
            Self.ok(Self.listingBody),
        ])

        _ = try await source.trails(near: Self.area, limit: 25)
        let afterFirst = await stub.requestCount
        _ = try await source.trails(near: Self.area, limit: 25)

        #expect(afterFirst == 2)
        #expect(await stub.requestCount == 3)
    }

    @Test("opening a route the list already fetched sends no request")
    func openingACachedRouteIsFree() async throws {
        let (source, stub) = Self.makeSource([
            Self.ok(Self.listingBody),
            Self.ok(Self.geometryBody),
        ])

        _ = try await source.trails(near: Self.area, limit: 25)
        let afterSearch = await stub.requestCount
        let trail = try await source.trail(of: 11)

        #expect(trail?.name == "Near Loop")
        #expect(await stub.requestCount == afterSearch)
    }

    /// The path a deep link or a stale row takes: the geometry pass is
    /// self-sufficient, carrying tags and bounds as well as the line.
    @Test("opening a route that was never listed fetches it whole")
    func openingAnUnknownRouteFetchesIt() async throws {
        let (source, stub) = Self.makeSource([Self.ok(Self.geometryBody)])

        let trail = try await source.trail(of: 22)

        #expect(trail?.name == "Far Path")
        #expect(trail?.tags["route"] == "hiking")
        #expect(trail?.route.count == 2)
        #expect(await stub.requestCount == 1)
    }

    // MARK: - Searching by name

    /// Overpass has no index to search the world by name — every query is
    /// bounded by an area — so this is not a question the source can be asked,
    /// and answering it locally is not an optimisation but the only honest
    /// reading of it.
    @Test("a title search filters the last answer and sends nothing")
    func titleSearchIsLocal() async throws {
        let (source, stub) = Self.makeSource([
            Self.ok(Self.listingBody),
            Self.ok(Self.geometryBody),
        ])

        _ = try await source.trails(near: Self.area, limit: 25)
        let afterSearch = await stub.requestCount
        let matches = await source.trails(matching: "near", limit: 25)

        #expect(matches.map(\.name) == ["Near Loop"])
        #expect(await stub.requestCount == afterSearch)
    }

    @Test("a title search before any area search answers empty")
    func titleSearchWithoutAnAreaIsEmpty() async {
        let (source, stub) = Self.makeSource([])
        #expect(await source.trails(matching: "near", limit: 25).isEmpty)
        #expect(await stub.requestCount == 0)
    }

    // MARK: - Rate limiting

    /// A `429` is a request to stop asking, and retrying into it is what turns
    /// one rate limit into a block. The deadline is checked *before* a request
    /// so a limited browse costs nothing rather than one refused round trip
    /// per search.
    @Test("a rate limit stops the next request until the clock passes it")
    func rateLimitHoldsAndThenReleases() async throws {
        let clock = TestClock()
        let (source, stub) = Self.makeSource(
            [
                OverpassHTTPResponse(
                    data: Data(),
                    statusCode: Self.httpRateLimited,
                    headers: ["retry-after": "120"]
                ),
                Self.ok(Self.listingBody),
                Self.ok(Self.geometryBody),
            ],
            clock: clock
        )

        await #expect(throws: TrailGraphProviderError.self) {
            _ = try await source.trails(near: Self.area, limit: 25)
        }
        let afterRefusal = await stub.requestCount
        #expect(afterRefusal == 1)

        // Still inside the window: refused without spending a request.
        clock.advance(by: 60)
        await #expect(throws: TrailGraphProviderError.self) {
            _ = try await source.trails(near: Self.area, limit: 25)
        }
        #expect(await stub.requestCount == afterRefusal)

        // Past it: asking is allowed again.
        clock.advance(by: 120)
        let trails = try await source.trails(near: Self.area, limit: 25)
        #expect(!trails.isEmpty)
        #expect(await stub.requestCount > afterRefusal)
    }

    /// Overpass answers an overloaded server with an HTML page carrying HTTP
    /// 200 — observed repeatedly while this feature was measured — so a decode
    /// failure is an ordinary operating condition and has to arrive as a typed
    /// error rather than as a crash.
    @Test("an HTML page served with HTTP 200 is a typed failure")
    func htmlServedAsSuccessIsTyped() async {
        let (source, _) = Self.makeSource([
            Self.ok("<html><body>rate limited</body></html>"),
        ])

        await #expect(throws: TrailGraphProviderError.self) {
            _ = try await source.trails(near: Self.area, limit: 25)
        }
    }
}
