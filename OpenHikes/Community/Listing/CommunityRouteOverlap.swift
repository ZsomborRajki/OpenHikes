//
//  CommunityRouteOverlap.swift
//  OpenHikes
//
//  Whether two routes are the same walk.
//
//  The question the community list needs answered is not "are these routes
//  identical" — no two recordings of one trail ever are — but "would somebody
//  browsing find two entries for one path". So what is measured is *coverage*:
//  how much of the route about to be published lies on ground the other one
//  already covers.
//
//  ## Why coverage, and in that direction
//
//  It is deliberately asymmetric. A two-kilometre there-and-back that runs
//  along the first two kilometres of a published twenty-kilometre traverse is
//  a duplicate of part of it, and publishing it adds nothing; the traverse is
//  not a duplicate of the short walk. Measuring "how much of *the new one* is
//  already covered" gets that the right way round, and a symmetric measure
//  — intersection over union — would call the pair unrelated because of all
//  the ground only the long route touches.
//
//  ## How it is computed
//
//  Points of the new route are tested against a grid index of the old one,
//  which makes the pass linear rather than quadratic: a 20,000-point route
//  against another is 400 million distance calculations done naively, and
//  this is a check that runs while a sheet is opening.
//
//  The old route is *densified* before it is indexed — interpolated along each
//  walked leg so no two indexed points are further apart than half the
//  tolerance.
//  Without that, a GPX recorded with a point every 200 m would report almost
//  no overlap with a walk straight down the middle of it, because the test is
//  point-to-point and the points are further apart than the tolerance is wide.
//  Densifying is cheaper and much simpler to be sure of than point-to-segment
//  distance, and it fails in the safe direction: it can only ever find *more*
//  overlap, never less.
//
//  ## A pause is not trail
//
//  A leg the recording was paused across — a drive or a lift between two
//  recorded pieces, or the jump between two GPX `<trkseg>`s — is never
//  densified, because nobody walked it (see ``RouteBoundary``). Interpolated,
//  it put kilometres of road into the index, and a different hike along that
//  road was refused as a retread (#1121). The index is built piece by piece
//  from ``TrailRuns/pieces``, the one reading of a route's pauses, which
//  keeps every fix — a lone one between two pauses included, since the hiker
//  was there — and joins only the fixes of one piece. The route being tested
//  needs no such care: it is sampled at its own fixes, never between them, so
//  its paused legs contribute nothing to either side of the fraction.
//
//  Neither of the two constants is a fact about the world, and both are
//  argued for where they are declared.
//

import CoreLocation
import Foundation
import OpenHikesData
import OpenHikesShared

nonisolated enum CommunityRouteOverlap {
    /// How far off a line a point may be and still count as on it.
    ///
    /// Forty metres, which is wide by GPS standards and deliberately so. What
    /// it has to absorb is not receiver error but the ways two honest
    /// recordings of one path differ: opposite sides of a track, a switchback
    /// cut on one pass and not the other, a wooded section where both traces
    /// wander. Too tight and the check finds nothing, which is the failure
    /// nobody notices.
    static let toleranceMeters: Double = 40

    /// How much of a route has to be already-covered ground before it is a
    /// duplicate rather than a walk that happens to share a stretch.
    ///
    /// Four fifths. Two walks from one car park share a kilometre of approach
    /// and are different hikes; a there-and-back and the loop it is half of
    /// share more and are still worth telling apart. At four fifths what is
    /// left is the case where somebody walked the same trail again — which is
    /// a fine thing to have done and not a second thing to publish.
    static let duplicateFraction: Double = 0.8

    /// At most this many points of the new route are tested.
    ///
    /// Evenly spaced through it, so a sample is a fair description of the
    /// whole walk rather than of its first kilometre. Four hundred points
    /// across any route puts a sample every few metres on a short one and
    /// every few tens of metres on a long one, which is finer than the
    /// tolerance in both cases.
    static let sampleLimit = 400

    /// A ceiling on the densified index, so a pathological pair cannot turn a
    /// sheet's appearance into a stall. Reached only by a route whose legs are
    /// enormous; at that point the index is coarse rather than absent, and the
    /// check under-reports, which is the safe direction.
    static let indexLimit = 200_000

    /// The share of `route` that lies within ``toleranceMeters`` of `other`.
    ///
    /// `0` when either route is empty, when their bounding boxes do not meet,
    /// or when nothing matches — all of which mean the same thing to the
    /// caller and none of which is an error.
    static func coverage(of route: [RouteCoordinate], by other: [RouteCoordinate]) -> Double {
        guard !route.isEmpty, !other.isEmpty else { return 0 }
        let sampled = sample(route, limit: sampleLimit)
        guard !sampled.isEmpty else { return 0 }

        // Cheapest possible rejection, and the common case: two walks in
        // different valleys share no cell and would otherwise pay for an index
        // over the whole of one of them.
        guard boxesMeet(sampled, other) else { return 0 }

        let origin = other[0].clCoordinate
        let index = grid(of: other, origin: origin)
        guard !index.isEmpty else { return 0 }

        let matched = sampled.reduce(into: 0) { total, point in
            if isCovered(point.clCoordinate, origin: origin, by: index) { total += 1 }
        }
        return Double(matched) / Double(sampled.count)
    }

    /// Whether `route` retraces `other` closely enough to be a second listing
    /// of one trail.
    static func isDuplicate(_ route: [RouteCoordinate], of other: [RouteCoordinate]) -> Bool {
        coverage(of: route, by: other) >= duplicateFraction
    }
}

