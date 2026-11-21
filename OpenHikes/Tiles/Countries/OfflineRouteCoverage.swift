//
//  OfflineRouteCoverage.swift
//  OpenHikes
//
//  Which of the countries on offer a saved line passes through, and whether
//  any of it is in none of them: what the hike screen's *Offline* tile says
//  *Saved* from (#1531).
//
//  Every walked leg is tested whole, never its ends alone. A sparse line, a
//  GPX file with a point every few kilometres, can have both ends of a leg
//  inside a downloaded country and the middle of it over a border, through
//  an enclave or across the bay of a concave outline, and the map goes blank
//  there. So a leg is cut wherever it meets an edge of an outline, and each
//  piece between two cuts is tested at its middle: no outline begins or ends
//  inside a piece, so the middle answers for all of it. A leg that meets no
//  edge is in the countries the one before it ended in, and costs no test,
//  which keeps a line of twenty thousand points to a few tests at its
//  borders. The legs are looked at a stretch at a time, and a leg is cut
//  only against the edges near its stretch.
//
//  The plane is the outlines' own, longitude by latitude, with a leg drawn
//  straight between its ends: the plane
//  ``OfflineCountryManifest/Country/contains(longitude:latitude:)`` reads a
//  point in, so a piece and its middle always agree. A leg over the
//  antimeridian goes the short way round, cut where it crosses.
//
//  A pause is not trail (``RouteBoundary``): the leg a pause opened was
//  driven, or not travelled at all, and is not tested. A lone fix between
//  two pauses is tested as the point it is, because the hiker stood there.
//
//  Pure, and measured off the main actor: a long line is many legs, and the
//  hike screen measures it as it opens.
//

import Algorithms
import OpenHikesData
import OpenHikesShared

/// What the countries on offer make of a saved line.
nonisolated struct OfflineRouteCoverage: Equatable, Sendable {
    /// The countries offered that the line passes through, in the order it
    /// reaches them.
    var crossed: [OfflineCountryManifest.Country] = []
    /// Whether some of the line is in no country offered, which no download
    /// draws.
    var leavesThem = false
}

nonisolated extension OfflineRouteCoverage {
    /// How many legs are cut against one look at the outlines: the edges
    /// within their box, so a leg is tested against the few near it rather
    /// than against every edge of a country.
    static let legsPerStretch = 64

    /// ``init(walking:through:)``, off the main actor.
    @concurrent
    static func measuring(
        _ route: [RouteCoordinate],
        through countries: [OfflineCountryManifest.Country]
    ) async throws(CancellationError) -> Self {
        try Self(walking: route, through: countries)
    }

    /// What `countries` make of every walked leg of `route`, and of every
    /// lone fix in it. Throws as soon as the task doing it is cancelled: a
    /// hiker can leave the screen before a long line is measured.
    init(
        walking route: [RouteCoordinate],
        through countries: [OfflineCountryManifest.Country]
    ) throws(CancellationError) {
        var walk = CoverageWalk(countries: countries)
        let points = route.map { SIMD2($0.longitude, $0.latitude) }
        for piece in route.trailRuns.pieces {
            if piece.count == 1 {
                walk.stand(at: points[piece.lowerBound])
                continue
            }
            walk.setOff()
            for legs in piece.dropLast().chunks(ofCount: Self.legsPerStretch) {
                if Task.isCancelled { throw CancellationError() }
                walk.walk(legs.flatMap { CoverageSpan.leg(from: points[$0], to: points[$0 + 1]) })
            }
        }
        self = walk.coverage
    }
}

/// The countries a line is in, gathered a span at a time.
nonisolated private struct CoverageWalk {
    let countries: [OfflineCountryManifest.Country]
    private(set) var coverage = OfflineRouteCoverage()
    private var named: Set<String> = []
    /// Whether the walk knows which countries hold where it has got to:
    /// those it last recorded. Not before the first span of a walked run,
    /// nor past the antimeridian.
    private var knowsWhere = false
    /// Each country's edges, once one is near the line.
    private var edges: [Int: [CoverageEdge]] = [:]

    init(countries: [OfflineCountryManifest.Country]) {
        self.countries = countries
    }

    /// Starts a walked run, wherever the last one ended.
    mutating func setOff() {
        knowsWhere = false
    }

    /// A lone fix: tested as a point, against every country.
    mutating func stand(at point: SIMD2<Double>) {
        record(Array(countries.indices), at: point)
        knowsWhere = false
    }

    /// One stretch of a walked run, in order.
    mutating func walk(_ spans: [CoverageSpan]) {
        guard var box = spans.first?.box else { return }
        for span in spans.dropFirst() { box = box.union(span.box) }
        let near = countries.indices.filter { box.intersects(CoverageBox(countries[$0].bounds)) }
        let nearEdges = near.flatMap { index in edges(of: index).filter { $0.box.intersects(box) } }
        for span in spans {
            if span.startsAfresh { knowsWhere = false }
            let cuts = span.cuts(by: nearEdges)
            guard cuts.isEmpty else {
                for (start, end) in ([0.0] + cuts + [1.0]).sorted().adjacentPairs() where end > start {
                    record(near, at: span.point(at: (start + end) / 2))
                }
                continue
            }
            if !knowsWhere { record(near, at: span.point(at: 0.5)) }
        }
    }

    /// Notes which of `candidates` hold `point`, as where the walk now is.
    private mutating func record(_ candidates: [Int], at point: SIMD2<Double>) {
        let inside = candidates.filter { countries[$0].contains(longitude: point.x, latitude: point.y) }
        knowsWhere = true
        if inside.isEmpty { coverage.leavesThem = true }
        for index in inside where named.insert(countries[index].id).inserted {
            coverage.crossed.append(countries[index])
        }
    }

    /// The edges of a country's outline, and the four sides of its bounds:
    /// the two things ``OfflineCountryManifest/Country/contains(longitude:latitude:)``
    /// asks, so a span that meets neither stays in or out of it.
    private mutating func edges(of index: Int) -> [CoverageEdge] {
        if let known = edges[index] { return known }
        let country = countries[index]
        var rings = country.outline.map { ring in
            ring.compactMap { $0.count >= 2 ? SIMD2($0[0], $0[1]) : nil }
        }
        let bounds = country.bounds
        rings.append([
            SIMD2(bounds.west, bounds.south), SIMD2(bounds.east, bounds.south),
            SIMD2(bounds.east, bounds.north), SIMD2(bounds.west, bounds.north),
        ])
        let found = rings.flatMap { ring in
            zip(ring.suffix(1) + ring, ring).compactMap { from, to in
                from == to ? nil : CoverageEdge(from: from, to: to)
            }
        }
        edges[index] = found
        return found
    }
}

