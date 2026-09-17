//
//  CuratedTrailSourceTests+Geometry.swift
//  OpenHikesTests
//
//  What a search does when the cheap pass gets through and the expensive one
//  does not.
//
//  An extension of `CuratedTrailSourceTests` in a file of its own rather than
//  a suite of its own, for the reason `MergedCommunityTransportTests+Curated`
//  is split from its sibling: the same type is under test with the same stub
//  behind it, and the file these came from is at the length limit.
//
//  What separates them is the question. That file is about what a search
//  *costs* — two passes, the geometry one naming only the survivors, the cache
//  that keeps a pan free. This one is about what a hiker is left holding when
//  the second pass is refused, which is a different thing and was for a long
//  time nothing at all: Overpass allows a handful of slots per address, one
//  search spends two of them, and a refusal on the second used to throw away
//  the page the first had already paid for.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Testing

extension CuratedTrailSourceTests {
    /// **The listing pass is paid for whether or not the geometry pass
    /// arrives.** Overpass allows a handful of slots per address and one
    /// search spends two of them, so the cheap pass getting through and the
    /// expensive one being refused is an ordinary afternoon — and it used to
    /// cost the whole page. The rows are what that first slot bought: real
    /// trails, with names, pins and what the signpost says. They stay, without
    /// their lines, and the refusal comes back beside them.
    @Test("a refused geometry pass keeps the rows the listing pass paid for")
    func aRefusedGeometryPassKeepsTheRows() async throws {
        let (source, stub) = Self.makeSource([
            Self.ok(Self.listingBody),
            OverpassHTTPResponse(
                data: Data(),
                statusCode: Self.httpRateLimited,
                headers: ["retry-after": "120"]
            ),
        ])

        let completion = try await Self.completion(source)

        #expect(
            completion.trails.map(\.name) == ["Near Loop", "Far Path"],
            "both day hikes are still offered, nearest first"
        )
        // Hoisted out of the macro: a key path passed to `allSatisfy` reads as
        // a throwing call inside `#expect`, and a closure would trip
        // `prefer_key_path`.
        let everyLineMissing = completion.trails.allSatisfy(\.route.isEmpty)
        #expect(everyLineMissing, "there are no lines, and nothing here pretends otherwise")
        #expect(completion.outage == .rateLimited(retryAfter: 120))
        #expect(await stub.requestCount == 2, "the refusal is not retried into")
    }

    /// The other half of that rule, and the reason it is not simply *keep
    /// everything*. A relation Overpass positively has nothing to draw for —
    /// deleted, or too fragmented to assemble — is a row that would be a name
    /// and a blank for ever. It stays out even while the rest of the page is
    /// being kept without its lines: the refusal is about the address, not
    /// about that route, and a row nobody could ever draw is no better for
    /// being kept.
    @Test("a route with nothing to draw stays out of a refused page")
    func anUndrawableRouteStaysOut() async throws {
        // Three day hikes the second time: one already drawn, one Overpass has
        // already said it has nothing for, and one nobody has asked about yet
        // — which is what makes the second geometry pass happen at all.
        let secondListing = """
        {"elements":[
            {"type":"relation","id":11,"tags":{"name":"Near Loop","route":"hiking"},
            "bounds":{"minlat":47.620,"minlon":12.970,"maxlat":47.628,"maxlon":12.980}},
            {"type":"relation","id":44,"tags":{"name":"Newcomer","route":"hiking"},
            "bounds":{"minlat":47.650,"minlon":13.000,"maxlat":47.658,"maxlon":13.010}},
            {"type":"relation","id":22,"tags":{"name":"Far Path","route":"hiking"},
            "bounds":{"minlat":47.700,"minlon":13.050,"maxlat":47.708,"maxlon":13.060}}
        ]}
        """
        let (source, _) = Self.makeSource([
            Self.ok(Self.listingBody),
            // The first geometry pass answers about one of the two it was
            // asked for, so the other is cached as "nothing to draw".
            Self.ok("""
            {"elements":[
                {"type":"relation","id":11,"tags":{"name":"Near Loop","route":"hiking"},
                "bounds":{"minlat":47.620,"minlon":12.970,"maxlat":47.628,"maxlon":12.980},
                "members":[{"type":"way","role":"","geometry":[
                    {"lat":47.620,"lon":12.970},{"lat":47.628,"lon":12.980}]}]}
            ]}
            """),
            Self.ok(secondListing),
            OverpassHTTPResponse(
                data: Data(),
                statusCode: Self.httpRateLimited,
                headers: ["retry-after": "120"]
            ),
        ])
        _ = try await Self.completion(source)

        let completion = try await Self.completion(source)

        #expect(
            completion.trails.map(\.name) == ["Near Loop", "Newcomer"],
            "the route with nothing to draw is not kept by somebody else's refusal"
        )
        #expect(
            completion.trails.first { $0.name == "Newcomer" }?.route.isEmpty == true,
            "the one that was refused is the one standing without a line"
        )
        #expect(completion.outage == .rateLimited(retryAfter: 120))
    }
}