// MARK: - The grid

nonisolated private extension CommunityRouteOverlap {
    /// A cell is one tolerance across, so a point's own cell and the eight
    /// around it contain everything within the tolerance of it. Testing those
    /// nine is what replaces testing every point of the other route.
    struct Cell: Hashable {
        let x: Int
        let y: Int
    }

    static func cell(x: Double, y: Double) -> Cell {
        Cell(
            x: Int((x / toleranceMeters).rounded(.down)),
            y: Int((y / toleranceMeters).rounded(.down))
        )
    }

    /// Local offsets of `route`, densified along each piece the pauses leave,
    /// bucketed by cell. Every fix is indexed and no paused leg is — see the
    /// file header.
    static func grid(
        of route: [RouteCoordinate],
        origin: CLLocationCoordinate2D
    ) -> [Cell: [(x: Double, y: Double)]] {
        var index: [Cell: [(x: Double, y: Double)]] = [:]
        var count = 0

        func add(_ offset: (x: Double, y: Double)) {
            index[cell(x: offset.x, y: offset.y), default: []].append(offset)
            count += 1
        }

        for piece in route.trailRuns.pieces {
            var previous: (x: Double, y: Double)?
            for coordinate in route[piece] {
                guard count < indexLimit else { return index }
                let offset = RouteGeometry.localOffset(from: origin, to: coordinate.clCoordinate)
                if let previous {
                    // Interpolate the leg. `steps` is how many points it takes
                    // for no two to be more than half a tolerance apart — see
                    // the file header for why the gap rather than the
                    // endpoints is what matters.
                    let span = hypot(offset.x - previous.x, offset.y - previous.y)
                    let steps = Int((span / (toleranceMeters / 2)).rounded(.up))
                    if steps > 1 {
                        for step in 1..<steps where count < indexLimit {
                            let fraction = Double(step) / Double(steps)
                            add((
                                x: previous.x + (offset.x - previous.x) * fraction,
                                y: previous.y + (offset.y - previous.y) * fraction
                            ))
                        }
                    }
                }
                add(offset)
                previous = offset
            }
        }
        return index
    }

    static func isCovered(
        _ coordinate: CLLocationCoordinate2D,
        origin: CLLocationCoordinate2D,
        by index: [Cell: [(x: Double, y: Double)]]
    ) -> Bool {
        let offset = RouteGeometry.localOffset(from: origin, to: coordinate)
        let home = cell(x: offset.x, y: offset.y)
        for dx in -1...1 {
            for dy in -1...1 {
                guard let bucket = index[Cell(x: home.x + dx, y: home.y + dy)] else { continue }
                for candidate in bucket
                where hypot(candidate.x - offset.x, candidate.y - offset.y) <= toleranceMeters {
                    return true
                }
            }
        }
        return false
    }
}

// MARK: - Sampling and bounds

