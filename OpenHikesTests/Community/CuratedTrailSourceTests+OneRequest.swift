//
//  CuratedTrailSourceTests+OneRequest.swift
//  OpenHikesTests
//
//  A search of the map above the sheet: one request, and the rows arrive with
//  their lines.
//
//  The suite's own fixtures are areas that are only circles, ten kilometres
//  out, so every case next door still exercises the two passes a wide search
//  makes. What is here is the other side of ``CuratedTrailQuery/areaRequest(in:)``
//  — the side a hiker meets at an ordinary zoom — and like the rest of the
//  suite it is asserted on requests: how many, and what was in them. A version
//  that quietly went back to two would draw exactly these rows, half a minute
//  later.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Testing

extension CuratedTrailSourceTests {
    /// The map above a half-height sheet at a five-kilometre view, around the
    /// suite's own centre.
    private enum Valley {
        static let latitude = 47.62
        static let longitude = 12.97
        static let latitudeDelta = 0.044
        static let longitudeDelta = 0.0665
    }

    static var visibleArea: CommunitySearchArea {
        CommunitySearchArea(
            coordinate: CLLocationCoordinate2D(latitude: Valley.latitude, longitude: Valley.longitude),
            radiusMeters: CommunityQueryPolicy.minimumRadiusMeters,
            visibleSpan: CommunitySearchArea.Span(
                latitudeDelta: Valley.latitudeDelta,
                longitudeDelta: Valley.longitudeDelta
            )
        )
    }

    /// The two day hikes of ``geometryBody`` with their lines, a continental
    /// path that slipped under the member ceiling with its line, and a route
    /// in two pieces that will not join.
    static let areaWithLinesBody = """
    {"elements":[
        {"type":"relation","id":11,"tags":{"name":"Near Loop","route":"hiking","roundtrip":"yes"},
        "bounds":{"minlat":47.620,"minlon":12.970,"maxlat":47.628,"maxlon":12.980},
        "members":[{"type":"way","role":"","geometry":[
            {"lat":47.620,"lon":12.970},{"lat":47.628,"lon":12.980}]}]},
        {"type":"relation","id":22,"tags":{"name":"Far Path","route":"hiking"},
        "bounds":{"minlat":47.700,"minlon":13.050,"maxlat":47.708,"maxlon":13.060},
        "members":[{"type":"way","role":"","geometry":[
            {"lat":47.700,"lon":13.050},{"lat":47.708,"lon":13.060}]}]},
        {"type":"relation","id":33,"tags":{"name":"Continental Way","route":"hiking"},
        "bounds":{"minlat":45.000,"minlon":10.000,"maxlat":49.000,"maxlon":15.000},
        "members":[{"type":"way","role":"","geometry":[
            {"lat":45.000,"lon":10.000},{"lat":49.000,"lon":15.000}]}]},
        {"type":"relation","id":44,"tags":{"name":"Broken Path","route":"hiking"},
        "bounds":{"minlat":47.610,"minlon":12.960,"maxlat":47.630,"maxlon":12.990},
        "members":[
            {"type":"way","role":"","geometry":[{"lat":47.610,"lon":12.960},{"lat":47.615,"lon":12.965}]},
            {"type":"way","role":"","geometry":[{"lat":47.625,"lon":12.985},{"lat":47.630,"lon":12.990}]}]}
    ]}
    """

    @Test("a search of the map above the sheet is one request, and its rows arrive with their lines")
    func aSmallAreaIsOneRequest() async throws {
        let (source, stub) = Self.makeSource([Self.ok(Self.areaWithLinesBody)])

        let completion = try await Self.completion(source, area: Self.visibleArea)

        let bodies = await stub.bodies
        #expect(bodies.count == 1, "the lines came with the list, so there is no second request")
        #expect(bodies.first?.contains("out geom") == true)
        #expect(bodies.first?.contains("count_members()") == true)
        #expect(completion.trails.map(\.relationID) == [11, 22])
        #expect(completion.trails.allSatisfy { $0.route.count > 1 })
        #expect(completion.outage == nil)
    }

    /// The day-hike filter is the listing pass's, and asking for both at once
    /// does not take it away: the box still decides what is offered.
    @Test("one request still offers only day hikes")
    func oneRequestKeepsTheDayHikeFilter() async throws {
        let (source, _) = Self.makeSource([Self.ok(Self.areaWithLinesBody)])

        let listed = try await source.listings(near: Self.visibleArea, limit: 25)

        #expect(!listed.map(\.relationID).contains(33))
    }

    /// Where the two passes ended up as well, one request later: listed, then
    /// dropped when the geometry had nothing to draw.
    @Test("a route that cannot be drawn is not offered at all")
    func anUndrawableRouteIsNotOffered() async throws {
        let (source, _) = Self.makeSource([Self.ok(Self.areaWithLinesBody)])

        let listed = try await source.listings(near: Self.visibleArea, limit: 25)

        #expect(!listed.map(\.relationID).contains(44))
    }

    /// The cache is what keeps everything after the list off the network: the
    /// map drawing a row's line, and the hiker opening one.
    @Test("opening a route a one-request search drew sends no request")
    func oneRequestLinesAreKept() async throws {
        let (source, stub) = Self.makeSource([Self.ok(Self.areaWithLinesBody)])

        _ = try await Self.search(source, area: Self.visibleArea)
        let trail = try await source.trail(of: 11)

        #expect(trail?.name == "Near Loop")
        #expect(await stub.requestCount == 1)
    }

    /// Only the page is kept: the rest of the box was measured and thrown away,
    /// and a route nobody was offered must not take a cache slot from one
    /// somebody was.
    @Test("only the routes the page offered are kept")
    func onlyThePageIsKept() async throws {
        let (source, stub) = Self.makeSource([
            Self.ok(Self.areaWithLinesBody),
            Self.ok(Self.geometryBody),
        ])

        _ = try await Self.search(source, area: Self.visibleArea, limit: 1)
        _ = try await source.trail(of: 22)

        #expect(await stub.requestCount == 2, "the second row was not on the page, so its line was not kept")
    }

    /// The other side of the threshold, so the two passes are not merely what
    /// the suite's circles happen to get.
    @Test("a search wider than one request carries lines for keeps the two passes")
    func aWideAreaKeepsTwoPasses() async throws {
        let (source, stub) = Self.makeSource([
            Self.ok(Self.listingBody),
            Self.ok(Self.geometryBody),
        ])
        let wide = CommunitySearchArea(
            coordinate: CLLocationCoordinate2D(latitude: 47.62, longitude: 12.97),
            radiusMeters: CommunityQueryPolicy.minimumRadiusMeters * 2,
            visibleSpan: CommunitySearchArea.Span(latitudeDelta: 0.36, longitudeDelta: 0.4)
        )

        _ = try await Self.search(source, area: wide)

        let bodies = await stub.bodies
        #expect(bodies.count == 2)
        #expect(bodies.first?.contains("out tags bb") == true)
        #expect(bodies.last?.contains("out geom") == true)
    }
}
