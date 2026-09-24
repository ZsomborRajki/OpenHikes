//
//  RouteProfileElevationTests.swift
//  OpenHikesTests
//
//  The elevation chart asks its profile for a y-domain, and a `ClosedRange`
//  built from bounds that aren't ordered is a trap rather than a bad-looking
//  axis. A single height that isn't a number is enough to produce exactly
//  that, and heights arrive from arbitrary GPX files: `<ele>nan</ele>` and
//  `<ele>1e400</ele>` are text `Double.init` accepts.
//
//  `GPXImport` refuses such a height at the door now, so nothing newly
//  imported carries one. This is the layer underneath that — what a hike
//  stored before the door existed, or synced from a device that had an older
//  build, has to survive being opened.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import Testing

@Suite("Route profile elevation range")
struct RouteProfileElevationTests {
    private static func route(_ elevations: [Double?]) -> [RouteCoordinate] {
        elevations.enumerated().map { index, elevation in
            RouteCoordinate(
                latitude: 47.63 + Double(index) * 0.001,
                longitude: 12.86,
                elevation: elevation
            )
        }
    }

    /// Why the range would trap rather than merely draw badly, and which
    /// positions matter. `minAndMax()` seeds both bounds from the front of
    /// the sequence and displaces one only when a later element compares
    /// smaller (or larger); every comparison against a NaN is false, so a
    /// bound seeded with one is never displaced. A NaN *first* survives as
    /// the min and a NaN *last* as the max, and `ClosedRange` checks
    /// `lower <= upper`, which fails either way.
    ///
    /// The trailing end is the one the stdlib `min()`/`max()` this replaced
    /// did not punish, and so the one no fixture here used to cover. Delete
    /// the `.filter(\.isFinite)` in `elevationRange` and this is the case
    /// that catches it — by trapping, like the leading one above, which is
    /// why neither builds the range itself in an `#expect`.
    @Test("a route whose last height is not a number still yields a usable range")
    func trailingNonFiniteHeightIsSteppedOver() throws {
        let profile = RouteProfile(route: Self.route([600, 700, 650, .nan]))
        let range = try #require(profile.elevationRange)

        #expect(range == 600...700)
    }

    @Test("a route whose first height is not a number still yields a usable range")
    func leadingNonFiniteHeightIsSteppedOver() throws {
        let profile = RouteProfile(route: Self.route([.nan, 600, 700, 650]))
        let range = try #require(profile.elevationRange)

        #expect(range == 600...700)
    }

    @Test("an infinite height doesn't stretch the chart's scale", arguments: [
        Double.infinity, -.infinity, .nan,
    ])
    func nonFiniteHeightsAreExcludedFromTheRange(elevation: Double) throws {
        let profile = RouteProfile(route: Self.route([600, elevation, 700]))
        let range = try #require(profile.elevationRange)

        #expect(range == 600...700)
    }

    /// A route whose only heights are unusable has to look like a route with
    /// no heights at all — which the chart already knows how to decline.
    @Test("a route of nothing but non-numbers has no range")
    func allNonFiniteHeightsGiveNoRange() {
        #expect(RouteProfile(route: Self.route([.nan, .infinity, -.infinity])).elevationRange == nil)
    }

    @Test("a route with no heights at all still has no range")
    func noHeightsGiveNoRange() {
        #expect(RouteProfile(route: Self.route([nil, nil])).elevationRange == nil)
    }

    /// The ordinary case, unchanged: one height is a range of zero width, not
    /// an absent one.
    @Test("a single usable height is its own range")
    func oneHeightIsItsOwnRange() throws {
        let profile = RouteProfile(route: Self.route([.nan, 600, nil]))
        let range = try #require(profile.elevationRange)

        #expect(range == 600...600)
    }
}
