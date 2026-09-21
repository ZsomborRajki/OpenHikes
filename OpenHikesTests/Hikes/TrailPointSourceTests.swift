//
//  TrailPointSourceTests.swift
//  OpenHikesTests
//
//  What comes back from a place search, and what the three ordinary weathers
//  of a volunteer-run API come back as.
//
//  Two of six requests in one sitting on 2026-09-21 answered `504`; three of
//  five did on the next. That is the dispatcher refusing before the query
//  starts, it is normal rather than exotic, and the whole of what this feature
//  promises about it is that **nothing may block drawing**: a refusal is a
//  sentence under a pill and the line, the legs and Save never hear about it.
//  So the cases below are mostly about failures, and every one of them asserts
//  that the failure arrived as a reading rather than as a crash or a silence.
//
//  The transport is injected for the reason the repository's *Deliberate test
//  seams* section gives, and the stub is ``CuratedTransportStub`` — the same
//  recorder the curated suite drives, because this asks the same service in
//  the same shape.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Testing

@Suite("Trail point source")
struct TrailPointSourceTests {
    private static let httpOK = 200
    private static let httpGatewayTimeout = 504
    private static let httpTooManyRequests = 429

    private static let area = CommunitySearchArea(
        coordinate: CLLocationCoordinate2D(latitude: 47.62, longitude: 12.97),
        radiusMeters: 8000
    )

    /// One of each kind of answer OpenStreetMap actually sends: a named
    /// summit, an unnamed waterfall — which is the normal case — a hut mapped
    /// as a **way**, so it arrives with a `center` and no `lat`, and an
    /// element carrying a tag this build has no symbol for.
    private static let body = """
    {"elements": [
    {"type": "node", "id": 1, "lat": 47.60, "lon": 12.95, \
    "tags": {"natural": "peak", "name": "Watzmann"}},
    {"type": "node", "id": 2, "lat": 47.61, "lon": 12.96, \
    "tags": {"waterway": "waterfall"}},
    {"type": "way", "id": 3, "center": {"lat": 47.62, "lon": 12.97}, \
    "tags": {"tourism": "alpine_hut", "name": "Kärlingerhaus"}},
    {"type": "node", "id": 4, "lat": 47.63, "lon": 12.98, \
    "tags": {"tourism": "information"}}
    ]}
    """

    private static func ok(_ json: String) -> OverpassHTTPResponse {
        OverpassHTTPResponse(
            data: Data(json.utf8),
            statusCode: httpOK,
            headers: [:]
        )
    }

    private static func makeSource(
        _ responses: [OverpassHTTPResponse],
        pause: (@Sendable (TimeInterval) async throws -> Void)? = nil
    ) -> (TrailPointSource, CuratedTransportStub) {
        let stub = CuratedTransportStub(responses: responses)
        let source = TrailPointSource(
            pause: pause ?? { _ in /* nothing waits in a suite */ },
            transport: { request in await stub.answer(request) }
        )
        return (source, stub)
    }

    // MARK: - What an answer holds

    /// The three that survive, and the one that does not. An element with no
    /// symbol is dropped rather than drawn as a plain pin: a plain pin reads
    /// as *a place the hiker marked*, and this app has never been there.
    @Test("an answer becomes places, and an unmappable element is dropped")
    func anAnswerBecomesPlaces() async throws {
        let (source, _) = Self.makeSource([Self.ok(Self.body)])

        let places = try await source.places(near: Self.area)

        #expect(places.count == 3)
        #expect(places.map(\.symbol) == [.summit, .water, .shelter])
    }

    /// **Unnamed is the normal case** — 19% of viewpoints and 22% of
    /// waterfalls in the measured box carry a name — so the name is left
    /// exactly as OpenStreetMap has it, and what is read on screen is the
    /// fallback.
    @Test("a name arrives when there is one, and the symbol speaks when there is not")
    func anUnnamedPlaceIsNamedByItsSymbol() async throws {
        let (source, _) = Self.makeSource([Self.ok(Self.body)])

        let places = try await source.places(near: Self.area)

        #expect(places[0].name == "Watzmann")
        #expect(places[1].name.isEmpty, "OpenStreetMap has no name for it and neither has this")
        #expect(places[1].displayName == "Water", "and what is read is what it is")
    }