nonisolated private extension CommunityRouteOverlap {
    /// At most `limit` points, evenly spaced through `route`, always including
    /// the first and last — the ends are where two walks most often differ,
    /// and a sample that dropped them would miss a trail extended at one end.
    static func sample(_ route: [RouteCoordinate], limit: Int) -> [RouteCoordinate] {
        guard route.count > limit else { return route }
        let step = Double(route.count - 1) / Double(limit - 1)
        return (0..<limit).map { route[Int((Double($0) * step).rounded())] }
    }

    /// Whether the two bounding boxes come within a tolerance of each other.
    ///
    /// The rejection may pass a pair on to the grid but never decide the
    /// answer, so it pads by the tolerance as the grid measures it: in the
    /// metres ``RouteGeometry/localOffset(from:to:)`` counts, and east–west at
    /// the most poleward latitude either box reaches. A degree of longitude
    /// shortens toward the poles — at 60° it is half the equator's — and the
    /// grid measures longitude at the first point of `other`, which lies
    /// inside its box, so no pair it compares is held to a shorter degree
    /// than that one. Over-padding costs a grid pass that finds nothing;
    /// under-padding would discard a real duplicate.
    ///
    /// Longitude is a circle, so the gap between two boxes is measured both
    /// ways round and the shorter one counts: two walks either side of the
    /// antimeridian are metres apart, not a world. A route with a leg across
    /// it — consecutive points more than half the world apart, which only the
    /// short way across explains — is densified onto ground outside the box
    /// its own points make, so it meets everything east–west and the grid,
    /// which handles the wrap, decides.
    static func boxesMeet(_ route: [RouteCoordinate], _ other: [RouteCoordinate]) -> Bool {
        let first = box(of: route)
        let second = box(of: other)

        let latitudePadding = toleranceMeters / gridMetersPerDegree(latitudeAt: 0)
        guard first.minLatitude - latitudePadding <= second.maxLatitude,
              second.minLatitude - latitudePadding <= first.maxLatitude
        else { return false }

        guard !first.crossesAntimeridian, !second.crossesAntimeridian else { return true }
        let poleward = [first.minLatitude, first.maxLatitude, second.minLatitude, second.maxLatitude]
            .map { min(abs($0), 90) }
            .max() ?? 90
        let longitudePadding = toleranceMeters / gridMetersPerDegree(longitudeAt: poleward)
        let directGap = max(0, second.minLongitude - first.maxLongitude, first.minLongitude - second.maxLongitude)
        let wrappedGap = 360 - max(first.maxLongitude - second.minLongitude, second.maxLongitude - first.minLongitude)
        return min(directGap, wrappedGap) <= longitudePadding
    }

    /// Metres in a degree of latitude, as the grid counts them.
    static func gridMetersPerDegree(latitudeAt latitude: Double) -> Double {
        RouteGeometry.localOffset(
            from: CLLocationCoordinate2D(latitude: latitude, longitude: 0),
            to: CLLocationCoordinate2D(latitude: latitude + 1, longitude: 0)
        ).y
    }

    /// Metres in a degree of longitude at `latitude`, as the grid counts them.
    /// Next to nothing at a pole, which pads the box the whole way round.
    static func gridMetersPerDegree(longitudeAt latitude: Double) -> Double {
        RouteGeometry.localOffset(
            from: CLLocationCoordinate2D(latitude: latitude, longitude: 0),
            to: CLLocationCoordinate2D(latitude: latitude, longitude: 1)
        ).x
    }

    struct Box {
        let minLatitude: Double
        let maxLatitude: Double
        let minLongitude: Double
        let maxLongitude: Double
        let crossesAntimeridian: Bool
    }

    static func box(of route: [RouteCoordinate]) -> Box {
        var minLatitude = Double.greatestFiniteMagnitude
        var maxLatitude = -Double.greatestFiniteMagnitude
        var minLongitude = Double.greatestFiniteMagnitude
        var maxLongitude = -Double.greatestFiniteMagnitude
        var crossesAntimeridian = false
        var previousLongitude: Double?
        for point in route {
            minLatitude = min(minLatitude, point.latitude)
            maxLatitude = max(maxLatitude, point.latitude)
            minLongitude = min(minLongitude, point.longitude)
            maxLongitude = max(maxLongitude, point.longitude)
            if let previousLongitude, abs(point.longitude - previousLongitude) > 180 {
                crossesAntimeridian = true
            }
            previousLongitude = point.longitude
        }
        return Box(
            minLatitude: minLatitude,
            maxLatitude: maxLatitude,
            minLongitude: minLongitude,
            maxLongitude: maxLongitude,
            crossesAntimeridian: crossesAntimeridian
        )
    }
}
