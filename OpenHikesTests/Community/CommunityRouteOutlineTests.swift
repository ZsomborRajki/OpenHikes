//
//  CommunityRouteOutlineTests.swift
//  OpenHikesTests
//
//  What has to hold for a published route to travel with the list that found
//  it: it stays small, it stays the right shape, and what comes back out of
//  the text is what went in.
//
//  The decoding half is the one with teeth. An outline is read off a field in
//  a **public** database — text a reviewer may have pasted by hand and a
//  modified client may have written on purpose — and drawn on the hiker's map
//  without anybody looking at it first. So the assertions about malformed
//  input are not defensive tidiness; they are the whole contract.
//

import CoreLocation
@testable import OpenHikes
import Testing

/// The thinned, encoded form of a published route.
@Suite("Community route outline")
struct CommunityRouteOutlineTests {
    private static let startLatitude = 47.63
    private static let startLongitude = 12.86
    /// About 111 m of latitude, comfortably past the simplification tolerance
    /// so a point placed with it is one no thinning may drop.
    private static let step = 0.001
    /// The tolerance the encoding's five decimal places allow: about a metre,
    /// which is finer than anything this is ever compared at.
    private static let precisionTolerance = 0.00002

    /// A line heading north-east, `count` points long.
    private static func route(_ count: Int) -> [RouteCoordinate] {
        (0..<count).map { index in
            RouteCoordinate(
                latitude: startLatitude + Double(index) * step,
                longitude: startLongitude + Double(index) * step,
                elevation: Double(index),
                timestamp: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }
    }

    /// What a real recording looks like to a simplifier: metre-spaced points
    /// with a lateral wobble on them.
    ///
    /// A dead-straight line of twenty thousand points would collapse to two
    /// at any tolerance at all, which would make the two size assertions below
    /// pass without measuring anything. The wobble is a few metres either
    /// side, which is GPS noise, and is what makes the point budget do work.
    private static func denseRoute(_ count: Int) -> [RouteCoordinate] {
        (0..<count).map { index in
            RouteCoordinate(
                latitude: startLatitude + Double(index) * 0.00001,
                longitude: startLongitude + Double(index % 2) * 0.0002
            )
        }
    }

    // MARK: - The round trip

    /// The one thing everything else rests on: what is drawn on somebody's map
    /// is where the hiker who published it actually walked.
    @Test("a route survives being encoded and read back")
    func theRoundTripKeepsThePoints() throws {
        let original = Self.route(20)
        let encoded = try #require(CommunityRouteOutline.encoded(original))
        let decoded = CommunityRouteOutline.decoded(encoded)

        #expect(decoded.count == original.count)
        for (point, source) in zip(decoded, original) {
            #expect(abs(point.latitude - source.latitude) < Self.precisionTolerance)
            #expect(abs(point.longitude - source.longitude) < Self.precisionTolerance)
        }
    }

    /// Negative coordinates and the meridian are where a zig-zag encoding
    /// gets it wrong, and where nobody testing in the Alps would notice.
    @Test("the southern and western hemispheres round-trip too")
    func signsSurviveTheRoundTrip() throws {
        let original = [
            RouteCoordinate(latitude: -33.86, longitude: -70.65),
            RouteCoordinate(latitude: -33.87, longitude: -70.66),
            RouteCoordinate(latitude: 0, longitude: 0),
            RouteCoordinate(latitude: 51.5, longitude: -0.0001),
        ]
        let encoded = try #require(CommunityRouteOutline.encoded(original))
        let decoded = CommunityRouteOutline.decoded(encoded)

        #expect(decoded.count == original.count)
        for (point, source) in zip(decoded, original) {
            #expect(abs(point.latitude - source.latitude) < Self.precisionTolerance)
            #expect(abs(point.longitude - source.longitude) < Self.precisionTolerance)
        }
    }

    /// An outline never becomes a hike, and this is where that is enforced:
    /// what comes back has a position and nothing else. A zero elevation would
    /// be a measurement nobody took.
    @Test("an outline carries no elevation and no time")
    func anOutlineIsOnlyAShape() throws {
        let encoded = try #require(CommunityRouteOutline.encoded(Self.route(5)))
        let decoded = CommunityRouteOutline.decodedRoute(encoded)

        #expect(decoded.allSatisfy { $0.elevation == nil })
        #expect(decoded.allSatisfy { $0.timestamp == nil })
    }

    // MARK: - Staying small

    /// The budget is the reason the map can afford geometry at all. A day's
    /// recording is tens of thousands of points and has to come back under it
    /// however wiggly it is.
    @Test("a long route is thinned to the point budget")
    func aLongRouteIsThinned() {
        let outline = CommunityRouteOutline.simplified(Self.denseRoute(20_000))

        #expect(outline.count <= CommunityRouteOutline.maximumPoints)
        #expect(outline.count >= 2, "a thinned route is still a line")
    }

    /// What the budget is worth in bytes, which is the number the design rests
    /// on: twenty-five of these arrive together.
    @Test("an outline is about a kilobyte of text")
    func anOutlineIsSmall() throws {
        let encoded = try #require(CommunityRouteOutline.encoded(Self.denseRoute(20_000)))

        #expect(encoded.utf8.count < 2048)
    }

    /// Thinning must not straighten. A stride over the points would keep the
    /// count and lose the corner, which is the distinction a hiker is looking
    /// at the line for.
    @Test("thinning keeps a corner and drops a straight run")
    func thinningKeepsTheShape() {
        // Two hundred points in a straight line east, then two hundred north:
        // one corner, and everything else redundant.
        let eastward = (0..<200).map { index in
            RouteCoordinate(
                latitude: Self.startLatitude,
                longitude: Self.startLongitude + Double(index) * Self.step
            )
        }
        let northward = (1..<200).map { index in
            RouteCoordinate(
                latitude: Self.startLatitude + Double(index) * Self.step,
                longitude: Self.startLongitude + 199 * Self.step
            )
        }
        let outline = CommunityRouteOutline.simplified(eastward + northward)

        #expect(outline.count == 3, "a start, the corner and an end is the whole shape")
        #expect(abs(outline[1].latitude - Self.startLatitude) < Self.precisionTolerance)
        #expect(abs(outline[1].longitude - (Self.startLongitude + 199 * Self.step)) < Self.precisionTolerance)
    }

    /// A route already inside the budget is left alone: there is nothing to
    /// buy by moving its points.
    @Test("a short route is not thinned at all")
    func aShortRouteIsKeptWhole() {
        let outline = CommunityRouteOutline.simplified(Self.route(30))

        #expect(outline.count == 30)
    }

    // MARK: - Nothing to draw

    /// A hike with no line does not get an empty string in the database. The
    /// absence is the fact.
    @Test("a route with no line encodes to nothing at all")
    func nothingToDrawEncodesToNil() {
        #expect(CommunityRouteOutline.encoded([]) == nil)
        #expect(CommunityRouteOutline.encoded(Self.route(1)) == nil)
    }

    // MARK: - Reading somebody else's text

    /// The case this is really written for. A truncated paste in the Console
    /// must not become a line across the map.
    @Test("a truncated outline draws nothing")
    func aTruncatedOutlineIsRefused() throws {
        let encoded = try #require(CommunityRouteOutline.encoded(Self.route(20)))
        // Cut inside the last coordinate's digits, which is where a selection
        // that missed the end of the field lands.
        let truncated = String(encoded.dropLast())

        #expect(CommunityRouteOutline.decoded(truncated).isEmpty)
    }

    /// A pair without its second half is the other way a copy goes wrong, and
    /// the one a length check would miss.
    @Test("a latitude with no longitude draws nothing")
    func anUnpairedValueIsRefused() throws {
        let single = try #require(
            CommunityRouteOutline.encoded([
                RouteCoordinate(latitude: Self.startLatitude, longitude: Self.startLongitude),
                RouteCoordinate(latitude: Self.startLatitude + Self.step, longitude: Self.startLongitude),
            ])
        )
        // The first coordinate's two values, and then one more value with
        // nothing to pair it with.
        let unpaired = single + single.prefix(1)

        #expect(CommunityRouteOutline.decoded(unpaired).isEmpty)
    }

    /// Text that was never an outline — a note, a quotation mark, a URL
    /// somebody pasted into the wrong field.
    @Test("text that is not an outline draws nothing")
    func nonsenseIsRefused() {
        #expect(CommunityRouteOutline.decoded("not an outline").isEmpty)
        #expect(CommunityRouteOutline.decoded("\"\"").isEmpty)
        #expect(CommunityRouteOutline.decoded("").isEmpty)
    }

    /// The worst of the three, because it is the one that would draw
    /// something. A single corrupt delta walks every later point off the
    /// world, and a partial line through the Atlantic is a worse answer than
    /// no line.
    @Test("an outline that leaves the world draws nothing")
    func anImpossibleCoordinateIsRefused() throws {
        let encoded = try #require(
            CommunityRouteOutline.encoded([
                RouteCoordinate(latitude: 89.9, longitude: 12.86),
                RouteCoordinate(latitude: 89.99, longitude: 12.87),
            ])
        )
        // The format is deltas from the point before, so a second copy of the
        // same text asks for another 89.9 degrees north — which is past the
        // pole and off the planet. A doubled paste is not a hypothetical.
        #expect(CommunityRouteOutline.decoded(encoded + encoded).isEmpty)
    }
}
