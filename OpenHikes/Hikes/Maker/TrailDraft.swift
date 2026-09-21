//
//  TrailDraft.swift
//  OpenHikes
//
//  The trail being drawn, before it is a hike.
//
//  Every trail this app could show came from somewhere else — a recording is a
//  walk that already happened, a GPX is a file somebody sent, a listing is a
//  route somebody published, a curated row is an OpenStreetMap relation. This
//  is the one a hiker makes, and it lives here until Save turns it into an
//  ordinary ``Hike`` (see ``TrailDraftSave``). Nothing downstream of that save
//  learns a new kind of thing exists.
//
//  A stable `@Observable` reference type rather than view state, for the
//  reason ``RouteHighlight`` and ``RecordingTrace`` are: the map draws the
//  line and the pins, the list of waypoints is in a screen inside the sheet,
//  and the write that feeds both arrives from a tap on the map — which is a
//  view the sheet cannot see. Passing any of it up through the hierarchy would
//  make the root view a dependency of a screen two pushes down.
//
//  ## What is published, and what the next phase must not break
//
//  ``waypoints`` is an ordinary observed property, so the map tracks it with
//  `withObservationTracking` exactly as `MapCommunityRoutes` tracks
//  `CommunityBrowser.routeLines`, and the maker's own list reads it in a body.
//  That is correct for as long as a waypoint only ever moves when a hiker taps
//  — which is all this phase does.
//
//  **A drag is the thing that breaks it, and it is the next phase's first
//  problem.** Dragging a pin writes at display rate, and a published array is
//  a body pass per frame for every reader of it. The shape that survives is
//  the one ``RecordingTrace`` uses: the moving point goes on its own
//  untracked channel with a revision beside it, the map reads that, and
//  ``waypoints`` keeps changing only when a drag *ends*. Do not widen this
//  property into the drag; add the channel beside it.
//

import CoreLocation
import Foundation
import Observation

/// One point a hiker put down, and the identity that lets a list draw it.
///
/// Latitude and longitude rather than a `CLLocationCoordinate2D`, because that
/// type is neither `Equatable` nor `Hashable` — and an `@Observable` filters a
/// same-value write only for a value that can answer whether it is one (see
/// *Render isolation, in practice*). The same reason ``RouteCoordinate``
/// stores its pair that way.
///
/// The id is what a row is keyed on and what a reorder moves, so it survives
/// the point being moved on the ground: two waypoints dropped on the same spot
/// are still two waypoints.
nonisolated struct TrailWaypoint: Identifiable, Hashable, Sendable {
    let id: UUID
    var latitude: Double
    var longitude: Double

    init(latitude: Double, longitude: Double, id: UUID = UUID()) {
        self.id = id
        self.latitude = latitude
        self.longitude = longitude
    }

    init(coordinate: CLLocationCoordinate2D, id: UUID = UUID()) {
        self.init(latitude: coordinate.latitude, longitude: coordinate.longitude, id: id)
    }

    var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// The shape a saved route and a stored draft are both written in.
    var routeCoordinate: RouteCoordinate {
        RouteCoordinate(latitude: latitude, longitude: longitude)
    }
}

@Observable
final class TrailDraft {
    /// Non-isolated so releasing the last reference never requires proving
    /// we're on the main actor — see ``LocationManager``'s deinit for why.
    nonisolated deinit { /* intentionally empty */ }

    /// The points, in the order they were put down. See the file header for
    /// why this is published and what the drag phase has to do instead.
    private(set) var waypoints: [TrailWaypoint] = []

    /// How far along the line each waypoint sits, in the order they were put
    /// down. Empty for an empty draft; `0` for the first point of any other.
    ///
    /// Stored, rather than each row measuring its own, because a list that
    /// asks every row to walk the line from the start is quadratic in the
    /// number of points — free at a dozen and not at a hundred, and a hundred
    /// is a long day's route drawn carefully. Measured once per change
    /// instead, which is one walk per tap.
    private(set) var distancesAlongLine: [Double] = []

    /// The line's length, summed along the straight legs between the points.
    ///
    /// The last element of the array above rather than a second sum of the
    /// same legs, which is what makes "the header and the last row say the
    /// same number" true by construction rather than by assertion.
    var distanceMeters: Double { distancesAlongLine.last ?? 0 }

    /// Whether there is a line here at all. One point is a place rather than a
    /// trail, which is why ``TrailDraftSave`` refuses it.
    var canBeSaved: Bool { waypoints.count > 1 }

    var isEmpty: Bool { waypoints.isEmpty }

    var coordinates: [CLLocationCoordinate2D] {
        waypoints.map(\.clCoordinate)
    }

    /// Appends a point at the end of the line.
    func append(_ coordinate: CLLocationCoordinate2D) {
        waypoints.append(TrailWaypoint(coordinate: coordinate))
        remeasure()
    }

    /// Replaces the whole draft — what a restore from disk does, and nothing
    /// else does today.
    ///
    /// The points are the whole of it: a drawn trail is named in the alert
    /// that saves it, so there is nothing else a restore could bring back.
    /// See ``TrailDraftView``.
    func replace(with waypoints: [TrailWaypoint]) {
        self.waypoints = waypoints
        remeasure()
    }

    /// Empties the draft, which is what Cancel and a completed Save both leave
    /// behind.
    func clear() {
        guard !waypoints.isEmpty else { return }
        waypoints = []
        remeasure()
    }

    /// How far along the line a waypoint sits, for the row that names it.
    ///
    /// Answers rather than traps for an index that is not there: a row is
    /// rebuilt while the list is changing shape underneath it.
    func distanceAlongLine(toWaypointAt index: Int) -> Double {
        guard distancesAlongLine.indices.contains(index) else { return 0 }
        return distancesAlongLine[index]
    }

    private func remeasure() {
        let measured = Self.distances(along: waypoints)
        guard distancesAlongLine != measured else { return }
        distancesAlongLine = measured
    }

    /// One running total per waypoint, in one walk of the legs.
    private static func distances(along waypoints: [TrailWaypoint]) -> [Double] {
        guard !waypoints.isEmpty else { return [] }
        var distances: [Double] = [0]
        distances.reserveCapacity(waypoints.count)
        var total: Double = 0
        for (previous, next) in zip(waypoints, waypoints.dropFirst()) {
            total += RouteGeometry.distanceMeters(
                from: previous.clCoordinate,
                to: next.clCoordinate
            )
            distances.append(total)
        }
        return distances
    }
}