/// A straight piece of a walked leg, in the outlines' plane.
nonisolated private struct CoverageSpan {
    /// How far, as a fraction of a span, a meeting may lie beyond either
    /// end of the span or of the edge and still count: a cut too many costs
    /// one test, and a cut missed would carry a country over a border.
    static let slack = 1e-9
    /// How nearly parallel a span and an edge may be before the span is
    /// tested anyway, rather than trusting a meeting point that rounding
    /// has made meaningless.
    static let parallel = 1e-12

    var from: SIMD2<Double>
    var to: SIMD2<Double>
    /// Whether it starts somewhere other than where the span before it
    /// ended: past the antimeridian, on the other side of the plane.
    var startsAfresh = false

    var box: CoverageBox { CoverageBox(from, to) }

    /// The leg from `start` to `end`, the short way round: cut in two at
    /// the antimeridian when it crosses it, as the map draws it.
    static func leg(from start: SIMD2<Double>, to end: SIMD2<Double>) -> [Self] {
        let width = end.x - start.x
        guard abs(width) > 180 else { return [Self(from: start, to: end)] }
        let exit: Double = width < 0 ? 180 : -180
        let run = end.x + (width < 0 ? 360 : -360) - start.x
        let fraction = run == 0 ? 0 : (exit - start.x) / run
        let latitude = start.y + fraction * (end.y - start.y)
        return [
            Self(from: start, to: SIMD2(exit, latitude)),
            Self(from: SIMD2(-exit, latitude), to: end, startsAfresh: true),
        ]
    }

    func point(at fraction: Double) -> SIMD2<Double> {
        from + (to - from) * fraction
    }

    /// Where along the span, as fractions of it, it meets any of `edges`,
    /// in no order: empty where it meets none.
    func cuts(by edges: [CoverageEdge]) -> [Double] {
        let reach = box
        return edges.compactMap { edge in
            edge.box.intersects(reach) ? meeting(edge) : nil
        }
    }

    /// Where the span meets `edge`, or `nil` where it does not. A span
    /// parallel to an edge it may touch is cut at its start, so it is
    /// tested rather than carried: where it leaves the edge, the edge's
    /// neighbour cuts it.
    private func meeting(_ edge: CoverageEdge) -> Double? {
        let along = to - from
        let side = edge.to - edge.from
        let offset = edge.from - from
        let denominator = Self.cross(along, side)
        let scale = Self.length(along) * Self.length(side)
        guard abs(denominator) > Self.parallel * scale else { return 0 }
        let fraction = Self.cross(offset, side) / denominator
        let onEdge = Self.cross(offset, along) / denominator
        let reach = -Self.slack...(1 + Self.slack)
        guard reach.contains(fraction), reach.contains(onEdge) else { return nil }
        return min(max(fraction, 0), 1)
    }

    private static func cross(_ lhs: SIMD2<Double>, _ rhs: SIMD2<Double>) -> Double {
        lhs.x * rhs.y - lhs.y * rhs.x
    }

    private static func length(_ vector: SIMD2<Double>) -> Double {
        (vector * vector).sum().squareRoot()
    }
}

/// One side of an outline, or of a country's bounds.
nonisolated private struct CoverageEdge {
    var from: SIMD2<Double>
    var to: SIMD2<Double>
    var box: CoverageBox { CoverageBox(from, to) }
}

/// A box in the outlines' plane, edges included.
nonisolated private struct CoverageBox {
    var lower: SIMD2<Double>
    var upper: SIMD2<Double>

    init(_ one: SIMD2<Double>, _ other: SIMD2<Double>) {
        lower = pointwiseMin(one, other)
        upper = pointwiseMax(one, other)
    }

    init(_ bounds: OfflineCountryManifest.Bounds) {
        self.init(SIMD2(bounds.west, bounds.south), SIMD2(bounds.east, bounds.north))
    }

    func union(_ other: Self) -> Self {
        var joined = self
        joined.lower = pointwiseMin(lower, other.lower)
        joined.upper = pointwiseMax(upper, other.upper)
        return joined
    }

    func intersects(_ other: Self) -> Bool {
        all(lower .<= other.upper) && all(other.lower .<= upper)
    }
}
