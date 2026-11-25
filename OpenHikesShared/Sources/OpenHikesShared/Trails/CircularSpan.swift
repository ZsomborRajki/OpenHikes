//
//  CircularSpan.swift
//  OpenHikesShared
//
//  The narrowest arc of a circle that holds every one of some positions on
//  it: how far a route reaches east and west, when east and west wrap.
//
//  One implementation for the two ways the app measures a route across the
//  antimeridian. `TileBoundingBox` measures in degrees, for framing a route,
//  choosing an offline download's tile columns and fitting a walk's share
//  picture. `TrailBasemap` measures in unit Mercator x, for the widget's
//  basemap. Each keeps its own latitudes and its own box; only the circle is
//  shared, so the two cannot disagree about which way round a route goes.
//
//  Here rather than in the app because the widget draws with it, and the
//  shared library takes no package dependency (*Layout and targets* in
//  AGENTS.md), which is why the neighbouring pairs are walked with `zip`.
//

import Foundation

/// The narrowest arc of a circle of circumference `period` that holds every
/// position given, as where it starts and how far it runs the positive way.
///
/// The arc is the complement of the widest gap between neighbouring positions
/// around the circle, including the gap that runs from the last position back
/// round to the first, which is the one an ordinary route falls in and the
/// one a plain min/max mistakes for the route itself.
///
/// **Ties.** The gap through the wrap is weighed first, and a later gap
/// replaces it only by being strictly wider, so when gaps are equal the wrap
/// wins, and after it the gap that starts furthest west. The same positions
/// therefore always give the same arc.
public struct CircularSpan: Equatable, Sendable {
    /// Where the arc starts: always one of the positions given, never one
    /// rebuilt by adding a gap to another, so it carries no rounding.
    public let start: Double
    /// How far the arc runs from ``start``, in `0..<period`. Zero for one
    /// position, or for one position repeated.
    ///
    /// Measured between the arc's own two ends, both positions given, rather
    /// than as `period` less the widest gap. The gap through the wrap is a
    /// sum with `period`, which rounds away the low bits of both ends, and
    /// its complement left `start + length` an ulp short of the last
    /// position. Measured end to end, `start + length` gives the last
    /// position back (past `period` when the arc runs through the wrap)
    /// wherever the difference is exact, as it is between two ends of one
    /// sign within a factor of two of each other. A box rebuilds its east
    /// edge that way, so a route whose east end lies on a tile column's west
    /// edge keeps that column.
    public let length: Double

    /// `nil` for no positions, which have no arc to speak of.
    ///
    /// - Parameters:
    ///   - positions: values on the circle, all inside one turn of it, such
    ///     as longitudes in `-180...180` or unit x in `0..<1`.
    ///   - period: the circle's circumference in the same unit: 360 for
    ///     degrees, 1 for unit Mercator.
    public init?(enclosing positions: [Double], period: Double) {
        let sorted = positions.sorted()
        guard let first = sorted.first, let last = sorted.last else { return nil }

        var widestGap = first + period - last
        var arcStart = first
        var arcEnd = last
        for (west, east) in zip(sorted, sorted.dropFirst()) where east - west > widestGap {
            widestGap = east - west
            arcStart = east
            arcEnd = west
        }
        start = arcStart
        // The gap is only compared, never subtracted: see `length`.
        length = arcEnd >= arcStart ? arcEnd - arcStart : arcEnd + period - arcStart
    }
}
