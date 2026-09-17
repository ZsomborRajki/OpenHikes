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
/// Internal rather than file-private because `CuratedTrailSourceTests+Geometry`
/// drives the same stub — see that file for why those cases live next door.
actor CuratedTransportStub {
    /// What a queue that has run dry answers with: a success carrying nothing,
    /// so an unexpected extra request fails on its empty body rather than on a
    /// status code and says which request was unexpected.
    private static let httpOK = 200

    private(set) var bodies: [String] = []
    private var responses: [OverpassHTTPResponse]
    /// Run as each request is answered, for a case that needs the world to
    /// have moved while one was in flight — the clock, above all: *how long
    /// the server took to refuse* is what decides whether it is asked again.
    private let onRequest: (@Sendable () -> Void)?

    init(responses: [OverpassHTTPResponse], onRequest: (@Sendable () -> Void)? = nil) {
        self.responses = responses
        self.onRequest = onRequest
    }

    var requestCount: Int { bodies.count }

    func answer(_ request: URLRequest) -> OverpassHTTPResponse {
        onRequest?()
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

    static var area: CommunitySearchArea {
        CommunitySearchArea(coordinate: centre, radiusMeters: searchRadius)
    }

    /// Two named day-hike relations and one continental path, which is what
    /// the day-hike filter exists to throw out — see
    /// ``CuratedTrailQuery/maximumSpanMeters``.
    static let listingBody = """
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
    static let geometryBody = """
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
    static let httpRateLimited = 429

    /// Where the flood fixture's relation ids start, clear of the three the
    /// listing body carries.
    private static let crowdFirstID: Int64 = 1000

    /// How many routes ``CuratedTrailSource`` keeps. Restated here rather than
    /// read off the source, because the eviction tests below are about the
    /// behaviour at the brim and a test that moved with the constant would
    /// stop being about anything.
    private static let cacheCapacity = 100

    private static func crowdIDs(_ count: Int) -> [Int64] {
        (0..<count).map { crowdFirstID + Int64($0) }
    }

    /// Enough answers for a `trails(of:)` over `count` ids, which the source
    /// asks in batches of ``CuratedTrailQuery/geometryBatchLimit``.
    private static func crowdResponses(of count: Int) -> [OverpassHTTPResponse] {
        let batch = CuratedTrailQuery.geometryBatchLimit
        return Array(repeating: ok(crowd(of: count)), count: (count + batch - 1) / batch)
    }

    /// `count` day hikes in one `out geom` answer, for overrunning the cache.
    ///
    /// Each is a single two-point way, which is all the cache stores anything
    /// about — what is under test is how many entries there are and which of
    /// them survives, not what is in them.
    private static func crowd(of count: Int) -> String {
        let elements = (0..<count).map { index -> String in
            let latitude = 47.0 + Double(index) / 10_000
            return """
            {"type":"relation","id":\(crowdFirstID + Int64(index)),
            "tags":{"name":"Crowd \(index)","route":"hiking"},
            "bounds":{"minlat":\(latitude),"minlon":12.0,
            "maxlat":\(latitude + 0.008),"maxlon":12.01},
            "members":[{"type":"way","role":"","geometry":[
            {"lat":\(latitude),"lon":12.0},{"lat":\(latitude + 0.008),"lon":12.01}]}]}
            """
        }
        return "{\"elements\":[\(elements.joined(separator: ","))]}"
    }

    static func ok(_ json: String) -> OverpassHTTPResponse {
        OverpassHTTPResponse(
            data: Data(json.utf8),
            statusCode: httpOK,
            headers: [:]
        )
    }

    /// A directory per case, so no case can read what another one wrote.
    ///
    /// Under the system's temporary directory and never the app's `Caches`,
    /// which is what the real source defaults to: a suite that left the
    /// default alone would write into the developer's own cache and then
    /// answer the *next* run's assertions out of it — a request count that is
    /// right once and wrong for good. See *Deliberate test seams* in the
    /// repository instructions.
    private static func scratchDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("curated-trails-\(UUID().uuidString)")
    }

    /// - Parameter directory: Where this source keeps routes between launches.
    ///   **`nil` — the default — is a source with no disk half at all**, which
    ///   is what most of this suite wants: the two things it counts are
    ///   requests and memory evictions, and a disk cache turns an eviction
    ///   into a file read rather than the round trip the assertion is written
    ///   against. The cases that are about the disk pass one.
    /// - Parameter pause: What the source does between a busy answer and
    ///   asking once more. Nothing, by default: the production seam sleeps,
    ///   and a suite that slept two real seconds per refused request is a
    ///   suite nobody runs. A case that is *about* the pause passes one that
    ///   records it — see `CuratedTrailSourceTests+Busy`.
    static func makeSource(
        _ responses: [OverpassHTTPResponse],
        clock: TestClock = TestClock(),
        directory: URL? = nil,
        onRequest: (@Sendable () -> Void)? = nil,
        pause: @escaping @Sendable (TimeInterval) async throws -> Void = { _ in
            // No wait: see the parameter's documentation above.
        }
    ) -> (CuratedTrailSource, CuratedTransportStub) {
        let stub = CuratedTransportStub(responses: responses, onRequest: onRequest)
        let source = CuratedTrailSource(
            endpoint: URL(string: "https://overpass.invalid/api/interpreter")!,
            directory: directory,
            // ``TestClock/read`` rather than a closure of our own: the whole
            // point of the seam is that no suite waits on wall time, and the
            // bundle already has the clock that makes that true.
            clock: clock.read,
            pause: pause,
            transport: { await stub.answer($0) }
        )
        return (source, stub)
    }

    /// One area search the way ``MergedCommunityTransport`` makes one: the
    /// cheap pass, and then geometry for the rows there is room to draw.
    ///
    /// A helper rather than two calls at every site, because the split is not
    /// what most of these tests are about — what they are about is how many
    /// requests a search costs and what is in them, and that is unchanged by
    /// the pass being asked for in two halves.
    static func search(
        _ source: CuratedTrailSource,
        area: CommunitySearchArea = Self.area,
        limit: Int = 25,
        room: Int? = nil
    ) async throws -> [CuratedTrail] {
        try await completion(source, area: area, limit: limit, room: room).trails
    }

    /// The same search, with what the geometry pass had to say about itself.
    ///
    /// The rows alone answer most of this file; the cases about a refused
    /// geometry pass need the other half of ``CuratedCompletion``, which is
    /// the difference between a row kept without its line and a row dropped.
    static func completion(
        _ source: CuratedTrailSource,
        area: CommunitySearchArea = Self.area,
        limit: Int = 25,
        room: Int? = nil
    ) async throws -> CuratedCompletion {
        let listed = try await source.listings(near: area, limit: limit)
        return try await source.completed(Array(listed.prefix(room ?? limit)))
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

        let trails = try await Self.search(source)

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

        let trails = try await Self.search(source)
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

        #expect(try await Self.search(source, area: wide).isEmpty)
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

        let trails = try await Self.search(source)
        #expect(trails.map(\.relationID) == [11])
    }

    @Test("the limit bounds how many routes geometry is fetched for")
    func limitBoundsTheGeometryPass() async throws {
        let (source, stub) = Self.makeSource([
            Self.ok(Self.listingBody),
            Self.ok(Self.geometryBody),
        ])

        let trails = try await Self.search(source, limit: 1)
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

        _ = try await Self.search(source)
        let afterFirst = await stub.requestCount
        _ = try await Self.search(source)

        #expect(afterFirst == 2)
        #expect(await stub.requestCount == 3)
    }

    @Test("opening a route the list already fetched sends no request")
    func openingACachedRouteIsFree() async throws {
        let (source, stub) = Self.makeSource([
            Self.ok(Self.listingBody),
            Self.ok(Self.geometryBody),
        ])

        _ = try await Self.search(source)
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

}

// MARK: - Searching by name, and what the cache keeps

/// Split from the suite's body for length alone — SwiftLint caps a type body at
/// 300 counted lines, and the fixtures at the top of this file are most of
/// them. The division is where it would be anyway: everything above is about
/// the two passes, and everything below is about what is remembered between
/// them.
extension CuratedTrailSourceTests {

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

        _ = try await Self.search(source)
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

    /// The failure that put Alpine trails on a map of Scotland. A title search
    /// answers out of the last area's rows, so *the last area* has to mean the
    /// one the hiker is looking at — and a search that failed did not make
    /// this one it.
    @Test("a failed search somewhere else does not leave the old area's rows behind")
    func aFailedSearchClearsTheLastAnswer() async throws {
        let clock = TestClock()
        let (source, _) = Self.makeSource(
            [
                Self.ok(Self.listingBody),
                Self.ok(Self.geometryBody),
                OverpassHTTPResponse(
                    data: Data(),
                    statusCode: Self.httpRateLimited,
                    headers: ["retry-after": "120"]
                ),
            ],
            clock: clock
        )
        _ = try await Self.search(source)
        #expect(await !source.trails(matching: "near", limit: 25).isEmpty)

        // Panned a long way off, and Overpass refuses.
        let elsewhere = CommunitySearchArea(
            coordinate: CLLocationCoordinate2D(latitude: 56.8, longitude: -5.1),
            radiusMeters: Self.searchRadius
        )
        await #expect(throws: TrailGraphProviderError.self) {
            _ = try await Self.search(source, area: elsewhere)
        }

        #expect(
            await source.trails(matching: "near", limit: 25).isEmpty,
            "the Alps are not near Scotland"
        )
    }

    /// The same seam by the other door: zooming out past the ceiling returns
    /// early without a request, and that early return is exactly where a stale
    /// answer used to survive.
    @Test("zooming out past the ceiling forgets the last area too")
    func zoomingOutClearsTheLastAnswer() async throws {
        let (source, _) = Self.makeSource([
            Self.ok(Self.listingBody),
            Self.ok(Self.geometryBody),
        ])
        _ = try await Self.search(source)
        let wide = CommunitySearchArea(
            coordinate: Self.centre,
            radiusMeters: CuratedTrailQuery.maximumRadiusMeters * 2
        )

        #expect(try await Self.search(source, area: wide).isEmpty)
        #expect(await source.trails(matching: "near", limit: 25).isEmpty)
    }

    /// Searching the same place again is a refresh rather than a move, so the
    /// rows a hiker can type against survive it even when Overpass refuses the
    /// refresh.
    @Test("re-searching the same area keeps its rows when the refresh fails")
    func aFailedRefreshKeepsTheSameAreasRows() async throws {
        let clock = TestClock()
        let (source, _) = Self.makeSource(
            [
                Self.ok(Self.listingBody),
                Self.ok(Self.geometryBody),
                OverpassHTTPResponse(
                    data: Data(),
                    statusCode: Self.httpRateLimited,
                    headers: ["retry-after": "120"]
                ),
            ],
            clock: clock
        )
        _ = try await Self.search(source)

        await #expect(throws: TrailGraphProviderError.self) {
            _ = try await Self.search(source)
        }

        #expect(await source.trails(matching: "near", limit: 25).map(\.name) == ["Near Loop"])
    }

    // MARK: - What the cache remembers about nothing

    /// A relation that is gone, or too fragmented to assemble, is an answer
    /// and not a missing one — and it does not change while the app is
    /// running. Without this, every *Try Again* on a hike that can no longer
    /// be drawn re-runs the whole geometry pass against a volunteer-run API.
    @Test("a route Overpass has nothing for is not asked about twice")
    func absenceIsRemembered() async throws {
        let empty = #"{"elements":[]}"#
        let (source, stub) = Self.makeSource([Self.ok(empty)])

        #expect(try await source.trail(of: 99) == nil)
        let afterFirst = await stub.requestCount
        #expect(try await source.trail(of: 99) == nil)

        #expect(afterFirst == 1)
        #expect(await stub.requestCount == 1, "the second tap costs nothing")
    }

    // MARK: - What the cache evicts

    /// The eviction bug, as the hiker met it. A search lists twenty-five
    /// routes, five already cached and among the oldest, twenty not. Caching
    /// the twenty evicts the twenty oldest — those five among them — and the
    /// list comes back twenty rows long with nothing saying so.
    ///
    /// Insertion order is what made *being looked at* count for nothing.
    /// Touching an entry on every read is the fix, and this is the shape of
    /// the bug in miniature: one route re-read, one not, and a browse long
    /// enough to evict exactly one of them.
    ///
    /// No disk half here, deliberately — see ``makeSource(_:clock:directory:)``.
    /// What this counts is requests, and with a disk cache behind it a memory
    /// eviction costs a file read instead, which would make the assertion
    /// below true whether or not the memory order was right.
    @Test("the route a hiker just looked at is not the first one evicted")
    func readingAnEntryKeepsItOutOfTheEvictionWindow() async throws {
        let flood = Self.cacheCapacity - 1
        let (source, stub) = Self.makeSource(
            [Self.ok(Self.listingBody), Self.ok(Self.geometryBody)]
                + Self.crowdResponses(of: flood)
                + [Self.ok(Self.geometryBody)]
        )
        _ = try await Self.search(source)

        // Opened again, which under insertion order counted for nothing.
        _ = try await source.trail(of: 11)
        _ = try await source.trails(of: Self.crowdIDs(flood))
        let afterBrowse = await stub.requestCount

        #expect(try await source.trail(of: 11)?.name == "Near Loop")
        #expect(await stub.requestCount == afterBrowse, "the one that was read survived")
        #expect(try await source.trail(of: 22)?.name == "Far Path")
        #expect(await stub.requestCount == afterBrowse + 1, "the one that was not did not")
    }

    /// The second guard, and the one that holds when even a touch cannot: a
    /// request bigger than the cache evicts its own earliest answers before it
    /// finishes. Read back out of the cache afterwards, the first twenty would
    /// simply be gone — so the answer is built from what the fetch returned.
    @Test("one request answers about every relation it was asked, past the cache's size")
    func anAnswerOutlivesItsOwnEviction() async throws {
        let asked = Self.cacheCapacity + 20
        let (source, _) = Self.makeSource(Self.crowdResponses(of: asked))

        let trails = try await source.trails(of: Self.crowdIDs(asked))

        #expect(trails.count == asked)
    }

    /// *Partial rather than nothing* has to hold inside the loop as well as
    /// before it. The rate-limit check runs once, up front; a map with more
    /// pins on it than one batch holds routes asks in several, and a refusal
    /// arriving at the second used to throw away the twenty-five lines the
    /// first had already brought back — which are cached, so the answer was
    /// free and was discarded anyway.
    @Test("a refused chunk keeps the lines the chunks before it fetched")
    func aRefusedChunkKeepsTheOnesBeforeIt() async throws {
        let batch = CuratedTrailQuery.geometryBatchLimit
        let (source, stub) = Self.makeSource([
            Self.ok(Self.crowd(of: batch)),
            OverpassHTTPResponse(
                data: Data(),
                statusCode: Self.httpRateLimited,
                headers: ["retry-after": "120"]
            ),
        ])

        let trails = try await source.trails(of: Self.crowdIDs(batch + 1))

        #expect(trails.count == batch, "the batch that arrived is the answer")
        #expect(await stub.requestCount == 2, "the second chunk was asked for and refused")
    }

    // MARK: - What survives a launch

    /// The point of the disk half: a second launch is not a second download.
    /// Two sources over one directory are what a relaunch looks like from
    /// here — the memory cache goes with the first one, the files do not.
    @Test("a route downloaded once is not downloaded again after a relaunch")
    func aStoredRouteOutlivesTheSource() async throws {
        let directory = Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (first, _) = Self.makeSource(
            [Self.ok(Self.listingBody), Self.ok(Self.geometryBody)],
            directory: directory
        )
        _ = try await Self.search(first)

        // A source with nothing in memory and no response left to give: the
        // only way this can answer is off the disk.
        let (second, relaunched) = Self.makeSource([], directory: directory)
        let trail = try await second.trail(of: 11)

        #expect(trail?.name == "Near Loop")
        #expect(await relaunched.requestCount == 0, "a relaunch spends no round trip")
    }

    /// What a hiker who has been rate-limited is shown instead of nothing —
    /// see ``MergedCommunityTransport``, which is what asks for this. Bounded
    /// by the area, because a cache full of the Alps must not answer a search
    /// in Scotland.
    @Test("routes already on the device answer for the area they are in")
    func storedRoutesAnswerAnAreaWithoutAsking() async throws {
        let directory = Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (first, _) = Self.makeSource(
            [Self.ok(Self.listingBody), Self.ok(Self.geometryBody)],
            directory: directory
        )
        _ = try await Self.search(first)

        let (second, relaunched) = Self.makeSource([], directory: directory)
        let near = await second.cachedTrails(near: Self.area, limit: 25)
        let elsewhere = await second.cachedTrails(
            near: CommunitySearchArea(
                coordinate: CLLocationCoordinate2D(latitude: 57.0, longitude: -4.0),
                radiusMeters: 20_000
            ),
            limit: 25
        )

        #expect(!near.isEmpty)
        #expect(elsewhere.isEmpty, "the Alps are not an answer about the Highlands")
        #expect(await relaunched.requestCount == 0)
    }

    /// A geometry pass refused after the listing pass got through used to
    /// throw away every line this device already had. `completed(_:)` is
    /// partial by contract, so a short answer is one its caller already draws.
    @Test("a rate limit does not discard the lines already in hand")
    func aRateLimitKeepsWhatIsAlreadyCached() async throws {
        let clock = TestClock()
        let (source, stub) = Self.makeSource(
            [
                Self.ok(Self.listingBody),
                Self.ok(Self.geometryBody),
                OverpassHTTPResponse(
                    data: Data(),
                    statusCode: Self.httpRateLimited,
                    headers: ["retry-after": "120"]
                ),
            ],
            clock: clock
        )
        _ = try await Self.search(source)

        // One cached relation and one that would need a request, with the
        // limit now running against the second.
        await #expect(throws: TrailGraphProviderError.self) {
            _ = try await source.trails(of: [99])
        }
        let known = try await source.trails(of: [11, 99])

        #expect(known.keys.sorted() == [11])
        #expect(await stub.requestCount == 3, "the refusal costs no further round trip")
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
            _ = try await Self.search(source)
        }
        let afterRefusal = await stub.requestCount
        #expect(afterRefusal == 1)

        // Still inside the window: refused without spending a request.
        clock.advance(by: 60)
        await #expect(throws: TrailGraphProviderError.self) {
            _ = try await Self.search(source)
        }
        #expect(await stub.requestCount == afterRefusal)

        // Past it: asking is allowed again.
        clock.advance(by: 120)
        let trails = try await Self.search(source)
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
            _ = try await Self.search(source)
        }
    }
}
