//
//  WalkShareRouteShape.swift
//  OpenHikes
//
//  The trail as a drawing rather than a map: the line fitted into a unit
//  square, with the stretches the walk covered fitted into the same square so
//  they land on top of it.
//
//  Its own fit rather than `TrailGlyphView.project`, which fits one line into
//  a size in points: this one has to put two sets of lines in one frame, and
//  it fits once, into a unit square, so the box can be drawn at any size —
//  on screen while it is dragged and pinched, and at the export's pixel scale
//  — without the route being projected again.
//
//  Its bounds are `TileBoundingBox`'s rather than a `min`/`max` of the
//  longitudes, so a trail across the antimeridian is fitted as the few
//  kilometres it covers rather than the rest of the globe.
//
//  The trail is drawn as the runs that were walked (#1122): a pause, or a GPX
//  `<trkseg>` break, is not trail (see *The app* in AGENTS.md), so the leg
//  across one is left out rather than drawn as the solid line across a drive
//  that the map, the widget and the watch never draw either. The runs share
//  one frame, fitted around all of them, so the covered stretches still land
//  on the line they were walked along.
//

import CoreGraphics
import CoreLocation
import Foundation
import OpenHikesData
import OpenHikesShared

nonisolated struct WalkShareRouteShape: Equatable, Sendable {
    /// The whole trail, in a unit square: centred, the longer side spanning
    /// 0…1, y growing southwards as a screen's does. One line per walked
    /// run, each of two points or more, in order; nothing across a pause.
    let trail: [[CGPoint]]
    /// The covered stretches, in the trail's square.
    let walked: [[CGPoint]]

    static let empty = Self(trail: [], walked: [])

    /// Below this a point is not drawn — a two-hundred-point box draws a
    /// thousandth of its side as a fifth of a point. A long recording is
    /// twenty thousand points; what survives is a few hundred.
    static let minimumStep: CGFloat = 0.002
    private static let minimumCosLatitude = 0.15

    /// Fits `trail`'s walked runs and `walked` into one unit square.
    ///
    /// Equirectangular around the trail's middle latitude, which is the right
    /// projection exactly because nothing has to line up with it: there is no
    /// map under this line, only a photograph.
    ///
    /// - Parameter runs: `trail` cut at its pauses, or `nil` for a line that
    ///   was never paused. A lone fix between two pauses is in no run, so it
    ///   is neither drawn nor fitted (see ``TrailRuns/walkedRuns``).
    init(fitting trail: [CLLocationCoordinate2D], walked: [[CLLocationCoordinate2D]], cutAt runs: TrailRuns? = nil) {
        // Runs counted on another line would cut this one in the wrong
        // places, so they are only read when they are this line's.
        let cut = runs.flatMap { $0.pointCount == trail.count ? $0 : nil }
            ?? TrailRuns(pointCount: trail.count, pauseIndices: [])
        let lines = cut.walkedRuns.map { trail[$0] }
        guard let bounds = TileBoundingBox(route: Array(lines.joined())) else {
            self = .empty
            return
        }
        // Floored for the reason `TrailGlyphView` floors it: a trail near a
        // pole must not divide its width by nothing.
        let cosLatitude = max(cos((bounds.southLat + bounds.northLat) / 2 * .pi / 180), Self.minimumCosLatitude)
        let width = bounds.lonSpan * cosLatitude
        let height = bounds.northLat - bounds.southLat
        // Measured from the middle of the span, not its west edge: a walked
        // point a hair west of the trail's box is a hair west of it here, not
        // a lap of the globe east.
        let middleLongitude = bounds.westLon + bounds.lonSpan / 2
        let span = max(width, height)
        // A trail with no extent at all is a point in the middle of the box.
        let scale = span > 0 ? 1 / span : 0
        let originX = (1 - width * scale) / 2
        let originY = (1 - height * scale) / 2

        func fit(_ coordinate: CLLocationCoordinate2D) -> CGPoint {
            CGPoint(
                x: originX + (RouteGeometry.normalizedLongitudeDelta(coordinate.longitude - middleLongitude)
                    + bounds.lonSpan / 2) * cosLatitude * scale,
                y: originY + (bounds.northLat - coordinate.latitude) * scale
            )
        }

        self.init(
            trail: lines.map { Self.thinned($0.map(fit)) },
            walked: walked.map { Self.thinned($0.map(fit)) }.filter { $0.count > 1 }
        )
    }

    init(trail: [[CGPoint]], walked: [[CGPoint]]) {
        self.trail = trail
        self.walked = walked
    }

    /// `points` without the ones closer than ``minimumStep`` to the last one
    /// kept, always keeping both ends so the line still starts and stops
    /// where the walk did.
    static func thinned(_ points: [CGPoint]) -> [CGPoint] {
        guard points.count > 2, let last = points.last else { return points }
        var kept = [points[0]]
        kept.reserveCapacity(points.count)
        for point in points.dropFirst().dropLast() {
            guard let previous = kept.last else { continue }
            if hypot(point.x - previous.x, point.y - previous.y) >= minimumStep {
                kept.append(point)
            }
        }
        kept.append(last)
        return kept
    }
}