    /// A hut is routinely a building rather than a node, which is why the
    /// query asks `nwr` for it — and a way has no `lat`, only the `center`
    /// that `out center` puts on it.
    @Test("a place mapped as a building stands at its centre")
    func aBuildingStandsAtItsCentre() async throws {
        let (source, _) = Self.makeSource([Self.ok(Self.body)])

        let hut = try await source.places(near: Self.area)[2]

        #expect(hut.latitude == 47.62)
        #expect(hut.longitude == 12.97)
    }

    /// An area past the ceiling is an *answer* and not a failure: at that zoom
    /// a map of five hundred pins is not what anybody asked for. Nothing
    /// reaches the network.
    @Test("a search wider than the ceiling asks nothing and answers nothing")
    func aWideSearchAsksNothing() async throws {
        let (source, stub) = Self.makeSource([Self.ok(Self.body)])
        let wide = CommunitySearchArea(
            coordinate: Self.area.coordinate,
            radiusMeters: TrailPointQuery.maximumRadiusMeters * 2
        )

        let places = try await source.places(near: wide)

        #expect(places.isEmpty)
        #expect(await stub.requestCount == 0, "and no request was spent finding that out")
    }

    // MARK: - The three weathers

    /// The measured one. A gateway refusal arrives in seconds because the
    /// query never started, so it is asked once more — and the second ask is
    /// usually admitted.
    @Test("a gateway refusal is asked once more, and reaches the hiker as busy")
    func aGatewayRefusalIsRetried() async throws {
        let (source, stub) = Self.makeSource([
            OverpassHTTPResponse(data: Data(), statusCode: Self.httpGatewayTimeout, headers: [:]),
            Self.ok(Self.body),
        ])

        let places = try await source.places(near: Self.area)

        #expect(places.count == 3, "the second ask answered")
        #expect(await stub.requestCount == 2)
    }

    /// Never retried, whatever it cost: a `429` names the seconds it wants to
    /// be left alone, and asking inside them is what turns one rate limit into
    /// a block on an address shared by everyone on that network.
    @Test("a rate limit is not asked again, and carries its wait")
    func aRateLimitIsNotRetried() async throws {
        let (source, stub) = Self.makeSource([
            OverpassHTTPResponse(
                data: Data(),
                statusCode: Self.httpTooManyRequests,
                headers: ["retry-after": "90"]
            ),
        ])

        let error = await #expect(throws: TrailGraphProviderError.self) {
            _ = try await source.places(near: Self.area)
        }

        #expect(await stub.requestCount == 1)
        #expect(CuratedTrailOutage(try #require(error)) == .rateLimited(retryAfter: 90))
    }

    /// **The one with teeth.** An abandoned query answers HTTP 200 with
    /// well-formed JSON and a `remark`; read blind it is indistinguishable
    /// from an area with nothing in it, which is the difference between a
    /// caption saying OpenStreetMap is busy and one telling a hiker there is
    /// nothing where they are standing.
    @Test("a 200 carrying a remark is a refusal and not an empty area")
    func aRemarkIsARefusal() async throws {
        let aborted = """
        {"elements": [], "remark": "runtime error: Query timed out in \\"query\\" at line 1"}
        """
        // Twice: the abort is momentarily-busy, so it is retried once and the
        // second answer is what stands.
        let (source, stub) = Self.makeSource([Self.ok(aborted), Self.ok(aborted)])

        let error = await #expect(throws: TrailGraphProviderError.self) {
            _ = try await source.places(near: Self.area)
        }

        #expect(await stub.requestCount == 2)
        #expect(CuratedTrailOutage(try #require(error)) == .busy)
    }

    /// The HTML error page an overloaded mirror serves with a `200`. Nobody
    /// here can claim to know what it means, so it is *unavailable* — the
    /// sentence that is honest about this device not reaching a server.
    @Test("a body that is not an answer is unavailable")
    func aMalformedBodyIsUnavailable() async throws {
        let (source, _) = Self.makeSource([Self.ok("<html>502 Bad Gateway</html>")])

        let error = await #expect(throws: TrailGraphProviderError.self) {
            _ = try await source.places(near: Self.area)
        }

        #expect(CuratedTrailOutage(try #require(error)) == .unavailable)
    }
}
