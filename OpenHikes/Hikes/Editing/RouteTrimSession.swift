//
//  RouteTrimSession.swift
//  OpenHikes
//
//  One visit to *Edit Route* on a hike that was recorded or imported: the
//  line being trimmed, where its two cuts stand, and what the map draws of
//  them.
//
//  ## Whose it is
//
//  ``SheetPresentation`` keeps one for as long as the screen's route is on
//  the path, for the reason it keeps every pushed screen's state: a turn of
//  the phone builds the screen again in the other host, and the cuts a hiker
//  placed must not go back to the ends. The pop that takes the screen away
//  ends it, which is what takes its handles off the map.
//
//  ## Two readers, neither a screen's body
//
//  The cuts move at drag frequency, from the chart in the sheet and from the
//  handles on the map. The map reads them directly (see `MapRouteTrim.swift`),
//  and in the sheet only the leaf views that draw them do, so a drag redraws
//  the chart, the figures and the Save button and nothing above them — see
//  *Render isolation, in practice* in `AGENTS.md`. Both cuts are `Double`s,
//  which Observation filters a same-value write of, so a handle held still
//  wakes nothing.
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
    /// How far along the drawn polyline each point stands, 0 to 1, by the
    /// length MapKit measures a polyline in: map points, a paused leg's
    /// included, since the polyline is drawn across it.
    let drawnFractions: [Double]

    var distances: [Double] { profile.distances }
    var totalMeters: Double { profile.totalDistanceMeters }

    @concurrent
    static func measuring(_ route: [RouteCoordinate]) async throws(CancellationError) -> Self {
        assertOffMainThread("A route is measured for trimming off the main thread")
        let measured = try RouteProfile.cancellable(route: route)
        let carried = RouteCarriedEnds.found(in: route, distances: measured.distances)
        guard !Task.isCancelled else { throw CancellationError() }
        return Self(
            route: route,
            profile: measured,
            carriedEnds: carried,
            drawnFractions: Self.drawnFractions(of: measured.coordinates)
        )
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

    /// The clock at a cut `meters` along the line, read off the two points
    /// either side of it, or `nil` where they carry none. An end left alone
    /// is its own point's, as the hike's *Duration* reads it.
    func timestamp(of handle: RouteTrimHandle, at meters: Double, takingOffPause: Bool = false) -> Date? {
        if isLeftAlone(handle, at: meters, takingOffPause: takingOffPause) {
            return handle == .start ? route.first?.timestamp : route.last?.timestamp
        }
        let leg = bracket(meters, for: handle)
        guard let began = route[leg.lower].timestamp, let arrived = route[leg.upper].timestamp else { return nil }
        return began.addingTimeInterval(arrived.timeIntervalSince(began) * leg.fraction)
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
}

@Observable
final class RouteTrimSession {
    /// Non-isolated so releasing the last reference never requires proving
    /// we're on the main actor — see ``LocationManager``'s deinit for why.
    nonisolated deinit { /* intentionally empty */ }

    /// The least a trim may leave: two handles closer than this are one
    /// place, and a line that short is no hike.
    static let minimumKeptMeters = 50.0

    /// Moves when a new line is loaded, which is rare; the map and the
    /// screen read ``line`` when it does.
    private(set) var lineRevision = 0
    @ObservationIgnored private(set) var line: RouteTrimLine?

    /// Where the kept line begins and ends, in metres along ``line``.
    private(set) var startMeters = 0.0
    private(set) var endMeters = 0.0
    /// The pauses standing on the line's own two ends that the cuts take
    /// off, which no distance along the line can say — see
    /// ``RouteTrim/EndPauses``. Only an offer sets one
    /// (``takeOff(_:at:)``); placing that handle by hand clears it.
    private(set) var pausesTakenOff: RouteTrim.EndPauses = []

    /// Whether a save or a revert is under way, which holds the buttons.
    var isSaving = false
    /// Why the last one did not land, while its alert is up.
    var refusal: RouteEditRefusal?

    /// The Health replacement the last save or revert started, if it owed
    /// one — see ``RouteEditWorkout``. Kept so a suite can wait for it.
    @ObservationIgnored var workoutReplacement: Task<Void, Never>?

    @ObservationIgnored private weak var preview: RouteTrimPreview?
    @ObservationIgnored private(set) var isEnded = false

    var totalMeters: Double { line?.totalMeters ?? 0 }

    /// Whether either cut takes anything off, which is when there is
    /// anything to save.
    var isTrimmed: Bool { cuts(.start) || cuts(.end) }

    var keptRange: ClosedRange<Double> { startMeters...max(startMeters, endMeters) }

    // MARK: The line

    /// Measures `route` and starts over on it, with both cuts at its ends.
    /// The same line again changes nothing, so coming back to the screen
    /// keeps the cuts where they were.
    func load(_ route: [RouteCoordinate]) async {
        guard route.count > 1, route != line?.route else { return }
        guard let measured = try? await RouteTrimLine.measuring(route), !Task.isCancelled else { return }
        line = measured
        startMeters = 0
        endMeters = measured.totalMeters
        pausesTakenOff = []
        lineRevision += 1
    }

    // MARK: The cuts

    func position(of handle: RouteTrimHandle) -> Double {
        switch handle {
        case .start: startMeters
        case .end: endMeters
        }
    }

    /// Whether the cut at `handle` takes anything off: it has left its end
    /// of the line, or takes off the pause standing on it.
    func cuts(_ handle: RouteTrimHandle) -> Bool {
        if pausesTakenOff.contains(handle.endPause) { return true }
        return switch handle {
        case .start: startMeters > 0
        case .end: endMeters < totalMeters
        }
    }

    /// Moves one cut, held at least ``minimumKeptMeters`` short of the other
    /// and inside the line. A handle moved by hand stands where it was put,
    /// so it no longer takes off a pause on its end. A touch that leaves it
    /// where it was, as the chart's drag makes on the way down, moves
    /// nothing.
    func move(_ handle: RouteTrimHandle, to meters: Double) {
        let total = totalMeters
        guard total > 0, meters.isFinite else { return }
        let gap = min(Self.minimumKeptMeters, total)
        let before = position(of: handle)
        switch handle {
        case .start: startMeters = min(max(meters, 0), max(endMeters - gap, 0))
        case .end: endMeters = max(min(meters, total), min(startMeters + gap, total))
        }
        if position(of: handle) != before, pausesTakenOff.contains(handle.endPause) {
            pausesTakenOff.remove(handle.endPause)
        }
    }

    /// Cuts `stretch` off the end of the line `handle` stands on: what the
    /// offer under *Not on Foot* does — see ``RouteCarriedEnds``.
    ///
    /// A drive that ends the line paused, with only the fix it took up again
    /// on after it, has no length on the line, so its inner edge is the
    /// line's own end. The cut stands there, and takes off the pause.
    func takeOff(_ stretch: RouteCarriedEnds.Stretch, at handle: RouteTrimHandle) {
        let edge = Self.innerEdge(of: stretch, at: handle)
        move(handle, to: edge)
        let isOnTheEnd = switch handle {
        case .start: edge <= 0
        case .end: edge >= totalMeters
        }
        if isOnTheEnd { pausesTakenOff.insert(handle.endPause) }
    }

    /// Whether the cut at `handle` already takes `stretch` off: it stands at
    /// the stretch's inner edge or past it, and is a cut.
    func hasTakenOff(_ stretch: RouteCarriedEnds.Stretch, at handle: RouteTrimHandle) -> Bool {
        let edge = Self.innerEdge(of: stretch, at: handle)
        let isPast = switch handle {
        case .start: startMeters >= edge
        case .end: endMeters <= edge
        }
        return isPast && cuts(handle)
    }

    /// The edge of `stretch` the walk is on.
    private static func innerEdge(of stretch: RouteCarriedEnds.Stretch, at handle: RouteTrimHandle) -> Double {
        switch handle {
        case .start: stretch.range.upperBound
        case .end: stretch.range.lowerBound
        }
    }

    /// Slides one cut along the line towards where a finger is on the map.
    func move(_ handle: RouteTrimHandle, toward coordinate: CLLocationCoordinate2D) {
        guard let meters = line?.distance(nearest: coordinate, around: position(of: handle)) else { return }
        move(handle, to: meters)
    }

    /// The line the cuts leave, measured for a save — see ``EditedLine``.
    func editedLine() async -> EditedLine? {
        guard let line, isTrimmed else { return nil }
        return await Self.edited(line, keeping: keptRange, takingOff: pausesTakenOff)
    }

    @concurrent
    nonisolated private static func edited(
        _ line: RouteTrimLine,
        keeping range: ClosedRange<Double>,
        takingOff pauses: RouteTrim.EndPauses
    ) async -> EditedLine? {
        EditedLine(trimming: line.route, distances: line.distances, to: range, takingOff: pauses)
    }

    /// Where the cut at `handle` stands on the map, or `nil` with no line.
    func spot(of handle: RouteTrimHandle) -> RouteTrimLine.Spot? {
        guard let line else { return nil }
        let takesOffPause = pausesTakenOff.contains(handle.endPause)
        return switch handle {
        case .start: line.startSpot(at: startMeters, takingOffPause: takesOffPause)
        case .end: line.endSpot(at: endMeters, takingOffPause: takesOffPause)
        }
    }

    /// The clock at the cut at `handle`, or `nil` where the line has none.
    func timestamp(of handle: RouteTrimHandle) -> Date? {
        line?.timestamp(
            of: handle,
            at: position(of: handle),
            takingOffPause: pausesTakenOff.contains(handle.endPause)
        )
    }

    // MARK: The map

    /// Puts the cuts on the map. An ended session is never shown again: the
    /// pop that ended it builds its screen once more on the way out.
    func show(on preview: RouteTrimPreview) {
        guard !isEnded else { return }
        self.preview = preview
        preview.present(self)
    }

    /// Takes the cuts off the map, for good — see the file header.
    func end() {
        isEnded = true
        preview?.withdraw(self)
    }
}

/// The trim the map draws, if a screen has one up: held in a reference type
/// for the reason ``WalkHighlight`` is, so the map observes it directly and
/// no SwiftUI view re-renders for a handle that moved.
@Observable
final class RouteTrimPreview {
    /// Non-isolated so releasing the last reference never requires proving
    /// we're on the main actor — see ``LocationManager``'s deinit for why.
    nonisolated deinit { /* intentionally empty */ }

    private(set) var session: RouteTrimSession?

    /// Called by ``RouteTrimSession/show(on:)`` and nothing else.
    func present(_ session: RouteTrimSession) {
        guard self.session !== session else { return }
        self.session = session
    }

    /// Called by ``RouteTrimSession/end()`` and nothing else.
    func withdraw(_ session: RouteTrimSession) {
        guard self.session === session else { return }
        self.session = nil
    }
}
