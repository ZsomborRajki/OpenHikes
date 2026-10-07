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
//  track in every colour of the scale. The heights are averaged over a short
//  stretch first, and the grade is then taken across two hundred metres: an
//  elevation service's points are about fifteen metres apart and a few metres
//  out each, and over a hundred metres that error alone was a whole step of
//  the scale, so the Königssee fixture changed colour fifty-five times in
//  eleven kilometres. A stretch shorter than ``minimumStretchMeters`` then
//  takes the colour of the longer one beside it, so the line reads as a few
//  long climbs rather than a flicker. Up and down count alike: a 25% descent
//  is as hard on the knees as the climb is on the lungs, and more likely to
//  be where a hiker slips.
//

import Algorithms
import CoreLocation
import Foundation
import OpenHikesData

nonisolated enum RouteSteepness {
    /// How much route one grade is measured across — see the file header.
    static let windowMeters = 200.0
    /// How far along the route either side of a point its height is averaged
    /// over before any grade is measured — see the file header.
    static let smoothingRadiusMeters = 50.0
    /// The shortest stretch drawn in a colour of its own. Anything shorter
    /// takes the colour of its longer neighbour — see the file header.
    static let minimumStretchMeters = 300.0

    /// One unbroken stretch at a single step of the scale.
    struct Run: Sendable {
        let shade: RouteShade
        /// From the first point of the stretch's first window to the last
        /// point of its last, through the route's own points. Never fewer
        /// than two.
        let coordinates: [CLLocationCoordinate2D]
    }

    /// The grade, in percent, at which each step of the scale after the
    /// first begins: under 10% is easy walking, 20% a stiff climb on a path,
    /// 30% steep mountain ground, and from 40% it is ground where hands come
    /// out. Set for mountain paths, where an ordinary climb to a hut runs at
    /// 15–20% and a lower scale drew most of a day out in its last two steps.
    /// Round numbers rather than fitted ones, so the key can print them.
    static let thresholdsPercent: [Double] = [10, 15, 20, 30, 40]

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
        let heights = smoothedHeights(of: route)
        var builder = Builder(route: route, heights: heights)
        var windowStart: Int?
        var windowLength = 0.0
        for index in route.indices {
            guard heights[index] != nil else {
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

    /// Each point's height averaged with every point within
    /// ``smoothingRadiusMeters`` of it along the route, or `nil` where the
    /// point has no usable height.
    ///
    /// The average never reaches across a gap in the heights, and near the
    /// end of a stretch it narrows to the same distance either side, so a
    /// steady climb keeps its grade right to its last point rather than being
    /// flattened by an average that can only look back.
    static func smoothedHeights(of route: [RouteCoordinate]) -> [Double?] {
        var smoothed = [Double?](repeating: nil, count: route.count)
        var index = route.startIndex
        while index < route.endIndex {
            guard route[index].elevation?.isFinite == true else {
                index += 1
                continue
            }
            let stretch = index..<(route[index...].firstIndex { $0.elevation?.isFinite != true } ?? route.endIndex)
            smoothStretch(route[stretch], into: &smoothed)
            index = stretch.upperBound
        }
        return smoothed
    }

    /// ``smoothedHeights(of:)`` for one stretch whose every point has a
    /// height.
    private static func smoothStretch(_ stretch: ArraySlice<RouteCoordinate>, into smoothed: inout [Double?]) {
        var along = [0.0]
        var sums = [0.0]
        for (previous, point) in zip(stretch, stretch.dropFirst()) {
            along.append(along[along.count - 1] + RouteGeometry.distanceMeters(
                from: previous.clCoordinate,
                to: point.clCoordinate
            ))
        }
        for point in stretch {
            sums.append(sums[sums.count - 1] + (point.elevation ?? 0))
        }
        let total = along[along.count - 1]
        for offset in along.indices {
            let radius = min(smoothingRadiusMeters, along[offset], total - along[offset])
            let first = along.partitioningIndex { $0 >= along[offset] - radius }
            let pastLast = along.partitioningIndex { $0 > along[offset] + radius }
            smoothed[stretch.startIndex + offset] = (sums[pastLast] - sums[first]) / Double(pastLast - first)
        }
    }

    /// One stretch of a single shade, as the route indices it spans.
    private struct Piece {
        var shade: RouteShade
        var start: Int
        var end: Int
        var length: Double
        /// Whether it begins where the piece before it ends, rather than
        /// after a gap in the heights.
        var joinsPrevious: Bool
    }

    /// Joins measured windows into runs of one shade.
    private struct Builder {
        let route: [RouteCoordinate]
        let heights: [Double?]
        private var pieces: [Piece] = []

        init(route: [RouteCoordinate], heights: [Double?]) {
            self.route = route
            self.heights = heights
        }

        /// The pieces with every short one given to its neighbour, as runs.
        var runs: [Run] {
            RouteSteepness.absorbingShort(pieces).map { piece in
                Run(shade: piece.shade, coordinates: route[piece.start...piece.end].map(\.clCoordinate))
            }
        }

        mutating func add(from start: Int, to end: Int, length: Double) {
            guard end > start, length > 0, let from = heights[start], let to = heights[end] else { return }
            let shade = RouteSteepness.shade(forGradePercent: (to - from) / length * 100)
            append(shade, from: start, to: end, length: length)
        }

        /// The window a stretch ends in, which is short of a full one.
        mutating func closeTail(from start: Int, to end: Int, length: Double) {
            guard end > start else { return }
            if length < RouteSteepness.windowMeters / 2, let previous = pieces.last, previous.end == start {
                append(previous.shade, from: start, to: end, length: length)
            } else {
                add(from: start, to: end, length: length)
            }
        }

        private mutating func append(_ shade: RouteShade, from start: Int, to end: Int, length: Double) {
            let joins = pieces.last?.end == start
            if joins, pieces[pieces.count - 1].shade == shade {
                pieces[pieces.count - 1].end = end
                pieces[pieces.count - 1].length += length
            } else {
                pieces.append(Piece(shade: shade, start: start, end: end, length: length, joinsPrevious: joins))
            }
        }
    }

    /// `pieces` with each one shorter than ``minimumStretchMeters`` merged
    /// into the longer of the pieces it touches, shortest first, so a blip
    /// is never what decides the colour of the stretch around it. A piece
    /// with nothing beside it — a stretch between two gaps in the heights —
    /// keeps its own colour however short it is.
    private static func absorbingShort(_ pieces: [Piece]) -> [Piece] {
        var pieces = pieces
        func neighbours(of index: Int) -> [Int] {
            [index - 1, index + 1].filter { other in
                pieces.indices.contains(other) && pieces[max(index, other)].joinsPrevious
            }
        }
        while let short = pieces.indices
            .filter({ pieces[$0].length < minimumStretchMeters && !neighbours(of: $0).isEmpty })
            .min(by: { pieces[$0].length < pieces[$1].length }),
            let into = neighbours(of: short).max(by: { pieces[$0].length < pieces[$1].length }) {
            let absorbed = pieces.remove(at: short)
            let kept = into < short ? into : into - 1
            pieces[kept].length += absorbed.length
            if into < short {
                pieces[kept].end = absorbed.end
            } else {
                pieces[kept].start = absorbed.start
                pieces[kept].joinsPrevious = absorbed.joinsPrevious
            }
            // The piece now touches the one on absorbed's far side, and the
            // two may be the same shade.
            let after = kept + 1
            if pieces.indices.contains(after), pieces[after].joinsPrevious, pieces[after].shade == pieces[kept].shade {
                pieces[kept].end = pieces[after].end
                pieces[kept].length += pieces.remove(at: after).length
            }
            if kept > 0, pieces[kept].joinsPrevious, pieces[kept - 1].shade == pieces[kept].shade {
                pieces[kept - 1].end = pieces[kept].end
                pieces[kept - 1].length += pieces.remove(at: kept).length
            }
        }
        return pieces
    }
}
