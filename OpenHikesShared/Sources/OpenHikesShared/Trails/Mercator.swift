//
//  Mercator.swift
//  OpenHikesShared
//
//  Spherical Web Mercator — the projection every raster map in this app is
//  drawn in: the OSM/Stadia/Thunderforest slippy tiles the map renders, and
//  the basemap images `MKMapSnapshotter` rasterizes for the widget.
//
//  The single implementation. `SlippyTileMath` (tile indices) and
//  `TrailBasemap` (widget basemap registration) are both expressed in terms
//  of these functions rather than writing the `tan`/`log` out again, so the
//  app and the widget can never end up projecting a coordinate two subtly
//  different ways — which, for two layers meant to line up pixel-for-pixel,
//  is the one bug worth designing out entirely.
//
//  Coordinates here are *unit* Mercator: the whole world is `0...1` on both
//  axes, x growing east from the antimeridian and y growing **south** from
//  the north edge. That's the tile grid's own convention at zoom 0, and it
//  matches image coordinates, so nothing downstream needs a flip.
//

import Foundation

public enum Mercator {
    /// The latitude where the projection's world becomes exactly square.
    /// Mercator can't represent the poles at all — `tan`/`log` blow up as
    /// latitude approaches ±90° — so every implementation clips here. Well
    /// outside anywhere a trail is walked.
    public static let latitudeLimit = 85.0511287798066

    /// Ground meters spanned by one full unit of Mercator space at the
    /// equator, i.e. the earth's equatorial circumference.
    public static let equatorialCircumferenceMeters = 40_075_016.686

    /// Longitude → unit x.
    ///
    /// Deliberately *not* clamped to ±180: longitude is cyclic, so a value
    /// past the antimeridian should wrap around the world, not pile up at the
    /// edge. Callers that index a finite tile grid wrap the result themselves
    /// (`SlippyTileMath.wrap`); callers that draw a bounded region simply
    /// never see out-of-range input.
    public static func unitX(longitude: Double) -> Double {
        (longitude + 180) / 360
    }

    /// `unitX` brought back inside the one world every bounded region and
    /// every tile grid is expressed in: `0..<1`.
    ///
    /// The companion to ``unitX(longitude:)`` leaving longitude alone. The
    /// projection keeps the extra turns so nothing is lost on the way in, and
    /// callers that want a *place* rather than a winding count drop them
    /// here. `SlippyTileMath.wrap` is the same idea in tile columns.
    ///
    /// Non-finite input is returned untouched: it names no place, and there
    /// is no meridian to bring it back to.
    public static func wrappedUnitX(_ unitX: Double) -> Double {
        guard unitX.isFinite else { return unitX }
        let wrapped = unitX - floor(unitX)
        // A tiny negative x rounds up to exactly 1 here — the same meridian
        // as 0, but outside the half-open range this promises.
        return wrapped < 1 ? wrapped : 0
    }

    /// Distance from `start` to `end` in unit x, signed, the short way round:
    /// `-0.5..<0.5`.
    ///
    /// x is cyclic — 0 and 1 name the same meridian — so two points either
    /// side of the antimeridian are a hair apart, not a world. Plain
    /// subtraction is what says otherwise, and it is wrong every time a route
    /// crosses ±180°.
    public static func unitXOffset(from start: Double, to end: Double) -> Double {
        let delta = wrappedUnitX(end - start)
        return delta < 0.5 ? delta : delta - 1
    }

    /// Latitude → unit y. Clamped, because unlike longitude this is a real
    /// domain boundary rather than a wrap point — beyond it the projection
    /// has no answer to give.
    public static func unitY(latitude: Double) -> Double {
        let clampedLatitude = min(max(latitude, -latitudeLimit), latitudeLimit)
        let sinLatitude = sin(clampedLatitude * .pi / 180)
        // Equivalent to the textbook `(1 - ln(tan φ + sec φ) / π) / 2`, via
        // ln(tan φ + sec φ) == ½·ln((1 + sin φ)/(1 - sin φ)) — the sine form
        // has no pole to step on partway through.
        let y = 0.5 - log((1 + sinLatitude) / (1 - sinLatitude)) / (4 * .pi)
        // At the limit itself the arithmetic lands a few ulps outside the
        // unit square (-7.8e-16 rather than 0), which `floor` at deep zoom
        // turns into tile row -1. Immaterial to anything drawn, but the
        // world being 0...1 is a promise this type makes, so keep it.
        return min(max(y, 0), 1)
    }

    public static func unitPoint(latitude: Double, longitude: Double) -> (x: Double, y: Double) {
        (x: unitX(longitude: longitude), y: unitY(latitude: latitude))
    }

    /// Inverse of ``unitX(longitude:)``.
    public static func longitude(unitX: Double) -> Double {
        unitX * 360 - 180
    }

    /// Inverse of ``unitY(latitude:)``.
    public static func latitude(unitY: Double) -> Double {
        let n = .pi - 2 * .pi * unitY
        return 180 / .pi * atan(sinh(n))
    }

    /// Ground meters spanned by one full unit of Mercator space at
    /// `latitude`. The projection is conformal, so locally this is the same
    /// for both axes — which is what lets a minimum span be expressed in
    /// meters and then applied to a unit rect on either axis.
    public static func metersPerUnit(atLatitude latitude: Double) -> Double {
        let clampedLatitude = min(max(latitude, -latitudeLimit), latitudeLimit)
        return equatorialCircumferenceMeters * cos(clampedLatitude * .pi / 180)
    }

    /// Whether a coordinate is representable without clamping — the check to
    /// run at the app's edges (GPX import, decoded payloads) so nothing
    /// downstream has to.
    public static func isRepresentable(latitude: Double, longitude: Double) -> Bool {
        (-latitudeLimit...latitudeLimit).contains(latitude) && (-180...180).contains(longitude)
    }
}
