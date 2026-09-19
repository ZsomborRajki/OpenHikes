//
//  RouteGeometryLongitudeTests.swift
//  OpenHikesTests
//
//  The one longitude wrap, on its own.
//
//  ``TileBoundingBox`` and ``TrailRegion`` each used to carry a private copy,
//  and the two had drifted into different arrangements of the same arithmetic
//  that agreed only by luck. Now that there is one, its contract is pinned
//  here rather than left to be inferred from whichever caller's tests happen
//  to cross the antimeridian.
//

import Foundation
@testable import OpenHikes
import Testing

@Suite("Longitude wrapping")
struct RouteGeometryLongitudeTests {
    /// The range is half-open at +180, so the two spellings of the
    /// antimeridian have to resolve to the one a box's west edge is stored in.
    @Test("every spelling of the antimeridian comes back as the west edge")
    func antimeridianCollapsesWest() {
        let spellings: [Double] = [180, -180, 540, -540, 900, -900]
        for longitude in spellings {
            #expect(RouteGeometry.normalizedLongitude(longitude) == -180, "\(longitude)°")
        }
    }

    @Test("a longitude already in range is handed back untouched")
    func inRangeIsUntouched() {
        let inRange: [Double] = [-180, -179.999, -90, -0.0, 0, 13.0164, 90, 179.999]
        for longitude in inRange {
            #expect(RouteGeometry.normalizedLongitude(longitude) == longitude, "\(longitude)°")
        }
    }

    /// The whole promise, swept: a wrapped longitude names the same meridian
    /// as the one that went in — a whole number of turns away, never a
    /// fraction of one — and lands inside `[-180, 180)`.
    @Test("wrapping moves a longitude by whole turns and lands it in range")
    func wrapIsCongruentAndInRange() {
        let sweep = stride(from: -3600.0, through: 3600.0, by: 0.25)

        let outOfRange = sweep.filter { longitude in
            let wrapped = RouteGeometry.normalizedLongitude(longitude)
            return !(wrapped >= -180 && wrapped < 180)
        }
        #expect(outOfRange.isEmpty, "left [-180, 180): \(outOfRange.prefix(5))")

        let partialTurns = sweep.filter { longitude in
            let turns = (RouteGeometry.normalizedLongitude(longitude) - longitude) / 360
            return abs(turns - turns.rounded()) > 1e-9
        }
        #expect(partialTurns.isEmpty, "moved a fraction of a turn: \(partialTurns.prefix(5))")
    }

    @Test("wrapping something already wrapped changes nothing")
    func wrapIsIdempotent() {
        let sweep = stride(from: -1080.0, through: 1080.0, by: 0.125)
        let unstable = sweep.filter { longitude in
            let once = RouteGeometry.normalizedLongitude(longitude)
            return RouteGeometry.normalizedLongitude(once) != once
        }
        #expect(unstable.isEmpty, "changed on a second pass: \(unstable.prefix(5))")
    }

    /// It wraps; it does not sanitise. A caller that can be handed a
    /// non-finite longitude has to reject it before here, because what comes
    /// back is non-finite too rather than a plausible-looking place.
    @Test("a longitude that isn't a number doesn't become one")
    func nonFiniteStaysNonFinite() {
        let nonFinite: [Double] = [.nan, .infinity, -.infinity]
        for longitude in nonFinite {
            #expect(!RouteGeometry.normalizedLongitude(longitude).isFinite, "\(longitude)")
        }
    }
}
