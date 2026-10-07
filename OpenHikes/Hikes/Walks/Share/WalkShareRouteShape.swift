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

import CoreGraphics
import CoreLocation
import Foundation

nonisolated struct WalkShareRouteShape: Equatable, Sendable {
    /// The whole trail, in a unit square: centred, the longer side spanning
    /// 0…1, y growing southwards as a screen's does.
    let trail: [CGPoint]
    /// The covered stretches, in the trail's square.
    let walked: [[CGPoint]]

    static let empty = Self(trail: [], walked: [])

    /// Below this a point is not drawn — a two-hundred-point box draws a
    /// thousandth of its side as a fifth of a point. A long recording is
    /// twenty thousand points; what survives is a few hundred.
    static let minimumStep: CGFloat = 0.002
    private static let minimumCosLatitude = 0.15

    /// Fits `trail` and `walked` into one unit square.
    ///
    /// Equirectangular around the trail's middle latitude, which is the right
    /// projection exactly because nothing has to line up with it: there is no
    /// map under this line, only a photograph.
    init(fitting trail: [CLLocationCoordinate2D], walked: [[CLLocationCoordinate2D]]) {
        guard let first = trail.first else {
            self = .empty
            return
        }
        var minLatitude = first.latitude, maxLatitude = first.latitude
        var minLongitude = first.longitude, maxLongitude = first.longitude
        for point in trail {
            minLatitude = min(minLatitude, point.latitude)
            maxLatitude = max(maxLatitude, point.latitude)
            minLongitude = min(minLongitude, point.longitude)
            maxLongitude = max(maxLongitude, point.longitude)
        }
        // Floored for the reason `TrailGlyphView` floors it: a trail near a
        // pole must not divide its width by nothing.
        let cosLatitude = max(cos((minLatitude + maxLatitude) / 2 * .pi / 180), Self.minimumCosLatitude)
        let width = (maxLongitude - minLongitude) * cosLatitude
        let height = maxLatitude - minLatitude
        let span = max(width, height)
        // A trail with no extent at all is a point in the middle of the box.
        let scale = span > 0 ? 1 / span : 0
        let originX = (1 - width * scale) / 2
        let originY = (1 - height * scale) / 2

        func fit(_ coordinate: CLLocationCoordinate2D) -> CGPoint {
            CGPoint(
                x: originX + (coordinate.longitude - minLongitude) * cosLatitude * scale,
                y: originY + (maxLatitude - coordinate.latitude) * scale
            )
        }

        self.init(
            trail: Self.thinned(trail.map(fit)),
            walked: walked.map { Self.thinned($0.map(fit)) }.filter { $0.count > 1 }
        )
    }

    init(trail: [CGPoint], walked: [[CGPoint]]) {
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
