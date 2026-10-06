//
//  RouteSteepness.swift
//  OpenHikes
//
//  How steep each stretch of a route is, from the heights its own points
//  carry, on the scale the difficulty grades are drawn on — see
//  ``RouteShade`` and ``RouteColoring/elevation``.
//
//  A grade is measured over a window of route rather than point to point.
//  Neighbouring fixes a few metres apart disagree about height by more than
//  the ground between them rises, so a point-to-point slope paints a level
//  track in every colour of the scale; across a hundred metres that noise is
//  a few percent, which is the width of one step. Up and down count alike:
//  a 25% descent is as hard on the knees as the climb is on the lungs, and
//  more likely to be where a hiker slips.
//

import Algorithms
import CoreLocation
import Foundation
import OpenHikesData

nonisolated enum RouteSteepness {
    /// How much route one grade is measured across — see the file header.
    static let windowMeters = 100.0

    /// One unbroken stretch at a single step of the scale.
    struct Run: Sendable {
        let shade: RouteShade
        /// From the first point of the stretch's first window to the last
        /// point of its last, through the route's own points. Never fewer
        /// than two.
        let coordinates: [CLLocationCoordinate2D]
    }

    /// The grade, in percent, at which each step of the scale after the
    /// first begins: under 5% is a stroll, 10% a noticeable hill, 20% steep
    /// for a path, and from 30% it is ground where hands come out. Round
    /// numbers rather than fitted ones, so the key can print them.
    static let thresholdsPercent: [Double] = [5, 10, 15, 20, 30]

    /// Where a grade, in percent and either way, falls on the scale.
    static func shade(forGradePercent grade: Double) -> RouteShade {
        let step = thresholdsPercent.partitioningIndex { abs(grade) < $0 }
        return RouteShade.scale[step]
    }

    /// The least grade, in percent, drawn in `shade`.
    static func lowerBoundPercent(of shade: RouteShade) -> Double {
        let step = RouteShade.scale.firstIndex(of: shade) ?? 0
        return step == 0 ? 0 : thresholdsPercent[step - 1]
    }

    /// ``runs(route:)`` off the main actor, for the map to colour the
    /// selected line by. A long recorded hike is tens of thousands of points,
    /// which is quick to walk but no reason to walk it on the main thread.
    @concurrent
    static func measuredRuns(route: [RouteCoordinate]) async -> [Run] {
        runs(route: route)
    }

    /// Every stretch of `route` that has heights to measure, in order.
    ///
    /// A point with no usable height closes the window it falls in without
    /// measuring it, so the line keeps the hike's own colour across the gap
    /// rather than being given one grade averaged over ground nobody measured.
    /// The last window of a stretch is usually short; under half a window, it
    /// is folded into the stretch before it, because a slope over a few
    /// metres is the noise the window exists to average away.
    static func runs(route: [RouteCoordinate]) -> [Run] {
        var builder = Builder(route: route)
        var windowStart: Int?
        var windowLength = 0.0
        for index in route.indices {
            guard let height = route[index].elevation, height.isFinite else {
                if let start = windowStart { builder.closeTail(from: start, to: index - 1, length: windowLength) }
                windowStart = nil
                continue
            }
            guard let start = windowStart else {
                windowStart = index
                windowLength = 0
                continue
            }
            windowLength += RouteGeometry.distanceMeters(
                from: route[index - 1].clCoordinate,
                to: route[index].clCoordinate
            )
            guard windowLength >= windowMeters else { continue }
            builder.add(from: start, to: index, length: windowLength)
            windowStart = index
            windowLength = 0
        }
        if let start = windowStart { builder.closeTail(from: start, to: route.count - 1, length: windowLength) }
        return builder.runs
    }

    /// Joins measured windows into runs of one shade.
    private struct Builder {
        let route: [RouteCoordinate]
        /// Extended in place as windows join them, which a `Run`'s `let`
        /// coordinates could not be without copying the whole run each time.
        private var pending: [(shade: RouteShade, coordinates: [CLLocationCoordinate2D])] = []
        var runs: [Run] { pending.map { Run(shade: $0.shade, coordinates: $0.coordinates) } }
        /// The route index the last run ends at, so a window starting there
        /// continues it and one starting anywhere else — after a gap — does not.
        private var lastEnd: Int?

        init(route: [RouteCoordinate]) {
            self.route = route
        }

        mutating func add(from start: Int, to end: Int, length: Double) {
            guard end > start, length > 0,
                  let from = route[start].elevation, let to = route[end].elevation
            else { return }
            append(RouteSteepness.shade(forGradePercent: (to - from) / length * 100), from: start, to: end)
        }

        /// The window a stretch ends in, which is short of a full one.
        mutating func closeTail(from start: Int, to end: Int, length: Double) {
            guard end > start else { return }
            if length < RouteSteepness.windowMeters / 2, lastEnd == start, let previous = pending.last {
                append(previous.shade, from: start, to: end)
            } else {
                add(from: start, to: end, length: length)
            }
        }

        private mutating func append(_ shade: RouteShade, from start: Int, to end: Int) {
            let coordinates = route[start...end].map(\.clCoordinate)
            if lastEnd == start, pending.last?.shade == shade {
                pending[pending.count - 1].coordinates.append(contentsOf: coordinates.dropFirst())
            } else {
                pending.append((shade, coordinates))
            }
            lastEnd = end
        }
    }
}
