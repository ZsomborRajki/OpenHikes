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
import Foundation
@testable import OpenHikes
import OpenHikesData
import RealModule
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
    /// along a trail that climbs, wanders and switchbacks, with GPS noise on
    /// top of all three.
    ///
    /// Every part of that is load-bearing, because the two size assertions
    /// below measure nothing against a route the simplifier can answer in one
    /// step. This fixture was previously a dead-straight climb with the
    /// longitude alternating between two values — described as "a few metres"
    /// of wobble, but 0.0002° at this latitude is **15 m**, so every point sat
    /// the same distance off the chord between the endpoints. Ramer–Douglas–
    /// Peucker then fell off a cliff rather than thinning: 19,992 points at the
    /// 8 m tolerance and **2** at 16 m, which was the answer accepted. Both
    /// assertions passed against a two-point line and a sixteen-byte string,
    /// and the discarded first pass cost 24 seconds apiece in a Debug build —
    /// 48 of the suite's 66 seconds, for two tests that checked nothing.
    ///
    /// Shape at several scales is what fixes that, because it gives RDP points
    /// at many different deviations instead of one. Measured against this
    /// fixture: 682 points at 8 m, 153 at 16 m, and 102 at 32 m, which is the
    /// pass the budget accepts. So the doubling loop in
    /// ``CommunityRouteOutline/simplified(_:maximumPoints:)`` really runs —
    /// three passes rather than one — and lands comfortably inside the budget
    /// rather than on its floor. The whole fixture is thinned in about a
    /// quarter of a second in a Debug build, against the old one's 24.
    ///
    /// Deterministic, deliberately: the noise comes from hashing the index
    /// rather than from a random generator, so a failure is reproducible and
    /// the numbers above stay true from one run to the next.
    private static func denseRoute(_ count: Int) -> [RouteCoordinate] {
        var latitude = startLatitude
        var longitude = startLongitude
        return (0..<count).map { index in
            let sample = Double(index)
            latitude += climbPerFix + sin(sample / climbPeriod) * climbVariation
            longitude += sin(sample / wanderPeriod) * wanderAmplitude
                + sin(sample / bendPeriod) * bendAmplitude
                + sin(sample / switchbackPeriod) * switchbackAmplitude
            return RouteCoordinate(
                latitude: latitude + jitter(index, salt: 1) * noiseLatitude,
                longitude: longitude + jitter(index, salt: 2) * noiseLongitude
            )
        }
    }

    /// About a metre of northward progress per fix, varying over a long climb.
    private static let climbPerFix = 0.0000090
    private static let climbVariation = 0.0000030
    private static let climbPeriod = 900.0
    /// The valley the trail follows, and a shorter bend inside it.
    private static let wanderAmplitude = 0.0000110
    private static let wanderPeriod = 450.0
    private static let bendAmplitude = 0.0000040
    private static let bendPeriod = 130.0
    /// The switchbacks, ±30 m every 140-odd fixes. These are what survive the
    /// 8 m tolerance in numbers and thin gradually as it doubles, which is the
    /// property the old fixture lacked.
    private static let switchbackAmplitude = 0.00040
    private static let switchbackPeriod = 45.0
    /// GPS noise, about two metres either way.
    private static let noiseLatitude = 0.000018
    private static let noiseLongitude = 0.000027

    /// A repeatable value in `-1...1` for `index`, so the fixture is noisy
    /// without being random.
    ///
    /// `salt` separates the latitude's noise from the longitude's; hashing the
    /// index twice with the same salt would put the two on the same curve and
    /// turn the noise into a diagonal.
    private static func jitter(_ index: Int, salt: Int) -> Double {
        var hashed = UInt64(truncatingIfNeeded: index &* 2_654_435_761 &+ salt &* 2_246_822_519)
        hashed ^= hashed >> 33
        hashed = hashed &* 14_029_467_366_897_019_727
        hashed ^= hashed >> 33
        return Double(hashed % 2001) / 1000.0 - 1.0
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
            #expect(
                point.latitude.isApproximatelyEqual(to: source.latitude, absoluteTolerance: Self.precisionTolerance)
            )
            #expect(
                point.longitude.isApproximatelyEqual(to: source.longitude, absoluteTolerance: Self.precisionTolerance)
            )
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
            #expect(
                point.latitude.isApproximatelyEqual(to: source.latitude, absoluteTolerance: Self.precisionTolerance)
            )
            #expect(
                point.longitude.isApproximatelyEqual(to: source.longitude, absoluteTolerance: Self.precisionTolerance)
            )
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
    ///
    /// The floor is the half that had to be added, and it is the house rule
    /// about upper bounds applied to a fixture rather than to a counter: a
    /// ceiling alone is scored perfectly by a simplifier that returns the two
    /// endpoints, which is exactly what the old fixture provoked and what
    /// nothing here noticed. A thinned day's walk is a line somebody can
    /// recognise, so it is worth tens of points and not two.
    @Test("a long route is thinned to the point budget")
    func aLongRouteIsThinned() {
        let outline = CommunityRouteOutline.simplified(Self.denseRoute(20_000))

        #expect(outline.count <= CommunityRouteOutline.maximumPoints)
        #expect(
            outline.count > Self.thinnedFloor,
            "a thinned route is still the shape of the walk, not its endpoints"
        )
    }

    /// What the budget is worth in bytes, which is the number the design rests
    /// on: twenty-five of these arrive together.
    @Test("an outline is about a kilobyte of text")
    func anOutlineIsSmall() throws {
        let encoded = try #require(CommunityRouteOutline.encoded(Self.denseRoute(20_000)))

        #expect(encoded.utf8.count < 2048)
        // Paired with the bound above for the reason the point count is: a
        // "small enough" assertion is met most comfortably by an outline that
        // carries nothing, and this one used to pass against sixteen bytes.
        #expect(
            encoded.utf8.count > Self.smallestUsefulOutlineBytes,
            "an outline that fits in a couple of hundred bytes is not a day's walk"
        )
    }

    /// Below this the outline has stopped describing the walk. Both are set
    /// well under what this fixture actually produces — 102 points and 515
    /// bytes — so an ordinary change to the simplifier moves neither, and a
    /// collapse moves both.
    private static let thinnedFloor = 32
    private static let smallestUsefulOutlineBytes = 256

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
        #expect(
            outline[1].latitude.isApproximatelyEqual(to: Self.startLatitude, absoluteTolerance: Self.precisionTolerance)
        )
        #expect(
            outline[1].longitude.isApproximatelyEqual(
                to: Self.startLongitude + 199 * Self.step,
                absoluteTolerance: Self.precisionTolerance
            )
        )
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

    /// The budget is a maximum on the way in as well as on the way out.
    ///
    /// The three below are one assertion in three sizes: a line at the budget
    /// is drawn, a line one point past it is not, and an enormous one is not
    /// either — the same answer, because the point count is what the map's
    /// tap hit-test is sized against and a tap projects every accepted point
    /// of every line on the main actor.
    ///
    /// `"?"` is the encoding's zero, so a pair of them is a point that has not
    /// moved. It is the shortest thing that is a valid outline of exactly N
    /// points, which is what makes it the right fixture for a count.
    @Test("an outline at the point budget is drawn")
    func anOutlineAtTheBudgetIsAccepted() {
        let atBudget = String(repeating: "??", count: CommunityRouteOutline.maximumPoints)

        #expect(CommunityRouteOutline.decoded(atBudget).count == CommunityRouteOutline.maximumPoints)
    }

    @Test("one point past the budget draws nothing")
    func anOutlineOverTheBudgetIsRefused() {
        let overBudget = String(repeating: "??", count: CommunityRouteOutline.maximumPoints + 1)

        #expect(
            CommunityRouteOutline.decoded(overBudget).isEmpty,
            "refused whole, not truncated: half a stranger's walk is a worse answer than none"
        )
    }

    /// A field somebody pasted a recorded route into, rather than an outline
    /// of one. Nothing is drawn, and nothing is decoded past the budget
    /// either — the refusal happens where the line stops being affordable.
    @Test("an enormous outline draws nothing")
    func anEnormousOutlineIsRefused() {
        let enormous = String(repeating: "??", count: 20_000)

        #expect(CommunityRouteOutline.decoded(enormous).isEmpty)
    }

    /// And the ordinary case still comes back, at exactly the size the
    /// uploader is allowed to produce.
    @Test("a full-length outline this app wrote is drawn")
    func aFullLengthOutlineFromTheEncoderIsAccepted() throws {
        let encoded = try #require(
            CommunityRouteOutline.encoded(Self.route(CommunityRouteOutline.maximumPoints))
        )

        #expect(CommunityRouteOutline.decoded(encoded).count == CommunityRouteOutline.maximumPoints)
    }

    /// The worst of the four, because it is the one that would draw
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
