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

    /// Why the old implementation trapped rather than merely drew badly, and
    /// why the *first* sample is the one that matters: `min()` and `max()`
    /// both seed themselves with the first element and keep it unless a later
    /// one compares smaller (or larger), and every comparison against a NaN is
    /// false. So both bounds come back NaN, and `nan <= nan` is false — which
    /// is the precondition `ClosedRange` checks.
    ///
    /// Asserted on the stdlib primitives rather than by building the range,
    /// because a test that genuinely traps takes the whole bundle down with
    /// it and reports nothing about anything else.
    @Test("a leading NaN survives both min and max, which is what made the range trap")
    func nanPropagatesThroughMinAndMax() {
        let poisoned: [Double] = [.nan, 600, 700]
        #expect(poisoned.min()?.isNaN == true)
        #expect(poisoned.max()?.isNaN == true)

        // The same NaN anywhere but first is harmless, which is why this went
        // unnoticed: most files that carry one carry it in the middle.
        let survivable: [Double] = [600, .nan, 700]
        #expect(survivable.min() == 600)
        #expect(survivable.max() == 700)
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
