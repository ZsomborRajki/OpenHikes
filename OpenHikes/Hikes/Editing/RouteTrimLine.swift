//
//  RouteTrimLine.swift
//  OpenHikes
//
//  The line a visit to *Edit Route* works on, measured once and off the main
//  actor: where a cut stands on it and on the map, the clock at a cut, where
//  a finger on the map is along it, and how a spot on it maps onto the same
//  pieces put together under other answers. See ``RouteTrimSession``, whose
//  file this was part of until it outgrew it.
//

import Algorithms
import CoreLocation
import Foundation
import MapKit
import OpenHikesData

/// Which end of the line a cut is.
nonisolated enum RouteTrimHandle: Sendable {
    case end
    case start

    /// The pause on this end of the line — see ``RouteTrim/EndPauses``.
    var endPause: RouteTrim.EndPauses {
        switch self {
        case .end: .end
        case .start: .start
        }
    }
}

/// The line a session trims, measured once, off the main actor.
nonisolated struct RouteTrimLine: Sendable {
    /// Where a cut stands on the map.
    struct Spot: Sendable {
        let coordinate: CLLocationCoordinate2D
        /// How far along the polyline MapKit draws it, 0 to 1: the scale
        /// `MKPolylineRenderer.strokeStart` and `strokeEnd` are in.
        let drawnFraction: Double
    }

    let route: [RouteCoordinate]
    let profile: RouteProfile
    let carriedEnds: RouteCarriedEnds
    /// Whether the line comes back to where it began, the way it came or
    /// another — see ``RouteShape``. `nil` for a line it gives no shape.
    var shape: RouteShape?
    /// Where each stretch to check is in ``route``, by its id — see
    /// ``RouteAssembly/Line``. Empty for a line with none.
    var checkRanges: [Int: ClosedRange<Int>] = [:]
    /// The answer each stretch to check is drawn under, by its id.
    var choices: [Int: RouteCheck.Choice] = [:]
    /// The pieces the line was put together from, and where each is in
    /// ``route`` — see ``RouteAssembly/Line/pieceRanges``. Empty for a line
    /// with no stretches to check.
    var pieces: [RouteAssembly.Piece] = []
    var pieceRanges: [ClosedRange<Int>?] = []
    /// The steps made on the line the pieces put together — see
    /// ``RouteStep``. A line with any has no stretches to point at: a step
    /// moves the ground they stood on.
    var steps: [RouteStep] = []
    /// The ends of the line a step moved: the hike no longer begins, or
    /// ends, where and when the line it was made from did.
    var endsMovedBySteps: Set<RouteTrimHandle> = []
    /// Whether the last of ``steps`` changed the line it was made on — see
    /// ``RouteSteps/Applied/lastStepChangedLine``.
    var lastStepChangedLine = true
    /// How long the line was being recorded, carried through any step that
    /// took its clock away — see ``RouteSteps/Applied/recordedSeconds``.
    var recordedSeconds: TimeInterval = 0
    /// The line as it stood before a step took its clock away, or empty —
    /// see ``RouteSteps/Applied/clockedRoute``.
    var clockedRoute: [RouteCoordinate] = []
    /// How far along the drawn polyline each point stands, 0 to 1, by the
    /// length MapKit measures a polyline in: map points, a paused leg's
    /// included, since the polyline is drawn across it.
    let drawnFractions: [Double]

    var distances: [Double] { profile.distances }
    var totalMeters: Double { profile.totalDistanceMeters }

    /// The whole line of `sources` under `assembly`, with `steps` made on
    /// it, measured.
    @concurrent
    static func measuring(
        _ sources: RouteEditSources,
        under assembly: RouteAssembly?,
        steps: [RouteStep] = []
    ) async throws(CancellationError) -> Self {
        let whole = sources.whole(under: assembly)
        guard !steps.isEmpty else {
            var line = try await measuring(whole.route)
            line.checkRanges = whole.checkRanges
            line.choices = Self.choices(of: assembly?.checks ?? [])
            line.pieces = assembly?.pieces ?? []
            line.pieceRanges = whole.pieceRanges
            return line
        }
        let applied = RouteSteps.applying(steps, to: whole.route)
        var line = try await measuring(applied.route)
        line.choices = Self.choices(of: assembly?.checks ?? [])
        line.steps = steps
        line.lastStepChangedLine = applied.lastStepChangedLine
        line.recordedSeconds = applied.recordedSeconds
        line.clockedRoute = applied.clockedRoute
        if applied.movesStart { line.endsMovedBySteps.insert(.start) }
        if applied.movesEnd { line.endsMovedBySteps.insert(.end) }
        return line
    }

    /// The answers `checks` stand under, by stretch: what tells two lines
    /// put together from the same pieces apart.
    static func choices(of checks: [RouteCheck]) -> [Int: RouteCheck.Choice] {
        Dictionary(checks.map { ($0.id, $0.choice) }, uniquingKeysWith: { first, _ in first })
    }

    /// The part of the line a stretch to check takes up, in metres along it.
    func meters(ofCheck id: Int) -> ClosedRange<Double>? {
        guard let range = checkRanges[id], distances.indices.contains(range.upperBound) else { return nil }
        return distances[range.lowerBound]...distances[range.upperBound]
    }

    /// Where the spot `distance` metres along this line is on `other`: the
    /// same pieces put together under other answers. A piece the two draw
    /// alike — kept ground, or a stretch answered alike — is the same ground
    /// on both, so a spot on it is the same spot. The leg joining two pieces
    /// is neither's, and changes with the pieces it joins, so a spot on it
    /// keeps its share of it.
    ///
    /// A spot inside a stretch the two draw differently is on no ground
    /// `other` has, so it goes to the edge of that stretch `handle` keeps it
    /// whole from: a start to its beginning, an end to its finish. Either end
    /// of the line is the same end of `other`.
    func meters(matching distance: Double, on other: Self, for handle: RouteTrimHandle) -> Double {
        if distance <= 0 { return 0 }
        if distance >= totalMeters { return other.totalMeters }
        guard choices != other.choices, pieces == other.pieces, pieceRanges.count == other.pieceRanges.count else {
            return min(distance, other.totalMeters)
        }
        var behind = (here: 0.0, there: 0.0)
        for (index, piece) in pieces.enumerated() {
            guard let here = meters(ofPiece: index), let there = other.meters(ofPiece: index) else { continue }
            if distance <= here.lowerBound {
                let leg = behind.there...there.lowerBound
                return Self.share(of: distance, from: behind.here, to: here.lowerBound, on: leg)
            }
            if distance < here.upperBound {
                if case .check(let id) = piece, choices[id] != other.choices[id] {
                    return handle == .start ? there.lowerBound : there.upperBound
                }
                return min(there.lowerBound + distance - here.lowerBound, there.upperBound)
            }
            behind = (here.upperBound, there.upperBound)
        }
        return Self.share(of: distance, from: behind.here, to: totalMeters, on: behind.there...other.totalMeters)
    }

    /// The part of the line one of ``pieces`` takes up, in metres along it.
    private func meters(ofPiece index: Int) -> ClosedRange<Double>? {
        guard pieceRanges.indices.contains(index), let range = pieceRanges[index],
              distances.indices.contains(range.upperBound)
        else { return nil }
        return distances[range.lowerBound]...distances[range.upperBound]
    }

    /// The spot on `there` that is as far along it as `distance` is from
    /// `start` to `end`.
    private static func share(
        of distance: Double,
        from start: Double,
        to end: Double,
        on there: ClosedRange<Double>
    ) -> Double {
        guard end > start else { return there.upperBound }
        let fraction = min(max((distance - start) / (end - start), 0), 1)
        return there.lowerBound + fraction * (there.upperBound - there.lowerBound)
    }

    /// The points a stretch to check is drawn with.
    func coordinates(ofCheck id: Int) -> [CLLocationCoordinate2D] {
        guard let range = checkRanges[id], profile.coordinates.indices.contains(range.upperBound) else { return [] }
        return Array(profile.coordinates[range])
    }

    @concurrent
    static func measuring(_ route: [RouteCoordinate]) async throws(CancellationError) -> Self {
        assertOffMainThread("A route is measured for trimming off the main thread")
        let measured = try RouteProfile.cancellable(route: route)
        let carried = RouteCarriedEnds.found(in: route, distances: measured.distances)
        guard !Task.isCancelled else { throw CancellationError() }
        var line = Self(
            route: route,
            profile: measured,
            carriedEnds: carried,
            shape: RouteShape.of(route: route),
            drawnFractions: Self.drawnFractions(of: measured.coordinates)
        )
        line.recordedSeconds = RouteTrim.recordedSeconds(of: route)
        return line
    }

    private static func drawnFractions(of coordinates: [CLLocationCoordinate2D]) -> [Double] {
        var lengths: [Double] = []
        lengths.reserveCapacity(coordinates.count)
        var cumulative = 0.0
        var previous: MKMapPoint?
        for coordinate in coordinates {
            let point = MKMapPoint(coordinate)
            if let previous { cumulative += hypot(point.x - previous.x, point.y - previous.y) }
            lengths.append(cumulative)
            previous = point
        }
        guard cumulative > 0 else { return lengths }
        return lengths.map { $0 / cumulative }
    }

    /// Where a line that begins `meters` along this one begins. Across a
    /// pause that is the fix after it, as ``RouteTrim`` cuts it.
    ///
    /// - Parameter takingOffPause: whether a cut on the line's own first
    ///   point takes off the pause after it — see ``RouteTrim/EndPauses``.
    func startSpot(at meters: Double, takingOffPause: Bool = false) -> Spot {
        // An end left alone is the line's own first point, a pause on it
        // included, as ``RouteTrim`` leaves it.
        if isLeftAlone(.start, at: meters, takingOffPause: takingOffPause), let first = profile.coordinates.first {
            return Spot(coordinate: first, drawnFraction: 0)
        }
        return spot(at: bracket(meters, for: .start))
    }

    /// Where a line that ends `meters` along this one ends: across a pause,
    /// the fix before it.
    func endSpot(at meters: Double, takingOffPause: Bool = false) -> Spot {
        if isLeftAlone(.end, at: meters, takingOffPause: takingOffPause), let last = profile.coordinates.last {
            return Spot(coordinate: last, drawnFraction: 1)
        }
        return spot(at: bracket(meters, for: .end))
    }

    /// The clock at a cut `meters` along the line, read off the stamped
    /// points either side of it as the save reads it, or `nil` where there
    /// are none — see ``RouteTrim/time(at:between:and:of:distances:)``. An
    /// end left alone is its own point's, as the hike's *Duration* reads it.
    func timestamp(of handle: RouteTrimHandle, at meters: Double, takingOffPause: Bool = false) -> Date? {
        if isLeftAlone(handle, at: meters, takingOffPause: takingOffPause) {
            return handle == .start ? route.first?.timestamp : route.last?.timestamp
        }
        let leg = bracket(meters, for: handle)
        let at = distances[leg.lower] + (distances[leg.upper] - distances[leg.lower]) * leg.fraction
        return RouteTrim.time(at: at, between: leg.lower, and: leg.upper, of: route, distances: distances)
    }

    /// Whether a cut `meters` along the line is no cut at all: it stands on
    /// its own end of the line, and leaves the pause there.
    private func isLeftAlone(_ handle: RouteTrimHandle, at meters: Double, takingOffPause: Bool) -> Bool {
        guard !takingOffPause else { return false }
        return switch handle {
        case .start: meters <= 0
        case .end: meters >= totalMeters
        }
    }

    /// The leg a cut falls on, and how far along it.
    private struct Bracket {
        let lower: Int
        let upper: Int
        let fraction: Double
    }

    /// Of the points standing at one distance, either side of a pause, a
    /// start takes the last and an end the first — see ``RouteTrim``.
    private func bracket(_ meters: Double, for handle: RouteTrimHandle) -> Bracket {
        let past = switch handle {
        case .start: distances.partitioningIndex { $0 > meters }
        case .end: distances.partitioningIndex { $0 >= meters }
        }
        let upper = min(past, distances.count - 1)
        let lower = max(upper - 1, 0)
        let length = distances[upper] - distances[lower]
        let fraction = length > 0 ? min(max((meters - distances[lower]) / length, 0), 1) : 0
        return Bracket(lower: lower, upper: upper, fraction: fraction)
    }

    private func spot(at leg: Bracket) -> Spot {
        Spot(
            coordinate: RouteGeometry.interpolate(
                from: profile.coordinates[leg.lower],
                to: profile.coordinates[leg.upper],
                fraction: leg.fraction
            ),
            drawnFraction: drawnFractions[leg.lower]
                + (drawnFractions[leg.upper] - drawnFractions[leg.lower]) * leg.fraction
        )
    }

    /// How far along the line the spot nearest `coordinate` is, looking only
    /// around `anchor`, where the handle being dragged stands.
    ///
    /// A handle slides along its line, so a finger that crosses to the other
    /// side of a loop must not take it there: the search stays inside
    /// ``RouteProfile/candidateSegmentRange(near:)``, and inside it a spot
    /// further along the line has to be nearer the finger to win, by
    /// ``continuityWeight``. That is what keeps the handle on its own leg of
    /// an out-and-back, whose two legs lie on top of each other.
    func distance(nearest coordinate: CLLocationCoordinate2D, around anchor: Double) -> Double? {
        var best: (cost: Double, meters: Double)?
        for index in profile.candidateSegmentRange(near: anchor) {
            let length = distances[index + 1] - distances[index]
            // A paused leg is no part of the line — see ``RouteBoundary``.
            guard length > 0 else { continue }
            let projection = RouteGeometry.project(
                coordinate,
                onSegmentFrom: profile.coordinates[index],
                to: profile.coordinates[index + 1]
            )
            let meters = distances[index] + projection.fraction * length
            let cost = projection.offRouteMeters + Self.continuityWeight * abs(meters - anchor)
            if cost < best?.cost ?? .greatestFiniteMagnitude { best = (cost, meters) }
        }
        return best?.meters
    }

    /// How many metres nearer the finger a spot has to be for each metre
    /// further along the line it is from the handle.
    static let continuityWeight = 0.02

    /// How far along the line the spot nearest `coordinate` is, anywhere on
    /// it, when that spot is within `reach` metres: where a finger took hold
    /// of the line. Of two passes over the same ground, the first.
    func distance(at coordinate: CLLocationCoordinate2D, within reach: Double) -> Double? {
        var best: (off: Double, meters: Double)?
        for index in profile.coordinates.indices.dropLast() {
            let length = distances[index + 1] - distances[index]
            // A paused leg is no part of the line — see ``RouteBoundary``.
            guard length > 0 else { continue }
            let projection = RouteGeometry.project(
                coordinate,
                onSegmentFrom: profile.coordinates[index],
                to: profile.coordinates[index + 1]
            )
            guard projection.offRouteMeters < best?.off ?? reach else { continue }
            best = (projection.offRouteMeters, distances[index] + projection.fraction * length)
        }
        return best?.meters
    }

    /// The ground of a stretch of the line: the spot it begins at, every
    /// point inside it, and the spot it ends at.
    func coordinates(between stretch: ClosedRange<Double>) -> [CLLocationCoordinate2D] {
        guard let from = profile.coordinate(atDistance: stretch.lowerBound),
              let to = profile.coordinate(atDistance: stretch.upperBound)
        else { return [] }
        let inside = profile.coordinates.indices.filter { index in
            distances[index] > stretch.lowerBound && distances[index] < stretch.upperBound
        }
        return [from] + inside.map { profile.coordinates[$0] } + [to]
    }
}
